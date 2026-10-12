import XCTest
import AVFoundation
import UIKit
@testable import Kulan

// The story encoder, on a simulator, against clips made here. Checks what can be checked without a
// phone: frame rate kept, size, codec, colour tags, audio kept, trim honoured, brightness applied,
// and that the editor's overlay and the repost card land where the editor put them.
// Results are also written to /tmp/repost-shots/encoder-log.txt for the workflow artifact.
final class StoryVideoEncoderTests: XCTestCase {

    private static var log: [String] = []
    override class func tearDown() {
        let dir = URL(fileURLWithPath: "/tmp/repost-shots", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? log.joined(separator: "\n").write(to: dir.appendingPathComponent("encoder-log.txt"), atomically: true, encoding: .utf8)
    }
    private func note(_ s: String) { Self.log.append("\(name): \(s)") }

    // MARK: Tests

    /// The new encoder itself, not the fallback: `prepare` would quietly use the old path if it failed.
    func testEncoderRunsDirectly() async throws {
        let src = try await Self.makeClip(size: CGSize(width: 1080, height: 1920), fps: 60, seconds: 2,
                                          colour: .systemPink, audio: true)
        let edits = StoryVideoEncoder.Edits(overlay: nil, cropRect: nil, canvasAspect: nil, contentScale: 1,
                                            backdrop: nil, holeCorner: 0, brightness: 0,
                                            gradientAspect: nil, hd: false)
        let out = await StoryVideoEncoder.encode(asset: AVURLAsset(url: src),
                                                 range: CMTimeRange(start: .zero, duration: CMTime(seconds: 2, preferredTimescale: 600)),
                                                 stripAudio: false, edits: edits)
        let o = try XCTUnwrap(out, "StoryVideoEncoder.encode returned nil")
        let info = try await Self.inspect(try Data(contentsOf: o.url))
        note("direct " + info.description)
        XCTAssertGreaterThan(info.fps, 55)
        XCTAssertTrue(info.hasAudio)
    }

    func testSixtyFpsPlainClipKeepsFrameRateAndAudio() async throws {
        let src = try await Self.makeClip(size: CGSize(width: 1080, height: 1920), fps: 60, seconds: 3,
                                          colour: .systemGreen, audio: true)
        let p = try unwrap(await VideoTranscoder.prepare(src, maxSeconds: 90, storyBackdrop: true))
        let info = try await Self.inspect(p.data)
        note(info.description)
        XCTAssertEqual(info.size.width, 720, accuracy: 2)
        XCTAssertEqual(info.size.height, 1280, accuracy: 2)
        XCTAssertGreaterThan(info.fps, 55, "60 fps source must stay 60 fps")
        XCTAssertEqual(info.duration, 3, accuracy: 0.15)
        XCTAssertTrue(info.hasAudio, "audio must be kept")
        XCTAssertEqual(info.audioDuration, 3, accuracy: 0.25)
        XCTAssertEqual(info.primaries, AVVideoColorPrimaries_ITU_R_709_2)
    }

    func testThirtyFpsTrimmedSegment() async throws {
        let src = try await Self.makeClip(size: CGSize(width: 1080, height: 1920), fps: 30, seconds: 4,
                                          colour: .systemBlue, audio: true)
        let range = CMTimeRange(start: CMTime(seconds: 1, preferredTimescale: 600),
                                duration: CMTime(seconds: 2, preferredTimescale: 600))
        let p = try unwrap(await VideoTranscoder.prepare(src, maxSeconds: 90, range: range, storyBackdrop: true))
        let info = try await Self.inspect(p.data)
        note(info.description)
        XCTAssertEqual(info.duration, 2, accuracy: 0.15)
        XCTAssertEqual(info.fps, 30, accuracy: 2)
    }

    func testBrightnessIsOneEncodeAndBrighter() async throws {
        let grey = UIColor(white: 0.4, alpha: 1)
        let src = try await Self.makeClip(size: CGSize(width: 720, height: 1280), fps: 30, seconds: 2,
                                          colour: grey, audio: false)
        let p = try unwrap(await VideoTranscoder.prepare(src, maxSeconds: 90, storyBackdrop: true, brightness: 0.5))
        let url = try Self.write(p.data)
        let px = try await Self.pixel(url, at: CGPoint(x: 0.5, y: 0.5))
        note("centre after brightness \(px)")
        XCTAssertGreaterThan(px.g, 0.5, "brightness must lift a 0.4 grey")
    }

    func testRepostCardAndOverlayLandWhereTheEditorPutThem() async throws {
        let src = try await Self.makeClip(size: CGSize(width: 1080, height: 1920), fps: 30, seconds: 2,
                                          colour: .green, audio: false)
        // Overlay: a magenta square near the TOP-LEFT of the canvas, transparent elsewhere.
        let canvas = CGSize(width: 1080, height: 1920)
        let overlay = UIGraphicsImageRenderer(size: canvas, format: { let f = UIGraphicsImageRendererFormat(); f.scale = 1; f.opaque = false; return f }())
            .image { ctx in UIColor.magenta.setFill(); ctx.fill(CGRect(x: 54, y: 96, width: 216, height: 192)) }
        let backdrop = Self.solid(.yellow, size: canvas)
        let p = try unwrap(await VideoTranscoder.prepare(src, maxSeconds: 90, overlay: overlay,
                                                            canvasAspect: 9.0 / 16.0, contentScale: 0.8,
                                                            backdrop: backdrop, storyBackdrop: true,
                                                            holeCorner: 0.04))
        let url = try Self.write(p.data)
        let topLeft = try await Self.pixel(url, at: CGPoint(x: 0.15, y: 0.10))      // inside the magenta square
        let bottomLeft = try await Self.pixel(url, at: CGPoint(x: 0.15, y: 0.90))   // same x, near the bottom
        let surround = try await Self.pixel(url, at: CGPoint(x: 0.04, y: 0.5))      // outside the 80% card
        let centre = try await Self.pixel(url, at: CGPoint(x: 0.5, y: 0.5))
        note("topLeft \(topLeft) bottomLeft \(bottomLeft) surround \(surround) centre \(centre)")
        XCTAssertTrue(topLeft.r > 0.7 && topLeft.b > 0.7 && topLeft.g < 0.35, "overlay must be at the top")
        XCTAssertFalse(bottomLeft.r > 0.7 && bottomLeft.b > 0.7, "overlay must not be flipped to the bottom")
        XCTAssertTrue(surround.r > 0.7 && surround.g > 0.7 && surround.b < 0.35, "surround must be the backdrop")
        XCTAssertTrue(centre.g > 0.6 && centre.r < 0.4, "the clip must be in the middle")
    }

    func testLandscapeClipGetsGradientCanvas() async throws {
        let src = try await Self.makeClip(size: CGSize(width: 1280, height: 720), fps: 30, seconds: 2,
                                          colour: .red, audio: false)
        let p = try unwrap(await VideoTranscoder.prepare(src, maxSeconds: 90, storyBackdrop: true))
        let info = try await Self.inspect(p.data)
        note(info.description)
        XCTAssertEqual(info.size.width / info.size.height, 9.0 / 16.0, accuracy: 0.01)
        let url = try Self.write(p.data)
        let centre = try await Self.pixel(url, at: CGPoint(x: 0.5, y: 0.5))
        note("landscape centre \(centre)")
        XCTAssertTrue(centre.r > 0.6 && centre.g < 0.4, "the clip must sit in the middle of the canvas")
    }

    func testRepostHdIs1080() async throws {
        let src = try await Self.makeClip(size: CGSize(width: 1080, height: 1920), fps: 30, seconds: 2,
                                          colour: .orange, audio: false)
        // A pinched card makes it a composed (edited) repost, which is always encoded.
        let p = try unwrap(await VideoTranscoder.prepare(src, maxSeconds: 90, hd: true, canvasAspect: 9.0 / 16.0,
                                                            contentScale: 0.8, backdrop: Self.solid(.gray, size: CGSize(width: 1080, height: 1920)),
                                                            storyBackdrop: true, holeCorner: 0.04))
        let info = try await Self.inspect(p.data)
        note(info.description)
        XCTAssertEqual(info.size.height, 1920, accuracy: 2)
    }

    struct Missing: Error {}
    static func unwrap<T>(_ v: T?, _ what: String = "value") throws -> T {
        guard let v else { XCTFail("missing (what)"); throw Missing() }
        return v
    }
    func unwrap<T>(_ v: T?) throws -> T { try Self.unwrap(v) }

    // MARK: Inspection

    struct Info: CustomStringConvertible {
        var size: CGSize; var fps: Double; var duration: Double; var codec: String
        var hasAudio: Bool; var audioDuration: Double; var primaries: String?; var bytes: Int
        var description: String {
            "size=\(size) fps=\(fps) dur=\(duration) codec=\(codec) audio=\(hasAudio)/\(audioDuration) primaries=\(primaries ?? "nil") bytes=\(bytes) mbps=\(Double(bytes) * 8 / max(0.01, duration) / 1e6)"
        }
    }

    static func write(_ data: Data) throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("enc-\(UUID().uuidString).mp4")
        try data.write(to: u); return u
    }

