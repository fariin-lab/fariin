import UIKit
import Compression
import Lottie

// ⛔ ANIMATED .TGS STICKERS, PLAYED AS VECTORS — owner 2026-10-21: stickers in the .tgs format
// (gzip-compressed Lottie JSON, 512x512 canvas, usually 60 fps, about 3 s) play natively and loop,
// in the panel and in the chat, as the reference app does. Never converted to WebP (he said no).
//
//   • unzip: Foundation has no gzip. The gzip wrapper is read by hand (RFC 1952: 10-byte header,
//     optional extra / name / comment / header-crc fields, 8-byte trailer) and the deflate stream
//     inside is handed to Apple's Compression framework, whose COMPRESSION_ZLIB is RAW deflate
//     (RFC 1951) — exactly what sits between the gzip header and trailer. The trailer's ISIZE gives
//     the output size up front, so it is one `compression_decode_buffer` call, no streaming loop.
//     No zlib module import (whether `import zlib` resolves differs between SDKs).
//   • decode: `LottieAnimation.from(data:)`, off the main thread, cached by file (NSCache).
//   • draw: `TGSFramePlayer` draws frames off the main thread into bitmaps and swaps them on screen
//     (a LottieAnimationView per sticker lagged, owner's second report 2026-10-21). The views that
//     host it decide when it plays (only on screen, never in Low Power Mode), as they do for WebP.
//   • a still, where the app needs a picture (the reply quote): frame 0 drawn once by the main-thread
//     engine into a UIImage, cached.
enum TGSSticker {
    static func isTGS(_ url: URL) -> Bool { url.pathExtension.lowercased() == "tgs" }

    /// The gzip magic. WebP starts "RIFF" and PNG 0x89 "PNG", so this never mistakes one for them.
    static func isTGS(_ data: Data) -> Bool {
        data.count > 18 && data[data.startIndex] == 0x1f && data[data.startIndex + 1] == 0x8b
    }

    private static let animations: NSCache<NSString, LottieAnimation> = {
        let c = NSCache<NSString, LottieAnimation>()
        c.countLimit = 96
        return c
    }()

