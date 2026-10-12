import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit
import VideoToolbox

// ⛔ STORY VIDEOS ONLY. Chat videos keep `VideoTranscoder.prepare`'s export-session path untouched.
//
// Why a second encoder (owner, 2026-10-12: story videos lose quality and smoothness next to the
// reference app). The export-session path had five causes, each measured in the code:
//   1. the edited path pinned the output to 30 frames a second (`burnIn`'s frameDuration), so a
//      60 fps clip lost every other frame;
//   2. a plain story went through AVAssetExportPreset960x540, so a story was 540 wide;
//   3. an export session takes no bitrate. Size was held by `fileLengthLimit`, which stops the
//      export when the file reaches the limit rather than lowering the quality, and the preset's
//      own bitrate decided everything else;
//   4. nothing said what colour the output is, so an HDR iPhone clip was left to the preset;
//   5. a brightness change was a full HighestQuality encode BEFORE the real encode: two generations.
//
// This path reads the clip once through ONE Core Image composition (rotation, framing, brightness,
// the editor's text and drawing, the card's surround, the gradient canvas) and writes it once with
// AVAssetWriter: HEVC where the encoder is there (H.264 High otherwise), the source's own frame rate
// up to 60, an explicit average bitrate by size, frame rate and length, and BT.709 SDR colour, which
// makes AVFoundation tone-map an HDR source instead of clipping it.
enum StoryVideoEncoder {

    /// The upload ceiling this encoder sizes against. storage.rules `stories/` allows 50 MB; the
    /// margin covers the encoder overshooting its average a little.
    static let budgetBytes: Double = Double(Limits.storyUploadBytes - 3 * 1024 * 1024)

    /// What the editor handed over for this segment. All in the same units `VideoTranscoder.burnIn`
    /// has always used, so the posted frame is the one the editor showed.
    struct Edits {
        var overlay: UIImage?
        var cropRect: CGRect?
        var canvasAspect: CGFloat?
        var contentScale: CGFloat
        var backdrop: UIImage?
        var holeCorner: CGFloat
        var brightness: Double
        /// A non-9:16 clip with nothing composited gets the sampled gradient canvas baked in.
        var gradientAspect: CGFloat?
        var hd: Bool

        var composing: Bool { overlay != nil || cropRect != nil || backdrop != nil || contentScale < 0.999 }
    }

    struct Output { let url: URL; let reframed: Bool }

    // MARK: Entry

