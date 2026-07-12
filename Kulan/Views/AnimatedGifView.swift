import SwiftUI
import UIKit
import ImageIO
import CryptoKit

// Persistent disk store for raw GIF bytes (keyed by URL) — so a GIF downloads ONCE and replays from
// disk on every relaunch, no re-download. Application Support (permanent), excluded from backup.
enum GifBytesCache {
    private static var dir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let d = base.appendingPathComponent("gif-cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        var mutable = d; try? mutable.setResourceValues(values)
        return d
    }()
    private static func file(_ url: String) -> URL {
        let key = SHA256.hash(data: Data(url.utf8)).map { String(format: "%02x", $0) }.joined()
        return dir.appendingPathComponent(key).appendingPathExtension("gif")
    }
    static func data(_ url: String) -> Data? { try? Data(contentsOf: file(url)) }
    static func store(_ data: Data, _ url: String) {
        try? data.write(to: file(url), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

// Plays an animated GIF from a URL with zero third-party deps — decodes frames via ImageIO
// into an animated UIImage. Used in the GIF picker and in chat bubbles.
struct AnimatedGifView: UIViewRepresentable {
    let url: String

    private static let cache = NSCache<NSString, UIImage>()   // decoded animated GIFs, reused across instances

    func makeUIView(context: Context) -> UIImageView {
        let v = UIImageView()
        v.contentMode = .scaleAspectFill
        v.clipsToBounds = true
        v.backgroundColor = UIColor.secondarySystemFill
        load(into: v, context.coordinator)
        return v
    }

    func updateUIView(_ v: UIImageView, context: Context) {
        if context.coordinator.loadedURL != url { load(into: v, context.coordinator) }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var loadedURL: String? }

    private func load(into v: UIImageView, _ coord: Coordinator) {
        coord.loadedURL = url   // mark BEFORE loading so re-renders/updates don't re-download+re-decode
        guard let u = URL(string: url) else { return }
        // Memory (decoded) → instant.
        if let cached = Self.cache.object(forKey: url as NSString) { v.image = cached; return }
        // Persistent disk (raw bytes) → decode, no download.
        if let bytes = GifBytesCache.data(url), let img = UIImage.animatedGif(data: bytes) {
            Self.cache.setObject(img, forKey: url as NSString); v.image = img; return
        }
        let requested = url
        URLSession.shared.dataTask(with: u) { data, _, _ in
            guard let data, let img = UIImage.animatedGif(data: data) else { return }
            GifBytesCache.store(data, url)   // persist raw bytes so it never re-downloads
            Self.cache.setObject(img, forKey: url as NSString)
            DispatchQueue.main.async {
                // The view may have been REUSED for a different GIF while this download was in flight
                // (bubble scroll / grid reuse) — only assign if it still wants THIS url, else the old
                // GIF would overwrite the new one (the "wrong GIF flashes" bug).
                guard coord.loadedURL == requested else { return }
                v.image = img
            }
        }.resume()
    }
}

extension UIImage {
    static func animatedGif(data: Data) -> UIImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return UIImage(data: data) }
        let count = CGImageSourceGetCount(src)
        guard count > 1 else { return UIImage(data: data) }
        var frames: [UIImage] = []
        var duration = 0.0
        for i in 0..<count {
            guard let cg = CGImageSourceCreateImageAtIndex(src, i, nil) else { continue }
            frames.append(UIImage(cgImage: cg))
            let props = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any]
            let gif = props?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let delay = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
                ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.1
            duration += max(delay, 0.02)
        }
        return UIImage.animatedImage(with: frames, duration: duration)
    }
}
