import XCTest
import SwiftUI
import AVFoundation
@testable import Kulan

// Renders the real repost editor on a simulator and saves what it draws.
//
// Not an assertion suite: the card frame, the author chip and the card / full-screen tap have each
// been "fixed" by reading the code and still did not show on the owner's phone. This puts the
// editor on a screen, saves screenshots and a dump of the frame view's state to /tmp/repost-shots,
// and the workflow uploads that folder, so the next change is made from what the screen showed.
@MainActor
final class RepostEditorRenderTests: XCTestCase {

    private let outDir = URL(fileURLWithPath: "/tmp/repost-shots", isDirectory: true)
    private var window: UIWindow?
    private var log: [String] = []

    private let started = Date()

    override func setUp() async throws {
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let t0 = started
        StoryEditorView.renderProbe = { [weak self] s in
            let line = String(format: "%.2fs ", Date().timeIntervalSince(t0)) + s
            if Thread.isMainThread { MainActor.assumeIsolated { self?.appendProbe(line) } }
        }
    }

    private var lastProbe = ""
    private func appendProbe(_ line: String) {
        // Only changes, so the log reads as a timeline rather than a wall of repeats.
        let body = line.split(separator: " ", maxSplits: 1).last.map(String.init) ?? line
        guard body != lastProbe else { return }
        lastProbe = body
        log.append("probe " + line)
    }

    override func tearDown() async throws {
        StoryEditorView.renderProbe = nil
        flushLog()
        window?.isHidden = true
        window = nil
    }

    // MARK: Video repost

    func testVideoRepostEditorShowsCardFrameAndChip() async throws {
        let clip = try await Self.makeClip()
        let poster = Self.solid(UIColor.systemTeal, size: CGSize(width: 540, height: 960))
        let editor = StoryEditorView(source: poster,
                                     repostOf: StoryRepost(authorUid: "u1", authorName: "Abdi",
                                                           storyId: "s1", modified: false, card: true),
                                     repostAvatar: Self.solid(.systemOrange, size: CGSize(width: 120, height: 120)),
                                     onPosted: {},
                                     sourceVideo: .init(url: clip))
        show(editor)
        try await Task.sleep(for: .seconds(0.6))
        dumpFrames("video, 0.6s after open")
        shoot("video-0.6s")
        try await Task.sleep(for: .seconds(3.4))
        dumpFrames("video, 4s after open")
        shoot("video-open")
        XCTAssertTrue(log.contains { $0.contains("canvas: items=1") }, "canvas never rebuilt after load")
        XCTAssertGreaterThan(visibleFrames(), 0, "name + avatar frame missing on open")
        XCTAssertTrue(log.contains { $0.contains("playing=true") }, "repost clip did not start on its own")

        // The tap: card -> full screen, then back.
        tapCanvas("video tap 1")
        try await Task.sleep(for: .seconds(1.5))
        dumpFrames("video, after tap 1")
        shoot("video-after-tap1")
        XCTAssertEqual(visibleFrames(), 0, "full screen still shows the card frame")
        tapCanvas("video tap 2")
        try await Task.sleep(for: .seconds(1.5))
        dumpFrames("video, after tap 2")
        shoot("video-after-tap2")
        XCTAssertGreaterThan(visibleFrames(), 0, "card frame did not come back")
    }

    // MARK: Photo repost

    func testPhotoRepostEditorTapSwitchesCardAndFullScreen() async throws {
        let full = Self.stripes(size: CGSize(width: 1080, height: 1920))
        let avatar = Self.solid(.systemOrange, size: CGSize(width: 120, height: 120))
        let card = RepostCard.render(full, name: "Abdi", avatar: avatar)
        let editor = StoryEditorView(source: card,
                                     repostOf: StoryRepost(authorUid: "u1", authorName: "Abdi",
                                                           storyId: "s1", modified: false, card: true),
                                     repostFullSource: full,
                                     repostAvatar: avatar,
                                     repostCanvas: RepostCard.edgeColours(full),
                                     onPosted: {})
        show(editor)
        try await Task.sleep(for: .seconds(2))
        dumpImages("photo, open")
        shoot("photo-open")
        XCTAssertTrue(log.contains { $0.contains("canvas: items=1") }, "canvas never rebuilt after load")
        guard let open = largestImage() else { return XCTFail("no picture on open") }

        tapCanvas("photo tap 1")
        try await Task.sleep(for: .seconds(1.5))
        dumpImages("photo, after tap 1")
        shoot("photo-after-tap1")
        guard let afterTap1 = largestImage() else { return XCTFail("no picture after tap 1") }
        XCTAssertFalse(afterTap1 === open, "tap 1 left the same picture on screen")

        tapCanvas("photo tap 2")
        try await Task.sleep(for: .seconds(1.5))
        dumpImages("photo, after tap 2")
        shoot("photo-after-tap2")
        guard let afterTap2 = largestImage() else { return XCTFail("no picture after tap 2") }
        XCTAssertFalse(afterTap2 === afterTap1, "tap 2 left the same picture on screen")
    }