    /// Encodes `range` of `asset` into a new mp4. nil on any failure; the caller then falls back to
    /// the old export path, so a story is never lost to this encoder.
    static func encode(asset: AVURLAsset, range: CMTimeRange, stripAudio: Bool, edits: Edits) async -> Output? {
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let natural = try? await track.load(.naturalSize),
              let transform = try? await track.load(.preferredTransform) else { return nil }
        let displayed = natural.applying(transform)
        let shown = CGSize(width: abs(displayed.width), height: abs(displayed.height))
        guard shown.width > 1, shown.height > 1 else { return nil }

        let fps = await frameRate(of: track)
        guard let layout = Layout(shown: shown, edits: edits) else { return nil }

        var under: CIImage = CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: layout.canvas))
        if edits.gradientAspect != nil {
            let c = await VideoTranscoder.gradientColours(of: asset)
            under = VideoTranscoder.gradientBackdrop(size: layout.canvas, top: c.top, bottom: c.bottom)
        }
        let surround = layout.surround(backdrop: edits.backdrop, contentScale: edits.contentScale,
                                       holeCorner: edits.holeCorner).flatMap(layout.onCanvas)
        let overlay = edits.overlay.flatMap(layout.onCanvas)
        let ev = StoryVideoBrightness.isNeutral(edits.brightness) ? nil
            : StoryVideoBrightness.exposureEV(for: edits.brightness)
        let underPlaced = under.transformed(by: layout.canvasShift)

        let comp: AVMutableVideoComposition
        do {
          comp = try await AVMutableVideoComposition.videoComposition(with: asset) { request in
            var f = request.sourceImage
            // Some OS versions hand the frame over already rotated and some do not; the size says
            // which (the same test `gradientComposition` uses).
            let ext = f.extent.size
            let alreadyRotated = abs(ext.width - shown.width) < 2 && abs(ext.height - shown.height) < 2
            if !alreadyRotated { f = f.transformed(by: transform) }
            f = f.transformed(by: CGAffineTransform(translationX: -f.extent.minX, y: -f.extent.minY))
            if let ev {
                let b = CIFilter.exposureAdjust()
                b.inputImage = f
                b.ev = ev
                f = (b.outputImage ?? f).cropped(to: f.extent)
            }
            let s = layout.fit * shown.width / max(1, f.extent.width)
            f = f.transformed(by: CGAffineTransform(scaleX: s, y: s))
            f = f.transformed(by: CGAffineTransform(translationX: layout.videoOrigin.x - f.extent.minX,
                                                    y: layout.videoOrigin.y - f.extent.minY))
            var out = f.composited(over: underPlaced)
            if let surround { out = surround.composited(over: out) }
            if let overlay { out = overlay.composited(over: out) }
            request.finish(with: out.cropped(to: CGRect(origin: .zero, size: layout.render)), context: nil)
          }
        } catch { return nil }
        comp.renderSize = layout.render
        comp.frameDuration = CMTime(seconds: 1 / fps, preferredTimescale: 60_000)
        // Output frames follow the source's own timestamps, so a variable-rate phone clip is not
        // resampled onto a fixed grid.
        comp.sourceTrackIDForFrameTiming = track.trackID
        // SDR BT.709 out. With an HDR source this is what makes AVFoundation tone-map it.
        comp.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        comp.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        comp.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2

        let out = FileManager.default.temporaryDirectory.appendingPathComponent("story-\(UUID().uuidString).mp4")
        let ok = await write(asset: asset, track: track, composition: comp, range: range,
                             stripAudio: stripAudio, size: layout.render, fps: fps, to: out)
        guard ok else { try? FileManager.default.removeItem(at: out); return nil }
        let size = (try? out.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size > 0, Double(size) <= Double(Limits.storyUploadBytes - 512 * 1024) else {
            try? FileManager.default.removeItem(at: out); return nil
        }
        let reframed = edits.composing || edits.gradientAspect != nil
        return Output(url: out, reframed: reframed)
    }

    // MARK: Rates

    /// The clip's own frame rate, 15 to 60.
    static func frameRate(of track: AVAssetTrack) async -> Double {
        let nominal = Double((try? await track.load(.nominalFrameRate)) ?? 0)
        let minDur = (try? await track.load(.minFrameDuration))?.seconds ?? 0
        let fps = nominal > 1 ? nominal : (minDur > 0 ? 1 / minDur : 30)
        return min(60, max(15, fps))
    }

    /// Average video bits per second: by output size and frame rate, then held under the upload
    /// budget for the segment's length (audio and container counted).
    static func videoBitrate(size: CGSize, fps: Double, hevc: Bool, seconds: Double) -> Int {
        let large = max(size.width, size.height) > 1400
        let fast = fps > 40
        var mbps: Double = large ? (fast ? 7.0 : 5.0) : (fast ? 4.5 : 3.2)
        if !hevc { mbps *= 1.4 }   // H.264 needs about 40 % more for the same picture
        let audio = 128_000.0
        let room = budgetBytes * 8 / max(1, seconds) - audio - 64_000
        return Int(max(600_000, min(mbps * 1_000_000, room)))
    }

    // MARK: Writer

    private static func write(asset: AVURLAsset, track: AVAssetTrack, composition: AVVideoComposition,
                              range: CMTimeRange, stripAudio: Bool, size: CGSize, fps: Double,
                              to out: URL) async -> Bool {
        guard let reader = try? AVAssetReader(asset: asset),
              let writer = try? AVAssetWriter(outputURL: out, fileType: .mp4) else { return false }
        reader.timeRange = range
        writer.shouldOptimizeForNetworkUse = true

        let vOut = AVAssetReaderVideoCompositionOutput(videoTracks: [track], videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
        vOut.videoComposition = composition
        vOut.alwaysCopiesSampleData = false
        guard reader.canAdd(vOut) else { return false }
        reader.add(vOut)

        let colour: [String: Any] = [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                                     AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                                     AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]
        func settings(hevc: Bool) -> [String: Any] {
            [AVVideoCodecKey: hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
             AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
             AVVideoColorPropertiesKey: colour,
             AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: videoBitrate(size: size, fps: fps, hevc: hevc,
                                                       seconds: range.duration.seconds),
                AVVideoExpectedSourceFrameRateKey: Int(fps.rounded()),
                AVVideoMaxKeyFrameIntervalDurationKey: 2,
                AVVideoAllowFrameReorderingKey: true,
                AVVideoProfileLevelKey: hevc ? (kVTProfileLevel_HEVC_Main_AutoLevel as String)
                                             : AVVideoProfileLevelH264HighAutoLevel,
             ] as [String: Any]]
        }
        let hevcSettings = settings(hevc: true)
        let useHEVC = writer.canApply(outputSettings: hevcSettings, forMediaType: .video)
        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: useHEVC ? hevcSettings : settings(hevc: false))
        vIn.expectsMediaDataInRealTime = false
        guard writer.canAdd(vIn) else { return false }
        writer.add(vIn)

        var audioPair: (AVAssetReaderOutput, AVAssetWriterInput)? = nil
        if !stripAudio, let at = try? await asset.loadTracks(withMediaType: .audio).first {
            var stereo = AudioChannelLayout()
            stereo.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
            let layoutData = Data(bytes: &stereo, count: MemoryLayout<AudioChannelLayout>.size)
            let aOut = AVAssetReaderTrackOutput(track: at, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 2,
                AVChannelLayoutKey: layoutData,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false])
            aOut.alwaysCopiesSampleData = false
            let aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 2,
                AVChannelLayoutKey: layoutData,
                AVEncoderBitRateKey: 128_000])
            aIn.expectsMediaDataInRealTime = false
            if reader.canAdd(aOut), writer.canAdd(aIn) {
                reader.add(aOut); writer.add(aIn)
                audioPair = (aOut, aIn)
            }
        }

        guard writer.startWriting(), reader.startReading() else {
            reader.cancelReading(); writer.cancelWriting(); return false
        }
        writer.startSession(atSourceTime: range.start)

        async let video: Void = pump(vOut, into: vIn, label: "story.video")
        if let pair = audioPair { await pump(pair.0, into: pair.1, label: "story.audio") }
        await video

        guard reader.status == .completed else {
            reader.cancelReading(); writer.cancelWriting(); return false
        }
        await writer.finishWriting()
        return writer.status == .completed
    }

    /// Feeds one reader output into one writer input until the reader runs dry.
    private static func pump(_ output: AVAssetReaderOutput, into input: AVAssetWriterInput, label: String) async {
        final class Flag: @unchecked Sendable { var done = false }
        let queue = DispatchQueue(label: label)
        let flag = Flag()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            input.requestMediaDataWhenReady(on: queue) {
                guard !flag.done else { return }
                while input.isReadyForMoreMediaData {
                    guard let sample = output.copyNextSampleBuffer(), input.append(sample) else {
                        flag.done = true
                        input.markAsFinished()
                        cont.resume()
                        return
                    }
                }
            }
        }
    }

    // MARK: Layout

    /// The geometry `VideoTranscoder.burnIn` and `gradientComposition` used, expressed for Core
    /// Image (origin bottom-left) instead of a layer instruction (origin top-left).
    struct Layout {
        let canvas: CGSize
        let crop: CGRect      // in canvas points, origin top-left
        let render: CGSize
        let fit: CGFloat
        let scaled: CGSize
        let videoOrigin: CGPoint   // bottom-left corner of the placed clip in render space

        init?(shown: CGSize, edits: Edits) {
            // A plain clip keeps its own shape; only an edited one is put on the editor's canvas.
            let own = shown.width / shown.height
            let aspect = edits.gradientAspect ?? (edits.composing ? (edits.canvasAspect ?? own) : own)
            var longSide: CGFloat = edits.hd ? 1920 : 1280
            // A plain story is never scaled UP: a 720p clip stays 720p.
            if !edits.composing && edits.gradientAspect == nil {
                longSide = min(longSide, max(shown.width, shown.height))
            }
            var canvas = aspect >= 1
                ? CGSize(width: longSide, height: (longSide / aspect).rounded())
                : CGSize(width: (longSide * aspect).rounded(), height: longSide)
            if edits.gradientAspect != nil || !edits.composing {
                canvas.width -= canvas.width.truncatingRemainder(dividingBy: 2)
                canvas.height -= canvas.height.truncatingRemainder(dividingBy: 2)
            }
            var crop = CGRect(origin: .zero, size: canvas)
            if let c = edits.cropRect, c.width > 0.01, c.height > 0.01 {
                crop = CGRect(x: c.minX * canvas.width, y: c.minY * canvas.height,
                              width: c.width * canvas.width, height: c.height * canvas.height)
            }
            var render = crop.size
            render.width -= render.width.truncatingRemainder(dividingBy: 2)
            render.height -= render.height.truncatingRemainder(dividingBy: 2)
            guard render.width >= 16, render.height >= 16 else { return nil }

            let scale = edits.gradientAspect != nil ? 1 : min(1, max(0.05, edits.contentScale))
            let fit = min(canvas.width / shown.width, canvas.height / shown.height) * scale
            let scaled = CGSize(width: shown.width * fit, height: shown.height * fit)
            // Top-left placement exactly as `burnIn`'s `place`, then flipped into render space.
            let tx = (canvas.width - scaled.width) / 2 - crop.minX
            let ty = (canvas.height - scaled.height) / 2 - crop.minY
            self.canvas = canvas
            self.crop = crop
            self.render = render
            self.fit = fit
            self.scaled = scaled
            self.videoOrigin = CGPoint(x: tx, y: render.height - ty - scaled.height)
        }

        /// Moves a canvas-sized image (origin bottom-left at the canvas corner) into render space,
        /// the same offset `burnIn`'s `canvasLayer` gave its layers.
        var canvasShift: CGAffineTransform {
            CGAffineTransform(translationX: -crop.minX, y: render.height + crop.minY - canvas.height)
        }

        /// A full-canvas picture (the editor's overlay, or the card surround) placed in render space.
        func onCanvas(_ image: UIImage) -> CIImage? {
            guard let cg = image.cgImage, cg.width > 0, cg.height > 0 else { return nil }
            return CIImage(cgImage: cg)
                .transformed(by: CGAffineTransform(scaleX: canvas.width / CGFloat(cg.width),
                                                   y: canvas.height / CGFloat(cg.height)))
                .transformed(by: canvasShift)
        }

        /// The repost card's surround with the clip's hole cut out, as `burnIn` draws it.
        func surround(backdrop: UIImage?, contentScale: CGFloat, holeCorner: CGFloat) -> UIImage? {
            guard let backdrop, contentScale < 0.999 else { return nil }
            let placed = CGRect(x: (canvas.width - scaled.width) / 2, y: (canvas.height - scaled.height) / 2,
                                width: scaled.width, height: scaled.height)
            let fmt = UIGraphicsImageRendererFormat(); fmt.scale = 1; fmt.opaque = false
            return UIGraphicsImageRenderer(size: canvas, format: fmt).image { ctx in
                backdrop.draw(in: CGRect(origin: .zero, size: canvas))
                ctx.cgContext.setBlendMode(.clear)
                let hole = placed.insetBy(dx: 0.5, dy: 0.5)
                if holeCorner > 0 {
                    ctx.cgContext.addPath(UIBezierPath(roundedRect: hole, cornerRadius: hole.width * holeCorner).cgPath)
                    ctx.cgContext.fillPath()
                } else {
                    ctx.cgContext.fill(hole)
                }
            }
        }
    }
}