    static func inspect(_ data: Data) async throws -> Info {
        let asset = AVURLAsset(url: try write(data))
        let v = try unwrap(try await asset.loadTracks(withMediaType: .video).first)
        let size = try await v.load(.naturalSize).applying(try await v.load(.preferredTransform))
        let fps = Double(try await v.load(.nominalFrameRate))
        let dur = try await asset.load(.duration).seconds
        let fmt = try await v.load(.formatDescriptions).first
        let sub = fmt.map { CMFormatDescriptionGetMediaSubType($0) } ?? 0
        let codec = sub == kCMVideoCodecType_HEVC ? "hevc" : sub == kCMVideoCodecType_H264 ? "h264" : "\(sub)"
        let prim = fmt.flatMap { CMFormatDescriptionGetExtension($0, extensionKey: kCMFormatDescriptionExtension_ColorPrimaries) as? String }
        let a = try await asset.loadTracks(withMediaType: .audio).first
        let ad = try await a?.load(.timeRange).duration.seconds ?? 0
        return Info(size: CGSize(width: abs(size.width), height: abs(size.height)), fps: fps, duration: dur,
                    codec: codec, hasAudio: a != nil, audioDuration: ad, primaries: prim, bytes: data.count)
    }

    struct RGB: CustomStringConvertible {
        let r: Double, g: Double, b: Double
        var description: String { String(format: "(%.2f %.2f %.2f)", r, g, b) }
    }