    // MARK: Bisect: which piece stops the canvas from rebuilding

    func testBisectNone() async throws { try await bisect([]) }
    func testBisectCardRect() async throws { try await bisect(["cardRect"]) }
    func testBisectCaption() async throws { try await bisect(["caption"]) }
    func testBisectControls() async throws { try await bisect(["controls"]) }
    func testBisectContent() async throws { try await bisect(["content"]) }
    func testBisectGlass() async throws { try await bisect(["glass"]) }
    func testBisectPad() async throws { try await bisect(["pad"]) }
    func testBisectOpacity() async throws { try await bisect(["opacity"]) }
    func testBisectKeyboardRule() async throws { try await bisect(["ikb"]) }
    func testBisectAll() async throws { try await bisect(["cardRect", "caption", "controls", "content"]) }

    private func bisect(_ skip: Set<String>) async throws {
        StoryEditorView.renderSkip = skip
        defer { StoryEditorView.renderSkip = [] }
        let clip = try await Self.makeClip()
        let editor = StoryEditorView(source: Self.solid(.systemTeal, size: CGSize(width: 540, height: 960)),
                                     repostOf: StoryRepost(authorUid: "u1", authorName: "Abdi",
                                                           storyId: "s1", modified: false, card: true),
                                     repostAvatar: Self.solid(.systemOrange, size: CGSize(width: 120, height: 120)),
                                     onPosted: {},
                                     sourceVideo: .init(url: clip))
        show(editor)
        try await Task.sleep(for: .seconds(3))
        let rebuilt = log.contains { $0.contains("canvas: items=1") }
        let summary = "BISECT skip=\(skip.sorted()) canvasRebuiltAfterLoad=\(rebuilt)"
        log.append(summary)
        print(summary)
        flushLog()
    }

    // MARK: Helpers

