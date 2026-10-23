import UIKit
import Compression

// ⛔ ANIMATED .TGS STICKERS — owner 2026-10-21 (play natively, never converted), REBUILT 2026-10-23
// on his report "when I send an animated sticker my app becomes lag", the reference app's way.
//
// WHAT WAS WRONG: every tile and every chat bubble built its own LottieAnimationView (a layer tree
// per sticker, 60 fps at 512 px, built on the main thread, torn down and rebuilt on every scroll,
// reuse and reload), and the engine was never pinned, so a file the Core Animation engine refused
// was redrawn on the main thread every frame. Twelve in the panel plus the new one in the chat.
//
// WHAT THE REFERENCE APP DOES, read from its source (2026-10-23, five-agent read):
//   • rlottie rasterises each frame into a plain bitmap on background queues; the main thread only
//     sets `layer.contents`, once per tick for ALL stickers together.
//   • the panel draws at most 2x the point size and stores Lottie at half its frame rate (30 fps);
//     the chat draws into a box of at most 384 px at the file's own rate.
//   • only stickers that are on screen play; scrolling does not stop them.
//
// HERE: `TGSEngine` = one CADisplayLink, two serial render queues, rlottie (librlottie, MIT at the
// pinned commit). A sticker's parsed document lives on ONE queue (picked by its key), because an
// rlottie handle must not be used from two threads. `TGSPlayer` is a plain CALayer a view hosts.
// No Core Animation is touched off the main thread, so the 1009 crash (a CATransaction committed on
// a render queue) cannot come back: render queues only produce CGImages.
enum TGSSticker {
    static func isTGS(_ url: URL) -> Bool { url.pathExtension.lowercased() == "tgs" }

    /// The gzip magic. WebP starts "RIFF" and PNG 0x89 "PNG", so this never mistakes one for them.
    static func isTGS(_ data: Data) -> Bool {
        data.count > 18 && data[data.startIndex] == 0x1f && data[data.startIndex + 1] == 0x8b
    }

    private static let stills: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 64
        return c
    }()

    /// A still for places that want a picture (the reply quote). Drawn by rlottie right here: one
    /// small frame, no layer tree. Frame 0, or the middle frame when frame 0 is nearly empty
    /// (stickers that start blank, like the Mice Hugs pack).
    static func still(url: URL, side: CGFloat) -> UIImage? {
        let key = "\(url.path)#\(Int(side))" as NSString
        if let hit = stills.object(forKey: key) { return hit }
        guard let data = try? Data(contentsOf: url), let doc = TGSDoc(data) else { return nil }
        let scale = UIScreen.main.scale
        let px = max(1, Int(side * scale))
        guard let cg = doc.still(px) else { return nil }
        let img = UIImage(cgImage: cg, scale: scale, orientation: .up)
        stills.setObject(img, forKey: key)
        return img
    }

    /// The panel tile's still: the shipped `_still.png` when there is one, else drawn by rlottie,
    /// all off the main thread. `done` runs on main.
    @MainActor static func stillAsync(url: URL, side: CGFloat, _ done: @escaping (UIImage?) -> Void) {
        let key = "\(url.path)#\(Int(side))" as NSString
        if let hit = stills.object(forKey: key) { done(hit); return }
        let scale = UIScreen.main.scale
        let shipped = URL(fileURLWithPath: url.deletingPathExtension().path + "_still.png")
        diskQueue.async {
            var img: UIImage?
            if let data = try? Data(contentsOf: shipped) {
                img = UIImage(data: data)?.preparingForDisplay()
            } else if let data = try? Data(contentsOf: url), let doc = TGSDoc(data),
                      let cg = doc.still(max(1, Int(side * scale))) {
                img = UIImage(cgImage: cg, scale: scale, orientation: .up)
            }
            DispatchQueue.main.async {
                if let img { stills.setObject(img, forKey: key) }
                done(img)
            }
        }
    }

    private static let diskQueue = DispatchQueue(label: "TGSStills", qos: .userInitiated)


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
