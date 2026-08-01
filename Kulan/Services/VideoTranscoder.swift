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

    // maxSeconds: hard cap for stories (the standard rule — longer videos are auto-trimmed
    // to the first N seconds, never rejected). nil = full length (video messages).
    // stripAudio: the story editor's mute — re-composes with the video track ONLY, so the
    // sound is genuinely gone from the uploaded file (not just muted in the preview).
    static func prepare(_ url: URL, maxSeconds: Double? = nil, stripAudio: Bool = false, hd: Bool = false) async -> Prepared? {
        let asset = AVURLAsset(url: url)
        guard let fullTime = try? await asset.load(.duration), fullTime.seconds > 0 else { return nil }
        var duration = fullTime.seconds

        var exportAsset: AVAsset = asset
        if stripAudio {
            let comp = AVMutableComposition()
            guard let videoTrack = try? await asset.loadTracks(withMediaType: .video).first,
                  let compTrack = comp.addMutableTrack(withMediaType: .video,
                                                       preferredTrackID: kCMPersistentTrackID_Invalid),
                  (try? compTrack.insertTimeRange(CMTimeRange(start: .zero, duration: fullTime),
                                                  of: videoTrack, at: .zero)) != nil else { return nil }
            compTrack.preferredTransform = (try? await videoTrack.load(.preferredTransform)) ?? .identity
            exportAsset = comp
        }

        let out = FileManager.default.temporaryDirectory.appendingPathComponent("send-\(UUID().uuidString).mp4")
        try? FileManager.default.removeItem(at: out)
        // HD = 1080p (bigger file, sharper); standard = 720p (smaller, the default).
        let preset = hd ? AVAssetExportPreset1920x1080 : AVAssetExportPreset1280x720
        guard let session = AVAssetExportSession(asset: exportAsset, presetName: preset) else { return nil }
        session.shouldOptimizeForNetworkUse = true
        if let cap = maxSeconds, duration > cap {
            session.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: cap, preferredTimescale: 600))
            duration = cap
        }
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
