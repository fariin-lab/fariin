import AVFoundation
import CoreImage
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

    /// `storyBackdrop`: THIS IS A STORY, so a clip that does not fill the story canvas must carry
    /// its own canvas IN THE FILE, and since 2026-08-07 that canvas is Telegram's two-colour
    /// GRADIENT rather than a blur — his decision after four reports of black bars; the reasoning is
    /// on `gradientComposition`. Baked at post time like the photo path (`flattenBackdrop`), because
    /// THREE viewer-side attempts shipped and failed on his phone — see the kulan-square-video-blur
    /// note. ⚠️ The EDITOR still previews these clips against a blur, so until that is changed too
    /// the preview and the posted file do not match. The accepted cost,
    /// put to him with the fix: a square/landscape story video stops being a fast copy and becomes
    /// a re-encode. Tall 9:16 clips still pass through untouched.
    static func prepare(_ url: URL, maxSeconds: Double? = nil, stripAudio: Bool = false,
                        hd: Bool = false, range: CMTimeRange? = nil,
                        overlay: UIImage? = nil, cropRect: CGRect? = nil,
                        canvasAspect: CGFloat? = nil, storyBackdrop: Bool = false) async -> Prepared? {
        let asset = AVURLAsset(url: url)
        guard let fullTime = try? await asset.load(.duration), fullTime.seconds > 0 else { return nil }
        var duration = fullTime.seconds
        let composing = overlay != nil || cropRect != nil

        // Does this clip need the baked backdrop? Only a story asks, only when nothing else is
        // being burned in (an edited clip goes down `burnIn`, whose canvas rules already own that
        // frame), and only when the clip's shape actually differs from the canvas — a 9:16 clip
        // fills it and keeps the fast path.
        var backdropAspect: CGFloat? = nil
        if storyBackdrop, !composing {
            let target = canvasAspect ?? (9.0 / 16.0)
            if let track = try? await asset.loadTracks(withMediaType: .video).first,
               let natural = try? await track.load(.naturalSize),
               let tf = try? await track.load(.preferredTransform) {
                let d = natural.applying(tf)
                let clipAspect = abs(d.width) / max(1, abs(d.height))
                if abs(clipAspect - target) > 0.02 { backdropAspect = target }
            }
        }

        // FAST PATH. When the clip already obeys every rule we were about to impose, copy it instead
        // of re-encoding it. The encode IS the wait before a video starts uploading, and spending
        // several seconds to produce a slightly worse copy of an already-fine file buys nothing.
        // A clip that needs the backdrop is never eligible: the whole point is frames it does not have.
        if backdropAspect == nil,
           let copied = await passthrough(url: url, stripAudio: stripAudio, hd: hd, composing: composing,
                                          range: range, maxSeconds: maxSeconds, duration: duration),
           let quick = await finish(data: copied, asset: asset, duration: duration) {
            return quick
        }

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
        // (`composing` is decided at the top, because the passthrough check needs it too.)
        guard let session = AVAssetExportSession(asset: exportAsset,
                                                 presetName: (composing || backdropAspect != nil)
                                                     ? AVAssetExportPresetHighestQuality : preset)
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
        } else if let ba = backdropAspect {
            // ⚠️ THIS `if let` IS THE OLD SILENT FALL-THROUGH, and it is why he reported black bars
            // four separate times. The blur build had four ways to return nil and every one of them
            // landed here and did nothing, producing exactly the file he kept photographing.
            //
            // `gradientComposition` is now total apart from "no video track", so this can only skip
            // for a clip that could never have been a story in the first place. Left as an `if let`
            // rather than a force: a crash is not a better answer than a plain export, and the
            // guarantee belongs in the builder, not in an exclamation mark here.
            if let comp = await gradientComposition(asset: exportAsset, aspect: ba, hd: hd) {
                session.videoComposition = comp
            }
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
        return await finish(data: data, asset: asset, duration: duration)
    }

    /// The half both paths share: the poster frame. Taken just after the start, because frame 0 is
    /// very often black, and rotation-corrected so a portrait clip does not land sideways.
    private static func finish(data: Data, asset: AVAsset, duration: Double) async -> Prepared? {
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 1600, height: 1600)
        let t = CMTime(seconds: min(0.1, duration / 2), preferredTimescale: 600)
        guard let cg = try? await gen.image(at: t).image,
              let thumb = UIImage(cgImage: cg).jpegData(compressionQuality: 0.72) else { return nil }
        return Prepared(data: data, thumbnail: thumb, duration: duration,
                        width: Double(cg.width), height: Double(cg.height))
    }

    /// COPY INSTEAD OF RE-ENCODE, when the clip already obeys every rule we would have imposed.
    ///
    /// Returns the mp4 bytes, or nil to mean "not eligible, do the real export". Deliberately narrow:
    /// anything with an overlay, a crop, a mute or a trim needs real frames rendered, and anything
    /// that is not already H.264 has to be converted or some devices cannot play it — that conversion
    /// is most of why this transcoder exists.
    ///
    /// ⚠️ THE METADATA READ-BACK IS NOT DECORATION. An iPhone recording carries the GPS coordinates
    /// it was taken at, and stripping those was a real privacy fix in this app. The same
    /// `metadataItemFilter` the re-encode uses is set here, but passthrough copies existing bytes
    /// rather than rebuilding them, so the output is READ BACK and refused if any location survived.
    /// A refusal costs only the speed: the caller falls through to the ordinary export.
    private static func passthrough(url: URL, stripAudio: Bool, hd: Bool, composing: Bool,
                                    range: CMTimeRange?, maxSeconds: Double?, duration: Double) async -> Data? {
        guard !composing, !stripAudio, range == nil else { return nil }
        if let cap = maxSeconds, duration > cap { return nil }

        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let natural = try? await track.load(.naturalSize),
              let transform = try? await track.load(.preferredTransform),
              let formats = try? await track.load(.formatDescriptions),
              let first = formats.first,
              CMFormatDescriptionGetMediaSubType(first) == kCMVideoCodecType_H264 else { return nil }

        // Inside the box the preset would have put it in, measured the way the clip actually appears
        // (after its own rotation), or a portrait 1080x1920 would read as "too wide" and be refused.
        let displayed = natural.applying(transform)
        let long = max(abs(displayed.width), abs(displayed.height))
        let short = min(abs(displayed.width), abs(displayed.height))
        let box: (CGFloat, CGFloat) = hd ? (1920, 1080) : (960, 540)
        guard long <= box.0, short <= box.1 else { return nil }

        // The same ceiling the export path computes, so passthrough can never post a file the
        // re-encode would have shrunk (and Storage would then refuse).
        let ceiling = min(Int64(Limits.videoMessageBytes - 2 * 1024 * 1024),
                          max(Int64(duration * 400_000), 2 * 1024 * 1024))
        guard let bytes = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              Int64(bytes) <= ceiling else { return nil }

        let out = FileManager.default.temporaryDirectory.appendingPathComponent("pass-\(UUID().uuidString).mp4")
        try? FileManager.default.removeItem(at: out)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough)
        else { return nil }
        session.shouldOptimizeForNetworkUse = true
        session.metadataItemFilter = AVMetadataItemFilter.forSharing()
        do { try await session.export(to: out, as: .mp4) } catch { return nil }
        defer { try? FileManager.default.removeItem(at: out) }

        let result = AVURLAsset(url: out)
        let all = ((try? await result.load(.metadata)) ?? []) + ((try? await result.load(.commonMetadata)) ?? [])
        guard !all.contains(where: isLocation) else { return nil }
        return try? Data(contentsOf: out)
    }

    /// Location hides under more than one key: the common one, and QuickTime's own
    /// `com.apple.quicktime.location.ISO6709`. Match on either rather than name every spelling.
    private static func isLocation(_ item: AVMetadataItem) -> Bool {
        if item.commonKey == .commonKeyLocation { return true }
        return (item.key as? String)?.lowercased().contains("location") ?? false
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
            // (The story's gradient canvas does NOT ride this path — see `gradientComposition`.
            // An edited clip keeps its black letterbox for now; the plain square/landscape story,
            // which is the reported case, gets the gradient.)
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

    /// THE STORY'S CANVAS, FILLED THE WAY TELEGRAM FILLS IT: a two-colour gradient sampled from the
    /// clip, baked into the exported file. Core Image per frame rather than the CoreAnimation tool,
    /// because a composition instruction paints its empty areas OPAQUE black (documented: background
    /// colours must be opaque), so a layer behind the video can never show through it.
    ///
    /// ⚠️ WHY THIS IS NOT A BLUR ANY MORE — his call, 2026-08-07, after four reports of black bars.
    /// He asked me to read Telegram; I read `VideoFinishPass.swift` and `mediaEditorGetGradientColors`
    /// in their MediaEditor, and they do not blur at all. They take two colours off the first frame
    /// and run a gradient behind the video. Rebuilt here from that idea, NOT copied: Telegram is
    /// GPL and that licence is exactly why we never take their code ([[kulan-telegram-conversation-mode]]).
    ///
    /// The blur had FOUR separate ways to return nil — a poster frame that would not decode, a
    /// degenerate canvas, a CIContext that would not produce a bitmap, and a throwing composition
    /// builder — and every one of them was silent and fell through to plain black bars. That is the
    /// bug, four times over. This version cannot do that:
    ///
    /// * The colours cannot fail. If the poster will not decode, or a crop comes back empty, the
    ///   sampler returns a neutral dark pair instead of nothing, and the gradient is still drawn.
    /// * The gradient is CoreGraphics, not Core Image: no CIContext to lose. If even that fails it
    ///   falls back to a flat fill of the top colour, which is still a canvas.
    /// * The only remaining nil is "this asset has no video track", and a clip with no video track
    ///   was never going to be a story.
    ///
    /// So the caller's `if let` can no longer quietly do nothing.
    private static func gradientComposition(asset: AVAsset, aspect: CGFloat, hd: Bool) async -> AVVideoComposition? {
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let natural = try? await track.load(.naturalSize),
              let transform = try? await track.load(.preferredTransform) else { return nil }
        let displayed = natural.applying(transform)
        let shown = CGSize(width: abs(displayed.width), height: abs(displayed.height))
        guard shown.width > 1, shown.height > 1 else { return nil }

        // The canvas, same sizing rule as `burnIn`, forced to even H.264-friendly dimensions.
        let longSide: CGFloat = hd ? 1920 : 1280
        var canvas = aspect >= 1
            ? CGSize(width: longSide, height: (longSide / aspect).rounded())
            : CGSize(width: (longSide * aspect).rounded(), height: longSide)
        canvas.width -= canvas.width.truncatingRemainder(dividingBy: 2)
        canvas.height -= canvas.height.truncatingRemainder(dividingBy: 2)
        guard canvas.width >= 16, canvas.height >= 16 else { return nil }

        // Two colours off the clip, then one gradient bitmap the whole export composites over. Both
        // steps are total: `gradientColours` always answers, and `gradientBackdrop` falls back to a flat
        // fill rather than to nothing.
        let colours = await gradientColours(of: asset)
        let backdrop = gradientBackdrop(size: canvas, top: colours.top, bottom: colours.bottom)

        let comp: AVMutableVideoComposition
        do {
            comp = try await AVMutableVideoComposition.videoComposition(with: asset) { request in
                var frame = request.sourceImage
                // ⚠️ ORIENTATION, DECIDED BY MEASUREMENT, because the documentation does not
                // decide it: whether this handler receives frames with the track's
                // preferredTransform already applied has changed across OS versions and is the
                // classic way this API ships sideways video. So the frame is measured: if its
                // extent already matches the displayed size, the rotation happened; if it still
                // matches the natural size, it has not, and it is applied here. (A square clip
                // carrying rotation metadata is undecidable this way and extremely rare — a
                // square frame is fitted identically either way, only its pixels could differ.)
                let ext = frame.extent.size
                let alreadyRotated = abs(ext.width - shown.width) < 2 && abs(ext.height - shown.height) < 2
                if !alreadyRotated {
                    frame = frame.transformed(by: transform)
                    frame = frame.transformed(by: CGAffineTransform(
                        translationX: -frame.extent.minX, y: -frame.extent.minY))
                }
                // Fit and centre on the canvas, measured from the frame actually in hand.
                let s = min(canvas.width / frame.extent.width, canvas.height / frame.extent.height)
                frame = frame.transformed(by: CGAffineTransform(scaleX: s, y: s))
                frame = frame.transformed(by: CGAffineTransform(
                    translationX: (canvas.width - frame.extent.width) / 2 - frame.extent.minX,
                    y: (canvas.height - frame.extent.height) / 2 - frame.extent.minY))
                request.finish(with: frame.composited(over: backdrop), context: nil)
            }
        } catch { return nil }
        comp.renderSize = canvas
        return comp
    }

    /// THE SAME CANVAS, AS A STILL, for the placeholder shown while a video uploads.
    ///
    /// His 2026-08-07 report: "when is uploading it's showing blur, when upload finished it's showing
    /// different color… use one is better". He is right, and the cause is that the two pictures were
    /// made by different code. The uploading card drew the raw poster, which letterboxes BLACK, while
    /// the finished file carries the gradient this file bakes — so the story visibly changed colour
    /// the moment it landed.
    ///
    /// This runs the identical sampler and the identical gradient over the poster frame, so the
    /// placeholder is the same picture the export will produce. Same functions, not a second
    /// implementation of the same idea: two implementations would agree today and drift later.
    ///
    /// Returns the poster untouched when it already fits the canvas, which is every 9:16 clip.
    static func storyCanvasPoster(_ poster: UIImage, aspect: CGFloat = 9.0 / 16.0) -> UIImage {
        guard let cg = poster.cgImage else { return poster }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        guard w > 1, h > 1 else { return poster }
        guard abs(w / h - aspect) > 0.02 else { return poster }   // already the right shape
        let longSide: CGFloat = 1280
        var canvas = aspect >= 1
            ? CGSize(width: longSide, height: (longSide / aspect).rounded())
            : CGSize(width: (longSide * aspect).rounded(), height: longSide)
        canvas.width -= canvas.width.truncatingRemainder(dividingBy: 2)
        canvas.height -= canvas.height.truncatingRemainder(dividingBy: 2)
        guard canvas.width >= 16, canvas.height >= 16 else { return poster }
        let colours = gradientColours(of: cg)
        let fmt = UIGraphicsImageRendererFormat(); fmt.scale = 1; fmt.opaque = true
        return UIGraphicsImageRenderer(size: canvas, format: fmt).image { ctx in
            drawGradient(in: ctx.cgContext, size: canvas, top: colours.top, bottom: colours.bottom)
            // Fitted and centred, the same placement the export's per-frame handler uses.
            let s = min(canvas.width / w, canvas.height / h)
            let box = CGRect(x: (canvas.width - w * s) / 2, y: (canvas.height - h * s) / 2,
                             width: w * s, height: h * s)
            poster.draw(in: box)
        }
    }

    /// The two colours the story canvas is filled with, read off the clip's own first frame.
    ///
    /// TOTAL BY CONSTRUCTION — it always returns a usable pair, because the whole point of this
    /// rewrite is that nothing in the canvas path may quietly produce nothing. A clip whose poster
    /// will not decode gets the neutral dark pair, which still reads as a deliberate backdrop rather
    /// than as the black bars he has reported four times.
    ///
    /// The instant sampled is the same just-after-zero one every poster in this file uses: frame
    /// zero is very often black on a real recording, and a black gradient IS the bug wearing a
    /// different hat.
    private static func gradientColours(of asset: AVAsset) async -> (top: CIColor, bottom: CIColor) {
        let fallback = (top: CIColor(red: 0.13, green: 0.13, blue: 0.15),
                        bottom: CIColor(red: 0.05, green: 0.05, blue: 0.06))
        let gen = AVAssetImageGenerator(asset: asset)
        // `appliesPreferredTrackTransform` so a clip recorded sideways is sampled the way it will be
        // SEEN: without it, the "top" band of a rotated clip is one of its sides.
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 240, height: 240)
        let dur = ((try? await asset.load(.duration))?.seconds) ?? 1
        let at = CMTime(seconds: min(0.1, max(0, dur / 2)), preferredTimescale: 600)
        guard let cg = try? await gen.image(at: at).image else { return fallback }
        return gradientColours(of: cg)
    }

    /// The same sampling, from a frame already in hand. Split out so the uploading placeholder and
    /// the export read their colours through ONE function — two implementations would agree today
    /// and drift the first time either is touched, and "it changes colour when it lands" is the
    /// report that produced this.
    static func gradientColours(of cg: CGImage) -> (top: CIColor, bottom: CIColor) {
        let fallback = (top: CIColor(red: 0.13, green: 0.13, blue: 0.15),
                        bottom: CIColor(red: 0.05, green: 0.05, blue: 0.06))
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        guard w >= 1, h >= 1 else { return fallback }
        // A band rather than a line: one row of pixels can land on a caption, a letterbox edge or a
        // single bright object. An eighth of the height averages those away and still describes the
        // end of the picture the gradient has to meet.
        let band = max(1, (h / 8).rounded())
        // ⚠️ `CGImage.cropping(to:)` takes its rectangle in the IMAGE's own space, whose origin is
        // the TOP left. That is not the same convention as a CGContext, and getting it backwards
        // would put the sky at the bottom — the kind of mistake nobody sees until it ships.
        let top = averageColour(of: cg, in: CGRect(x: 0, y: 0, width: w, height: band))
        let bottom = averageColour(of: cg, in: CGRect(x: 0, y: h - band, width: w, height: band))
        guard let top, let bottom else { return fallback }
        return (top, bottom)
    }

    /// The mean colour of one band of a frame, or nil if it cannot be read.
    ///
    /// Averaged in code from a small grid rather than by asking CoreGraphics to scale the band
    /// straight down to a single pixel: at extreme reductions the interpolator is free to point
    /// sample, and a "mean" that is really one arbitrary pixel is how a gradient ends up keyed to a
    /// speck of glare.
    private static func averageColour(of image: CGImage, in rect: CGRect) -> CIColor? {
        guard let crop = image.cropping(to: rect.integral), crop.width > 0, crop.height > 0
        else { return nil }
        let side = 8
        var px = [UInt8](repeating: 0, count: side * side * 4)
        let ok: Bool = px.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: side, height: side,
                                      bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(crop, in: CGRect(x: 0, y: 0, width: CGFloat(side), height: CGFloat(side)))
            return true
        }
        guard ok else { return nil }
        var r = 0.0, g = 0.0, b = 0.0, n = 0.0
        for i in stride(from: 0, to: px.count, by: 4) {
            // Premultiplied: undo the alpha before averaging, and skip anything transparent so a
            // clip with an alpha channel cannot drag the mean towards black.
            let a = Double(px[i + 3]) / 255
            guard a > 0.01 else { continue }
            r += Double(px[i]) / 255 / a
            g += Double(px[i + 1]) / 255 / a
            b += Double(px[i + 2]) / 255 / a
            n += 1
        }
        guard n > 0 else { return nil }
        return CIColor(red: CGFloat(min(1, r / n)), green: CGFloat(min(1, g / n)), blue: CGFloat(min(1, b / n)))
    }

    /// The gradient itself, drawn ONCE into a bitmap the export then composites every frame over.
    ///
    /// Returns a CIImage that ALWAYS covers the whole canvas, and there is no failure path out of
    /// here. CoreGraphics draws it, because there is no CIContext in that route to lose; if the
    /// bitmap cannot be produced for any reason, the fallback is `CIImage(color:)` cropped to the
    /// canvas, which is a Core Image generator with no allocation to fail and infinite extent. A
    /// flat colour is still a canvas. The one thing this must never do is hand back something that
    /// does not cover the frame, because whatever it does not cover is composited as BLACK — which
    /// is the exact bug this whole rewrite exists to end.
    private static func gradientBackdrop(size: CGSize, top: CIColor, bottom: CIColor) -> CIImage {
        let canvas = CGRect(origin: .zero, size: size)
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        fmt.opaque = true
        let ui = UIGraphicsImageRenderer(size: size, format: fmt).image { ctx in
            drawGradient(in: ctx.cgContext, size: size, top: top, bottom: bottom)
        }
        if let cg = ui.cgImage { return CIImage(cgImage: cg) }
        return CIImage(color: top).cropped(to: canvas)
    }

    /// The gradient stroke itself, shared by the export's backdrop and the uploading placeholder.
    ///
    /// The flat fill goes down FIRST, so even if the gradient cannot be built the result is still a
    /// full, opaque canvas rather than a transparent one — the invariant the whole rewrite rests on
    /// is that nothing here may leave part of the frame uncovered, because uncovered composites as
    /// black.
    ///
    /// ⚠️ `UIGraphicsImageRenderer` hands out a FLIPPED context (origin top-left, y downwards), so
    /// y = 0 is the TOP and the top colour starts there. Drawing it the other way up is the classic
    /// way a gradient ships upside down, and on a clip whose two sampled colours are similar nobody
    /// would notice until it shipped.
    private static func drawGradient(in cg: CGContext, size: CGSize, top: CIColor, bottom: CIColor) {
        let topUI = UIColor(red: top.red, green: top.green, blue: top.blue, alpha: 1)
        let bottomUI = UIColor(red: bottom.red, green: bottom.green, blue: bottom.blue, alpha: 1)
        topUI.setFill()
        cg.fill(CGRect(origin: .zero, size: size))
        guard let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                    colors: [topUI.cgColor, bottomUI.cgColor] as CFArray,
                                    locations: [0, 1])
        else { return }
        cg.drawLinearGradient(grad,
                              start: CGPoint(x: size.width / 2, y: 0),
                              end: CGPoint(x: size.width / 2, y: size.height),
                              options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }
}