    private func show<V: View>(_ view: V) {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let w = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: UIScreen.main.bounds)
        w.frame = UIScreen.main.bounds
        w.windowLevel = .alert + 1
        w.rootViewController = StoryComposerHostVC(rootView: AnyView(view))
        w.makeKeyAndVisible()
        window = w
        log.append("window \(w.frame) scene=\(scene != nil)")
    }

    private func shoot(_ label: String) {
        guard let w = window else { return }
        // Two captures: the view hierarchy as UIKit draws it, and the screen as the compositor shows
        // it (the clip is Metal, which a hierarchy snapshot may leave blank).
        let r = UIGraphicsImageRenderer(bounds: w.bounds)
        let img = r.image { _ in _ = w.drawHierarchy(in: w.bounds, afterScreenUpdates: true) }
        if let d = img.pngData() { try? d.write(to: outDir.appendingPathComponent("\(label)-hierarchy.png")) }
        flushLog()
    }

    private func flushLog() {
        try? log.joined(separator: "\n").write(to: outDir.appendingPathComponent("\(name.filter { $0.isLetter || $0.isNumber })-log.txt"),
                                               atomically: true, encoding: .utf8)
    }

    private func all(_ v: UIView) -> [UIView] { [v] + v.subviews.flatMap(all) }

    private func tapCanvas(_ label: String) {
        guard let w = window else { return }
        let taps = all(w).flatMap { v in (v.gestureRecognizers ?? []).compactMap { g -> (UITapGestureRecognizer, ZoomableImageView.Coordinator)? in
            guard let t = g as? UITapGestureRecognizer, let c = t.delegate as? ZoomableImageView.Coordinator else { return nil }
            return (t, c)
        } }
        log.append("\(label): \(taps.count) canvas tap recogniser(s)")
        taps.first.map { $0.1.handleTap($0.0) }
    }

    private func dumpFrames(_ label: String) {
        guard let w = window else { return }
        let frames = all(w).compactMap { $0 as? RepostCardFrameView }
        log.append("== \(label): \(frames.count) RepostCardFrameView")
        for f in frames {
            log.append("  frame hidden=\(f.isHidden) alpha=\(f.alpha) bounds=\(f.bounds) window=\(f.window != nil)")
            var p: UIView? = f.superview
            var chain: [String] = []
            while let s = p { chain.append("\(type(of: s))\(s.isHidden ? "[hidden]" : "") a=\(s.alpha) \(s.frame)"); p = s.superview }
            log.append("  chain: " + chain.prefix(6).joined(separator: " <- "))
            if let sup = f.superview {
                log.append("  siblings (back to front): " + sup.subviews.map { "\(type(of: $0))\($0.isHidden ? "[hidden]" : "") \($0.frame) t=\($0.transform.a)" }.joined(separator: " | "))
            }
            for s in f.subviews { log.append("    sub \(type(of: s)) hidden=\(s.isHidden) frame=\(s.frame)") }
            for l in f.layer.sublayers ?? [] { log.append("    layer \(type(of: l)) frame=\(l.frame) mask=\(l.mask != nil)") }
        }
        dumpImages(label)
    }

    private func visibleFrames() -> Int {
        guard let w = window else { return 0 }
        return all(w).compactMap { $0 as? RepostCardFrameView }.filter { !$0.isHidden && $0.alpha > 0 }.count
    }

    private func largestImage() -> UIImage? {
        guard let w = window else { return nil }
        return all(w).compactMap { ($0 as? UIImageView)?.image }.filter { $0.size.width > 300 }
            .max { $0.size.width * $0.size.height < $1.size.width * $1.size.height }
    }

    private func dumpImages(_ label: String) {
        guard let w = window else { return }
        let ivs = all(w).compactMap { $0 as? UIImageView }.filter { ($0.image?.size.width ?? 0) > 300 }
        log.append("-- \(label): large image views: " + ivs.map { "\($0.image!.size) t=\($0.transform.a) hidden=\($0.isHidden) win=\($0.window != nil) frame=\($0.frame)" }.joined(separator: " | "))
    }

    private static func solid(_ c: UIColor, size: CGSize) -> UIImage {
        UIGraphicsImageRenderer(size: size, format: { let f = UIGraphicsImageRendererFormat(); f.scale = 1; return f }())
            .image { ctx in c.setFill(); ctx.fill(CGRect(origin: .zero, size: size)) }
    }

    private static func stripes(size: CGSize) -> UIImage {
        UIGraphicsImageRenderer(size: size, format: { let f = UIGraphicsImageRendererFormat(); f.scale = 1; return f }())
            .image { ctx in
                let colours: [UIColor] = [.systemRed, .systemYellow, .systemGreen, .systemBlue, .systemPurple]
                let h = size.height / CGFloat(colours.count)
                for (i, c) in colours.enumerated() {
                    c.setFill(); ctx.fill(CGRect(x: 0, y: CGFloat(i) * h, width: size.width, height: h))
                }
            }
    }

    /// A two second 540x960 clip, 30 fps, a bar sweeping down so playback is visible between shots.
    private static func makeClip() async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("repost-test-\(UUID().uuidString).mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let w = 540, h = 960
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for i in 0..<60 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, nil, &pb)
            guard let pb else { continue }
            CVPixelBufferLockBaseAddress(pb, [])
            let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
            let row = CVPixelBufferGetBytesPerRow(pb)
            let bar = (i * h) / 60
            for y in 0..<h {
                let onBar = abs(y - bar) < 40
                for x in 0..<w {
                    let p = base + y * row + x * 4
                    p[0] = onBar ? 255 : 200; p[1] = onBar ? 255 : 120; p[2] = onBar ? 255 : 40; p[3] = 255
                }
            }
            CVPixelBufferUnlockBaseAddress(pb, [])
            adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 30))
        }
        input.markAsFinished()
        await writer.finishWriting()
        return url
    }
}