extension VideoTranscoder {
    /// The story path of `prepare`. nil means "use the old path", never "the story failed".
    static func prepareStory(_ url: URL, maxSeconds: Double?, stripAudio: Bool, hd: Bool,
                             range: CMTimeRange?, overlay: UIImage?, cropRect: CGRect?,
                             canvasAspect: CGFloat?, contentScale: CGFloat, backdrop: UIImage?,
                             brightness: Double, holeCorner: CGFloat) async -> Prepared? {
        let asset = AVURLAsset(url: url)
        guard let fullTime = try? await asset.load(.duration), fullTime.seconds > 0 else { return nil }
        var start = 0.0
        var length = fullTime.seconds
        if let range {
            start = max(0, range.start.seconds)
            length = min(range.duration.seconds, max(0, fullTime.seconds - start))
        }
        guard length > 0.05 else { return nil }
        if let cap = maxSeconds { length = min(length, cap) }
        let timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                    duration: CMTime(seconds: length, preferredTimescale: 600))

        var edits = StoryVideoEncoder.Edits(overlay: overlay, cropRect: cropRect, canvasAspect: canvasAspect,
                                            contentScale: contentScale, backdrop: backdrop,
                                            holeCorner: holeCorner, brightness: brightness,
                                            gradientAspect: nil, hd: hd)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let natural = try? await track.load(.naturalSize),
              let transform = try? await track.load(.preferredTransform) else { return nil }
        let d = natural.applying(transform)
        let shown = CGSize(width: abs(d.width), height: abs(d.height))
        if !edits.composing {
            // Same test as the old path: a clip that is not the canvas's shape gets the gradient.
            let target = canvasAspect ?? (9.0 / 16.0)
            let clipAspect = shown.width / max(1, shown.height)
            if abs(clipAspect - target) > 0.02 { edits.gradientAspect = target }
        }

