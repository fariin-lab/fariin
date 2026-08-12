import Foundation
import AVFoundation
import UIKit
import StoryUI

// âš ï¸ AVAILABLE IN TESTFLIGHT, NEVER IN THE APP STORE â€” and `#if DEBUG` was the wrong gate.
//
// These shipped in build 550 behind `#if DEBUG` and were therefore in NO build he can run. The
// TestFlight lane builds `configuration: "Release"` (`fastlane/Fastfile`), and he has no Mac, so
// every build that reaches his phone is a Release build. A debug-only test aid is a test aid he can
// never use. See `isAvailable`.
//
// MEDIA FOR THE DEMO STORY PEOPLE, MADE ON THIS PHONE AND PLANTED WHERE THE REAL CODE LOOKS.
//
// The demo groups this feeds used to point at `picsum.photos` and `pravatar.cc`, which meant no
// demo story existed without a network, none of them were ever video, and every one of them was a
// real download on a real connection. The story bugs that need demo people are all VIDEO bugs, so
// remote stills could not test the thing they were there to test.
//
// Nothing here talks to a network or to Firebase. Frames are drawn on the device, encoded to a real
// H.264 mp4, and written into the story video cache under the exact name `CacheManager` derives from
// the url â€” so the viewer takes its ordinary "already downloaded" path and never learns these clips
// are synthetic. Same for the posters and avatars, which go into `URLCache` and `DiskImageCache`
// because that is where `ImageLoader` and `AvatarView` read.
//
// âš ï¸ THE CLIPS CARRY A RUNNING CLOCK ON PURPOSE. Every frame prints its own timestamp and draws a
// moving bar, so a frame from second 4 is unmistakably not a frame from second 0. Half the bugs in
// this area are "the picture jumped back to the start for one frame", and against a plain gradient
// that is invisible.
enum DemoStoryMedia {

    /// WHERE THE DEMO PEOPLE ARE OFFERED AT ALL: debug builds and TestFlight, never the App Store.
    ///
    /// A TestFlight (and debug-signed) install carries a `sandboxReceipt`; an App Store install
    /// carries a `receipt`. That is the only distinction available inside the app, and it is the one
    /// that matches the actual requirement â€” testers can reach these, the public never sees the
    /// switch.
    ///
    /// âš ï¸ THE SAFETY OF THIS FEATURE WAS NEVER THE COMPILE FLAG. These people exist only in this
    /// device's caches: their media is drawn and encoded here, nothing is uploaded, no story doc is
    /// written, and `StoriesRepository.isDemoAuthor` keeps view receipts and watermarks from ever
    /// reaching the database for them. The switch also defaults OFF. Widening the gate from debug to
    /// TestFlight changes who can turn them on, not what they touch.
    static var isAvailable: Bool {
        #if DEBUG
        return true
        #else
        return Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"
        #endif
    }

    /// A host that cannot resolve, so a mistake here fails loudly instead of fetching something.
    private static let host = "https://fariin.local"

    // MARK: - Public shape

    struct Clip {
        let mediaUrl: String
        let thumbUrl: String
        let seconds: Double
    }

    /// Build (once) and return the url of a demo video story, or nil if encoding failed.
    ///
    /// Safe to call repeatedly: the second call finds the file on disk and returns immediately, and
    /// the file survives relaunches, so this costs one encode per clip per install.
    static func video(_ name: String, seconds: Double, top: UIColor, bottom: UIColor, title: String) -> Clip? {
        let mediaUrl = "\(host)/demo-\(name).mp4"
        let thumbUrl = "\(host)/demo-\(name)-thumb.jpg"
        guard let dest = cacheFile(for: mediaUrl) else { return nil }
        if !isUsable(dest), !encode(to: dest, seconds: seconds, top: top, bottom: bottom, title: title) {
            return nil
        }
        // The poster is the clip's own opening frame, which is what a real upload's `thumb.jpg` is.
        plantImage(frame(at: 0, of: seconds, top: top, bottom: bottom, title: title), at: thumbUrl)
        return Clip(mediaUrl: mediaUrl, thumbUrl: thumbUrl, seconds: seconds)
    }