    /// The colour at a point given as fractions of the frame, measured from the TOP-LEFT.
    static func pixel(_ url: URL, at p: CGPoint) async throws -> RGB {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .zero; gen.requestedTimeToleranceAfter = .zero
        let cg = try await gen.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)).image
        var px = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let x = CGFloat(cg.width) * p.x, yTop = CGFloat(cg.height) * p.y
        // CGContext is bottom-left: draw the image so the wanted pixel lands on (0,0).
        ctx.draw(cg, in: CGRect(x: -x, y: -(CGFloat(cg.height) - yTop), width: CGFloat(cg.width), height: CGFloat(cg.height)))
        return RGB(r: Double(px[0]) / 255, g: Double(px[1]) / 255, b: Double(px[2]) / 255)
    }

    // MARK: Clip maker

    static func solid(_ c: UIColor, size: CGSize) -> UIImage {
        UIGraphicsImageRenderer(size: size, format: { let f = UIGraphicsImageRendererFormat(); f.scale = 1; return f }())
            .image { ctx in c.setFill(); ctx.fill(CGRect(origin: .zero, size: size)) }
    }

    static func makeClip(size: CGSize, fps: Int, seconds: Double, colour: UIColor, audio: Bool) async throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
        let videoURL = tmp.appendingPathComponent("v-\(UUID().uuidString).mov")
        let w = Int(size.width), h = Int(size.height)
        let writer = try AVAssetWriter(outputURL: videoURL, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 20_000_000]])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        let frames = Int(Double(fps) * seconds)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        colour.getRed(&r, green: &g, blue: &b, alpha: &a)
        for i in 0..<frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            var pb: CVPixelBuffer?
            if let pool = adaptor.pixelBufferPool { CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb) }
            if pb == nil { CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, nil, &pb) }
            let buf = try XCTUnwrap(pb)
            CVPixelBufferLockBaseAddress(buf, [])
            let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buf), width: w, height: h, bitsPerComponent: 8,
                                bytesPerRow: CVPixelBufferGetBytesPerRow(buf), space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
            ctx.setFillColor(red: r, green: g, blue: b, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            // A small moving tick so consecutive frames differ (an encoder may merge identical ones).
            ctx.setFillColor(red: 1 - r, green: 1 - g, blue: 1 - b, alpha: 1)
            ctx.fill(CGRect(x: (i * 7) % max(1, w - 8), y: 0, width: 8, height: 8))
            CVPixelBufferUnlockBaseAddress(buf, [])
            adaptor.append(buf, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard audio else { return videoURL }

        // A sine tone the same length, then both tracks muxed into one file.
        let audioURL = tmp.appendingPathComponent("a-\(UUID().uuidString).m4a")
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        do {
            let file = try AVAudioFile(forWriting: audioURL, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1])
            let count = AVAudioFrameCount(44_100 * seconds)
            let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count)!
            pcm.frameLength = count
            let data = pcm.floatChannelData![0]
            for i in 0..<Int(count) { data[i] = 0.3 * sinf(Float(i) * 2 * .pi * 440 / 44_100) }
            try file.write(from: pcm)
        }
        let comp = AVMutableComposition()
        let vAsset = AVURLAsset(url: videoURL), aAsset = AVURLAsset(url: audioURL)
        let vt = try await vAsset.loadTracks(withMediaType: .video).first!
        let at = try await aAsset.loadTracks(withMediaType: .audio).first!
        let span = CMTimeRange(start: .zero, duration: try await vAsset.load(.duration))
        try comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
            .insertTimeRange(span, of: vt, at: .zero)
        let aSpan = CMTimeRange(start: .zero, duration: min(span.duration, try await aAsset.load(.duration)))
        try comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
            .insertTimeRange(aSpan, of: at, at: .zero)
        let out = tmp.appendingPathComponent("av-\(UUID().uuidString).mov")
        let session = try XCTUnwrap(AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetPassthrough))
        try await session.export(to: out, as: .mov)
        return out
    }
}