        // NOTHING TO DO = NO ENCODE. A whole, unedited clip that is already story-sized, SDR and
        // within the bitrate a story would get is posted as it is: no generation lost at all.
        let whole = start < 0.05 && length >= fullTime.seconds - 0.05
        if whole, !edits.composing, edits.gradientAspect == nil, !stripAudio,
           StoryVideoBrightness.isNeutral(brightness),
           let copied = await storyCopy(asset: asset, track: track, shown: shown, hd: hd, seconds: length),
           let quick = await finish(data: copied, asset: asset, duration: length) {
            return quick
        }

        guard let out = await StoryVideoEncoder.encode(asset: asset, range: timeRange,
                                                       stripAudio: stripAudio, edits: edits) else { return nil }
        defer { try? FileManager.default.removeItem(at: out.url) }
        guard let data = try? Data(contentsOf: out.url) else { return nil }
        return await finish(data: data, asset: asset, duration: length,
                            canvasAspect: edits.gradientAspect, startAt: start,
                            posted: out.reframed ? AVURLAsset(url: out.url) : nil)
    }

    /// The untouched copy for a story (container rewritten, location stripped, samples unchanged).
    private static func storyCopy(asset: AVURLAsset, track: AVAssetTrack, shown: CGSize, hd: Bool,
                                  seconds: Double) async -> Data? {
        guard let formats = try? await track.load(.formatDescriptions), let first = formats.first else { return nil }
        let codec = CMFormatDescriptionGetMediaSubType(first)
        let hevc = codec == kCMVideoCodecType_HEVC
        guard hevc || codec == kCMVideoCodecType_H264 else { return nil }
        let traits = (try? await track.load(.mediaCharacteristics)) ?? []
        guard !traits.contains(.containsHDRVideo) else { return nil }
        let long = max(shown.width, shown.height), short = min(shown.width, shown.height)
        guard long <= (hd ? 1920 : 1280) + 1, short <= (hd ? 1080 : 720) + 1 else { return nil }
        let fps = await StoryVideoEncoder.frameRate(of: track)
        // Up to half again what this encoder would spend on the same clip, never over the budget.
        let target = Double(StoryVideoEncoder.videoBitrate(size: shown, fps: fps, hevc: hevc, seconds: seconds))
        let allowance = min(StoryVideoEncoder.budgetBytes, seconds * (target * 1.5 + 160_000) / 8)
        guard let bytes = try? asset.url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              Double(bytes) <= allowance else { return nil }

        let out = FileManager.default.temporaryDirectory.appendingPathComponent("storycopy-\(UUID().uuidString).mp4")
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough)
        else { return nil }
        session.shouldOptimizeForNetworkUse = true
        session.metadataItemFilter = AVMetadataItemFilter.forSharing()
        do { try await session.export(to: out, as: .mp4) } catch { return nil }
        defer { try? FileManager.default.removeItem(at: out) }
        let result = AVURLAsset(url: out)
        let meta = ((try? await result.load(.metadata)) ?? []) + ((try? await result.load(.commonMetadata)) ?? [])
        let located = meta.contains { item in
            item.commonKey == .commonKeyLocation
                || ((item.key as? String)?.lowercased().contains("location") ?? false)
        }
        guard !located else { return nil }
        return try? Data(contentsOf: out)
    }
}