    /// A still story. Planted in `URLCache`, which is the first place `ImageLoader` looks.
    static func image(_ name: String, top: UIColor, bottom: UIColor, title: String,
                      size: CGSize = CGSize(width: 1080, height: 1920)) -> String {
        let url = "\(host)/demo-\(name).jpg"
        plantImage(still(size: size, top: top, bottom: bottom, title: title, clock: nil), at: url)
        return url
    }

    /// A round portrait. Avatars are read from `DiskImageCache`, NOT `URLCache` â€” see the note on
    /// `DemoMode.profilePhoto`, which found this the hard way â€” so it goes in both.
    static func avatar(_ name: String, top: UIColor, bottom: UIColor, initial: String) -> String {
        let url = "\(host)/demo-pp-\(name).jpg"
        let img = still(size: CGSize(width: 600, height: 600), top: top, bottom: bottom,
                        title: initial, clock: nil, fontSize: 260)
        if let data = img.jpegData(compressionQuality: 0.9) {
            DiskImageCache.shared.store(img, data: data, for: url)
        }
        plantImage(img, at: url)
        return url
    }

    // MARK: - Where the real code looks

    /// âš ï¸ MIRRORS `CacheManager.cacheFileName` AND MUST KEEP MIRRORING IT. That type is internal to
    /// StoryUI, so this cannot call it. The rule there is `lastPathComponent` with slashes flattened;
    /// every url built above is a plain single-component name, so both derivations agree trivially â€”
    /// which is the reason they are plain. Do not put a percent-encoded path in one of these.
    private static func cacheFile(for urlString: String) -> URL? {
        guard let url = URL(string: urlString) else { return nil }
        let name = url.lastPathComponent.replacingOccurrences(of: "/", with: "_")
        guard !name.isEmpty else { return nil }
        return StoryStorage.directory("VideoCache").appendingPathComponent(name)
    }

