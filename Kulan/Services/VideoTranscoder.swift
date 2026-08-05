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
    /// `range`: export exactly this slice instead of starting at zero. Two callers need it and they
    /// are the same problem seen twice — the trim screen cutting a clip by hand, and a long story
    /// being split into 90-second segments. `maxSeconds` still applies to whatever is left after it.
    ///
    /// `overlay` / `cropRect`: THE STORY EDITOR'S TOOLS, APPLIED TO A VIDEO (owner 2026-08-04 — Aa,
    /// crop and pen were offered on video and then silently dropped at post time, which is worse than
    /// not offering them at all). `overlay` is the text and the pen strokes drawn once into a single
    /// transparent image at the editor's own canvas size; `cropRect` is normalised (0-1) in that same
    /// canvas. Both are composited during the export, so what gets uploaded is what he drew.
    /// One frame and the duration, and nothing else. Decoding a single frame is tens of
    /// milliseconds; `prepare` cannot answer this until the whole export has finished, which for an
    /// eighteen second clip is several seconds.
    ///
    /// That is the entire reason this exists. The send path used to wait for `prepare` before it had
    /// a thumbnail to put in the optimistic bubble, so tapping send on a video sat there doing
    /// nothing visible while the video compressed — measured at 3.88s by the owner. Now the bubble
    /// is drawn from this, immediately, and the transcode happens behind it.
    ///
    /// Returns nil for anything it cannot read, and the caller must treat that as "not a video I can
    /// send" rather than pressing on with a blank bubble.
    struct Poster { let jpeg: Data; let duration: Double; let width: Double; let height: Double }

    static func poster(_ url: URL) async -> Poster? {
        let asset = AVURLAsset(url: url)
        guard let time = try? await asset.load(.duration), time.seconds > 0 else { return nil }
        let duration = time.seconds
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true       // honour the rotation, or a portrait clip lands sideways
        gen.maximumSize = CGSize(width: 1600, height: 1600)
        // Same instant `prepare` samples, and for the same reason: frame zero is very often black.
        let t = CMTime(seconds: min(0.1, duration / 2), preferredTimescale: 600)
        guard let cg = try? await gen.image(at: t).image,
              let jpeg = UIImage(cgImage: cg).jpegData(compressionQuality: 0.72) else { return nil }
        return Poster(jpeg: jpeg, duration: duration, width: Double(cg.width), height: Double(cg.height))
    }

    static func prepare(_ url: URL, maxSeconds: Double? = nil, stripAudio: Bool = false,
                        hd: Bool = false, range: CMTimeRange? = nil,
                        overlay: UIImage? = nil, cropRect: CGRect? = nil,
                        canvasAspect: CGFloat? = nil) async -> Prepared? {
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
        // 540p BY DEFAULT, down from 720p. Read Signal's pipeline for this: they export everything at
        // AVAssetExportPreset640x480 and that single line is why an 18 second clip leaves their app
        // in about three seconds while ours took nearly four just to compress, before a byte moved.
        // Three times the pixels costs twice — the encode is ~3x longer AND the file is ~3x bigger,
        // so the upload afterwards is ~3x longer too.
        //
        // Not 480p though, and the reason is who this app is for. Fariin is people sending video home
        // to family, very often to a phone in Somalia on expensive mobile data. The RECIPIENT pays to
        // download every one of those megabytes, on a connection the site itself says we cannot
        // assume is fast — so file size matters more here than it does for most messengers. But 480p
        // on a 2026 phone is visibly rough, and a video of a wedding that arrives soft has lost the
        // thing it was sent for.
        //
        // 540p is half the pixels of 720p (twice as fast, half the data) and still 1.7x Signal's. HD
        // stays 1080p because that is an explicit choice somebody made for a reason.
        let preset = hd ? AVAssetExportPreset1920x1080 : AVAssetExportPreset960x540
        // A composition of our own needs a preset that will not impose a size as well — the render
        // size is the thing deciding the output here, and two things deciding it is one too many.
        let composing = overlay != nil || cropRect != nil
        guard let session = AVAssetExportSession(asset: exportAsset,
                                                 presetName: composing ? AVAssetExportPresetHighestQuality : preset)
        else { return nil }
        session.shouldOptimizeForNetworkUse = true
        // A HARD CEILING ON THE OUTPUT. This is the thing that was missing, and its absence cost a
        // very long hunt.
        //
        // A resolution preset is a HINT, not a guarantee. Measured on the owner's clip: 18 seconds,
        // 1080x1750 portrait, 59.88 fps, exported through AVAssetExportPreset960x540 and it came out
        // at 19 MB — roughly 8 Mbps, because the preset's bitrate is tuned for 960x540 at THIRTY
        // frames a second and this had double the frame rate and an aspect the box does not fit.
        // Storage then refused it for being over 25 MB, and said "User does not have permission",
        // which names neither size nor quality.
        //
        // I chased the network, then the app's own limits, then the quality setting. All wrong. The
        // real answer is that we were never actually controlling the size — we were asking for a
        // resolution and hoping. `fileLengthLimit` says it outright, and AVFoundation lowers quality
        // as far as it must to obey. A video can now be long, 60fps, portrait, HDR, whatever it
        // likes, and the export still fits.
        //
        // The margin covers AVFoundation overshooting slightly and the few bytes encryption adds.
        session.fileLengthLimit = Int64(Limits.videoMessageBytes - 2 * 1024 * 1024)
        // STRIP THE METADATA. An iPhone recording carries the GPS coordinates it was taken at, the
        // device model and the original timestamps, and we were passing all of it straight through.
        // The clip is end-to-end encrypted so the server never sees any of it — but the person
        // receiving it gets the sender's exact location embedded in the file, permanently, and can
        // read it out with any photo app. In an app that sells itself on privacy that is not a
        // trade-off, it is an oversight. Signal has always set this filter; we never did.
        session.metadataItemFilter = AVMetadataItemFilter.forSharing()
        if composing {
            session.videoComposition = await burnIn(asset: exportAsset, overlay: overlay,
                                                    cropRect: cropRect, canvasAspect: canvasAspect,
                                                    hd: hd)
        }
        // A requested slice wins; the cap then trims whatever that slice turned out to be. Clamped
        // to the real duration, because a range past the end exports nothing at all rather than
        // failing loudly, which is the worst way for this to go wrong.
        if let range {
            let start = max(0, range.start.seconds)
            let len = min(range.duration.seconds, max(0, fullTime.seconds - start))
            guard len > 0.05 else { return nil }
            let capped = min(len, maxSeconds ?? len)
            session.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                            duration: CMTime(seconds: capped, preferredTimescale: 600))
            duration = capped
        } else if let cap = maxSeconds, duration > cap {
            session.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: cap, preferredTimescale: 600))
            duration = cap
        }
        // PROPORTIONAL TO LENGTH, NOT JUST THE FLAT CEILING. The flat cap above only defends the
        // 90-second worst case: an 18-second 60fps clip sailed under it at ~19 MB — 8 Mbps of
        // bytes the upload then carried for no visible gain, which is most of "uploading a story
        // video takes much longer than expected" on a short clip. ~3.2 Mbps is generous for
        // 540p/720p H.264 (the big messengers ship less); AVFoundation only lowers quality as far
        // as it must, so a clip already under its target is untouched. Sits AFTER the timeRange
        // block because `duration` is only final once the slice and the cap have had their say.
        session.fileLengthLimit = min(session.fileLengthLimit,
                                      max(Int64(duration * 400_000), 2 * 1024 * 1024))
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

    /// Build the composition that paints the editor's work onto the frames.
    ///
    /// THE OUTPUT IS THE EDITOR'S CANVAS, not the clip's own frame. That is what makes it WYSIWYG: on
    /// screen the video sits letterboxed on black inside a full-screen canvas and the text and the pen
    /// are placed against THAT, so the export has to reproduce the same canvas or every overlay lands
    /// somewhere slightly wrong. The clip is scaled to fit inside it exactly as `scaledToFit` does,
    /// and a crop then takes a rectangle out of that canvas and makes it the whole picture.
    ///
    /// ONLY REACHED WHEN THERE IS SOMETHING TO BURN IN. A plain video still exports down the original
    /// path, untouched, so nothing that works today can be broken by what happens in here.
    private static func burnIn(asset: AVAsset, overlay: UIImage?, cropRect: CGRect?,
                               canvasAspect: CGFloat?, hd: Bool) async -> AVVideoComposition? {
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let natural = try? await track.load(.naturalSize),
              let transform = try? await track.load(.preferredTransform) else { return nil }

        // The clip's size as it actually appears, after its own rotation is applied.
        let displayed = natural.applying(transform)
        let shown = CGSize(width: abs(displayed.width), height: abs(displayed.height))
        guard shown.width > 1, shown.height > 1 else { return nil }

        // 1. The canvas the editor drew on: its aspect when we know it, the clip's own otherwise.
        let aspect = canvasAspect ?? (shown.width / shown.height)
        let longSide: CGFloat = hd ? 1920 : 1280
        let canvas = aspect >= 1
            ? CGSize(width: longSide, height: (longSide / aspect).rounded())
            : CGSize(width: (longSide * aspect).rounded(), height: longSide)

        // 2. The piece of it being kept. Normalised in, points out, top-left origin like the editor.
        var crop = CGRect(origin: .zero, size: canvas)
        if let c = cropRect, c.width > 0.01, c.height > 0.01 {
            crop = CGRect(x: c.minX * canvas.width, y: c.minY * canvas.height,
                          width: c.width * canvas.width, height: c.height * canvas.height)
        }
        // H.264 wants even dimensions; an odd one is refused outright by some encoders.
        var render = crop.size
        render.width -= render.width.truncatingRemainder(dividingBy: 2)
        render.height -= render.height.truncatingRemainder(dividingBy: 2)
        guard render.width >= 16, render.height >= 16 else { return nil }

        // 3. Place the clip: fit inside the canvas, centred, then shifted so the crop's corner is
        //    the new origin. `scaledToFit` plus a pan, written as one transform.
        let fit = min(canvas.width / shown.width, canvas.height / shown.height)
        let scaled = CGSize(width: shown.width * fit, height: shown.height * fit)
        let place = CGAffineTransform(scaleX: fit, y: fit)
            .concatenating(CGAffineTransform(
                translationX: (canvas.width - scaled.width) / 2 - crop.minX,
                y: (canvas.height - scaled.height) / 2 - crop.minY))

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero,
                                            duration: (try? await asset.load(.duration)) ?? .positiveInfinity)
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        layer.setTransform(transform.concatenating(place), at: .zero)
        instruction.layerInstructions = [layer]

        let comp = AVMutableVideoComposition()
        comp.renderSize = render
        comp.frameDuration = CMTime(value: 1, timescale: 30)
        comp.instructions = [instruction]

        if let overlay, let cg = overlay.cgImage {
            let parent = CALayer(); parent.frame = CGRect(origin: .zero, size: render)
            let video = CALayer(); video.frame = parent.frame
            let art = CALayer()
            // Core Animation composes video with the origin at the BOTTOM left, so the overlay's
            // rectangle is converted into that space and its contents flipped about its own centre.
            // Flipping the parent instead would turn the video upside down with it, which is the
            // classic way this ends up shipping inverted.
            art.frame = CGRect(x: -crop.minX,
                               y: render.height + crop.minY - canvas.height,
                               width: canvas.width, height: canvas.height)
            art.contents = cg
            art.contentsGravity = .resize
            art.transform = CATransform3DMakeScale(1, -1, 1)
            parent.addSublayer(video); parent.addSublayer(art)
            comp.animationTool = AVVideoCompositionCoreAnimationTool(
                postProcessingAsVideoLayer: video, in: parent)
        }
        return comp
    }
}