    private static let stills: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 64
        return c
    }()

    /// Already decoded, or nil. Safe from any thread.
    static func cached(_ key: String) -> LottieAnimation? { animations.object(forKey: key as NSString) }

    /// Off the main thread: reads, unzips and decodes the file once; later calls hit the cache.
    static func animation(url: URL) -> LottieAnimation? {
        let key = url.path
        if let hit = cached(key) { return hit }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return animation(data: data, key: key)
    }

    /// Off the main thread: the same, from bytes already in hand (a chat row's loaded file).
    static func animation(data: Data, key: String) -> LottieAnimation? {
        if let hit = cached(key) { return hit }
        guard let json = isTGS(data) ? gunzip(data) : data,
              let anim = try? LottieAnimation.from(data: json) else { return nil }
        animations.setObject(anim, forKey: key as NSString)
        return anim
    }

    /// Frame 0 as a picture, `side` points square. Drawn once per file and size, then cached.
    @MainActor static func still(url: URL, side: CGFloat) -> UIImage? {
        let key = "\(url.path)#\(Int(side))" as NSString
        if let hit = stills.object(forKey: key) { return hit }
        guard let anim = animation(url: url), let img = still(anim, side: side) else { return nil }
        stills.setObject(img, forKey: key)
        return img
    }

    // MARK: Stills without stutter (owner 2026-10-21: "the sticker keyboard lags when I scroll")

    /// Frame 0 for a tile, never stalling a scroll: memory, then a PNG kept in Caches (read off the
    /// main thread), and only a sticker never seen before is drawn, on the main thread, ONE per run-
    /// loop turn, then written to disk so it is drawn once per phone, ever.
    @MainActor static func stillAsync(url: URL, side: CGFloat, _ done: @escaping (UIImage?) -> Void) {
        let key = "\(url.path)#\(Int(side))" as NSString
        if let hit = stills.object(forKey: key) { done(hit); return }
        let file = stillFile(url, side)
        let scale = UIScreen.main.scale
        // ⛔ SHIPPED STILLS FIRST — owner 2026-10-21, second report of panel lag. Drawing a still
        // on the phone runs Lottie on the main thread, the scroll's own thread. Every bundled pack
        // ships `<name>_still.png` (made once on the build machine, first frame that shows ink), so
        // a bundled sticker never draws one: it is read and decoded here, off the main thread.
        let shipped = URL(fileURLWithPath: url.deletingPathExtension().path + "_still.png")
        diskQueue.async {
            if let data = try? Data(contentsOf: shipped), let img = UIImage(data: data)?.preparingForDisplay() {
                DispatchQueue.main.async { stills.setObject(img, forKey: key); done(img) }
                return
            }
            if let file, let data = try? Data(contentsOf: file), let img = UIImage(data: data, scale: scale) {
                DispatchQueue.main.async { stills.setObject(img, forKey: key); done(img) }
                return
            }
            let anim = animation(url: url)   // decoded here, off the main thread
            DispatchQueue.main.async { enqueueDraw(anim, key: key, file: file, side: side, done) }
        }
    }

    private static let diskQueue = DispatchQueue(label: "TGSStills", qos: .userInitiated)
    @MainActor private static var drawJobs: [() -> Void] = []
    @MainActor private static var drawing = false

    @MainActor private static func enqueueDraw(_ anim: LottieAnimation?, key: NSString, file: URL?, side: CGFloat,
                                               _ done: @escaping (UIImage?) -> Void) {
        drawJobs.append {
            if let hit = stills.object(forKey: key) { done(hit); return }
            guard let anim, let img = still(anim, side: side) else { done(nil); return }
            stills.setObject(img, forKey: key)
            done(img)
            if let file, let png = img.pngData() { diskQueue.async { try? png.write(to: file, options: .atomic) } }
        }
        drainDraws()
    }

    @MainActor private static func drainDraws() {
        guard !drawing, !drawJobs.isEmpty else { return }
        drawing = true
        let job = drawJobs.removeFirst()
        DispatchQueue.main.async {
            job()
            drawing = false
            drainDraws()
        }
    }

    private static func stillFile(_ url: URL, _ side: CGFloat) -> URL? {
        guard let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent("tgsStills", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pack = url.deletingLastPathComponent().lastPathComponent
        let name = url.deletingPathExtension().lastPathComponent
        return dir.appendingPathComponent("\(pack)_\(name)_\(Int(side)).png")
    }

    /// The main-thread engine draws into ordinary layers, which `render(in:)` can copy; the Core
    /// Animation engine's frames live in the render server and would come out blank.
    @MainActor static func still(_ anim: LottieAnimation, side: CGFloat) -> UIImage? {
        guard side > 0 else { return nil }
        let v = LottieAnimationView(animation: anim,
                                    configuration: LottieConfiguration(renderingEngine: .mainThread))
        v.frame = CGRect(x: 0, y: 0, width: side, height: side)
        v.contentMode = .scaleAspectFit
        v.backgroundColor = .clear
        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = false
        func draw(at progress: CGFloat) -> UIImage {
            v.currentProgress = progress
            v.setNeedsLayout()
            v.layoutIfNeeded()
            v.forceDisplayUpdate()
            return UIGraphicsImageRenderer(size: v.bounds.size, format: format).image { ctx in
                v.layer.render(in: ctx.cgContext)
            }
        }
        // ⛔ A STICKER THAT POPS IN STARTS EMPTY — owner 2026-10-21 (Mice Hugs tabs and tiles blank):
        // all 24 of that pack's animations begin on a transparent frame. Frame 0 stays the picture when
        // it shows something; otherwise the middle of the animation is used.
        let first = draw(at: 0)
        return Self.mostlyEmpty(first) ? draw(at: 0.5) : first
    }

    /// Under 3% of a 16x16 sample has any ink.
    private static func mostlyEmpty(_ img: UIImage) -> Bool {
        guard let cg = img.cgImage else { return true }
        let side = 16
        var px = [UInt8](repeating: 0, count: side * side * 4)
        guard let ctx = CGContext(data: &px, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
        var inked = 0
        for i in stride(from: 3, to: px.count, by: 4) where px[i] > 20 { inked += 1 }
        return inked < (side * side * 3) / 100
    }

    // MARK: - gzip

    /// The JSON inside a .tgs, or nil when the wrapper is damaged or the size does not match.
    static func gunzip(_ data: Data) -> Data? {
        let b = [UInt8](data)
        let n = b.count
        // ID1 ID2, CM = 8 (deflate).
        guard n > 18, b[0] == 0x1f, b[1] == 0x8b, b[2] == 8 else { return nil }
        let flags = b[3]
        var i = 10
        if flags & 0x04 != 0 {                       // FEXTRA: 2-byte length, then that many bytes
            guard i + 2 <= n else { return nil }
            i += 2 + (Int(b[i]) | Int(b[i + 1]) << 8)
        }
        if flags & 0x08 != 0 {                       // FNAME: zero-terminated
            while i < n, b[i] != 0 { i += 1 }
            i += 1
        }
        if flags & 0x10 != 0 {                       // FCOMMENT: zero-terminated
            while i < n, b[i] != 0 { i += 1 }
            i += 1
        }
        if flags & 0x02 != 0 { i += 2 }              // FHCRC
        let end = n - 8                              // CRC32 + ISIZE trail the deflate stream
        guard i < end else { return nil }
        // ISIZE: the unzipped length mod 2^32, little-endian. A sticker's JSON is well under 32 MB.
        let size = Int(b[n - 4]) | Int(b[n - 3]) << 8 | Int(b[n - 2]) << 16 | Int(b[n - 1]) << 24
        guard size > 0, size <= 32 * 1024 * 1024 else { return nil }
        // One byte of room past ISIZE: a stream that would overflow it shows up as a wrong count.
        var out = [UInt8](repeating: 0, count: size + 1)
        let written = b.withUnsafeBufferPointer { src -> Int in
            out.withUnsafeMutableBufferPointer { dst -> Int in
                guard let s = src.baseAddress, let d = dst.baseAddress else { return 0 }
                return compression_decode_buffer(d, size + 1, s + i, end - i, nil, COMPRESSION_ZLIB)
            }
        }
        guard written == size else { return nil }
        return Data(out[0..<size])
    }
}