    /// The same floor `CacheManager.isUsableCacheFile` applies, for the same reason: a half-written
    /// file that merely EXISTS would be handed to a player and wedge the story for good.
    private static func isUsable(_ file: URL) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
              let size = attrs[.size] as? Int else { return false }
        return size > 4096
    }

    private static func plantImage(_ img: UIImage, at urlString: String) {
        guard let url = URL(string: urlString),
              let data = img.jpegData(compressionQuality: 0.85) else { return }
        guard URLCache.shared.cachedResponse(for: URLRequest(url: url)) == nil else { return }
        let resp = URLResponse(url: url, mimeType: "image/jpeg",
                               expectedContentLength: data.count, textEncodingName: nil)
        URLCache.shared.storeCachedResponse(CachedURLResponse(response: resp, data: data),
                                            for: URLRequest(url: url))
    }

    // MARK: - Drawing

    private static func still(size: CGSize, top: UIColor, bottom: UIColor, title: String,
                              clock: Double?, fontSize: CGFloat = 120) -> UIImage {
        UIGraphicsImageRenderer(size: size).image { ctx in
            draw(in: ctx.cgContext, size: size, top: top, bottom: bottom,
                 title: title, clock: clock, fontSize: fontSize)
        }
    }

    private static func frame(at second: Double, of total: Double,
                              top: UIColor, bottom: UIColor, title: String) -> UIImage {
        still(size: CGSize(width: 720, height: 1280), top: top, bottom: bottom,
              title: title, clock: second / max(total, 0.001))
    }

    /// One frame. `clock` is 0...1 through the clip, and nil for a still.
    private static func draw(in cg: CGContext, size: CGSize, top: UIColor, bottom: UIColor,
                             title: String, clock: Double?, fontSize: CGFloat = 120) {
        if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: [top.cgColor, bottom.cgColor] as CFArray, locations: [0, 1]) {
            cg.drawLinearGradient(g, start: .zero,
                                  end: CGPoint(x: size.width, y: size.height), options: [])
        }
        let para = NSMutableParagraphStyle(); para.alignment = .center
        (title as NSString).draw(
            in: CGRect(x: 0, y: size.height * 0.30, width: size.width, height: fontSize * 1.6),
            withAttributes: [.foregroundColor: UIColor.white,
                             .font: UIFont.systemFont(ofSize: fontSize, weight: .heavy),
                             .paragraphStyle: para])
        guard let clock else { return }
        // THE PART THAT MAKES A FLASH VISIBLE: the second, printed, and a bar that crosses the
        // screen once. A frame from the middle of the clip cannot be mistaken for the opening one.
        let seconds = String(format: "%.1fs", clock * clockTotal)
        (seconds as NSString).draw(
            in: CGRect(x: 0, y: size.height * 0.48, width: size.width, height: 200),
            withAttributes: [.foregroundColor: UIColor.white,
                             .font: UIFont.monospacedDigitSystemFont(ofSize: 150, weight: .black),
                             .paragraphStyle: para])
        let barY = size.height * 0.68, barH: CGFloat = 26
        cg.setFillColor(UIColor.white.withAlphaComponent(0.25).cgColor)
        cg.fill(CGRect(x: 60, y: barY, width: size.width - 120, height: barH))
        cg.setFillColor(UIColor.white.cgColor)
        cg.fill(CGRect(x: 60, y: barY, width: (size.width - 120) * CGFloat(clock), height: barH))
    }

    /// Set for the duration of one encode so `draw` can print real seconds rather than a fraction.
    private nonisolated(unsafe) static var clockTotal: Double = 1

    // MARK: - Encoding

    /// Write a real H.264 mp4. Runs synchronously on whatever thread calls it â€” which is a background
    /// one, because `demoGroups` is built inside `rebuild()` before it hops to the main actor.
    private static func encode(to dest: URL, seconds: Double,
                               top: UIColor, bottom: UIColor, title: String) -> Bool {
        let w = 720, h = 1280
        let fps: Int32 = 30
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".mp4")
        guard let writer = try? AVAssetWriter(outputURL: tmp, fileType: .mp4) else { return false }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: w,
            AVVideoHeightKey: h,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: w,
                kCVPixelBufferHeightKey as String: h,
            ])
        guard writer.canAdd(input) else { return false }
        writer.add(input)
        guard writer.startWriting() else { return false }
        writer.startSession(atSourceTime: .zero)

        clockTotal = seconds
        defer { clockTotal = 1 }
        let size = CGSize(width: w, height: h)
        let total = max(1, Int(seconds * Double(fps)))
        for i in 0..<total {
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.004) }
            guard let pool = adaptor.pixelBufferPool else { return false }
            var out: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) == kCVReturnSuccess,
                  let buf = out else { return false }
            CVPixelBufferLockBaseAddress(buf, [])
            if let cg = CGContext(data: CVPixelBufferGetBaseAddress(buf),
                                  width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(buf),
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) {
                // A bitmap context has its origin at the BOTTOM left and UIKit text does not, so the
                // flip goes on before anything is drawn or every label comes out upside down.
                cg.translateBy(x: 0, y: CGFloat(h))
                cg.scaleBy(x: 1, y: -1)
                UIGraphicsPushContext(cg)
                draw(in: cg, size: size, top: top, bottom: bottom, title: title,
                     clock: Double(i) / Double(total))
                UIGraphicsPopContext()
            }
            CVPixelBufferUnlockBaseAddress(buf, [])
            adaptor.append(buf, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: fps))
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: tmp)
            return false
        }
        try? FileManager.default.createDirectory(at: dest.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: dest)
        do { try FileManager.default.moveItem(at: tmp, to: dest) } catch { return false }
        return true
    }
}
