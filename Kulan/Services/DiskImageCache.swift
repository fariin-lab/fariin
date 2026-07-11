import UIKit
import CryptoKit

extension UIImage {
    // Signal's quantized-decode idea: never hold a bitmap bigger than the screen needs. A 12MP photo
    // decodes to ~48MB; bounded to 2048px it's ~12MB with no visible difference in a bubble or a
    // full-screen view (deep pinch-zoom re-reads the full bytes from disk if ever needed).
    func boundedForDisplay(maxPixels: CGFloat = 2048) -> UIImage {
        let w = size.width * scale, h = size.height * scale
        let m = max(w, h)
        guard m > maxPixels else { return self }
        let f = maxPixels / m
        let target = CGSize(width: floor(w * f), height: floor(h * f))
        return preparingThumbnail(of: target) ?? self
    }
}

// Two-tier media cache: NSCache (memory) + persistent disk (app Caches dir).
//
// Once an image or story is fetched it is written to disk, so reopening a chat /
// story or relaunching the app loads it INSTANTLY from local storage with no
// network request — and it stays viewable offline (WhatsApp/Messenger behaviour).
//
// Encrypted chat media is stored DECRYPTED but with iOS file protection
// (.completeFileProtectionUnlessOpen), so it is encrypted at rest while the device
// is locked — the standard approach used by Signal/WhatsApp.
//
// A size budget (LRU by last-access date) keeps the cache from bloating storage;
// iOS may additionally purge the Caches dir under storage pressure, which is fine.
final class DiskImageCache {
    static let shared = DiskImageCache()

    private let mem = NSCache<NSString, UIImage>()
    private let dir: URL
    private let io = DispatchQueue(label: "DiskImageCache.io", qos: .utility)
    private let maxBytes = 250 * 1024 * 1024   // 250 MB budget

    private init() {
        mem.countLimit = 250
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        dir = caches.appendingPathComponent("MediaCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Signal's LRUCache evacuates in the background: decoded UIImages are the app's biggest heap
        // objects, and a backgrounded app holding hundreds of them is first in line for jetsam (and
        // background thermal work). The disk tier stays, so reopening is still instant.
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.mem.removeAllObjects()
        }
    }

    private func key(_ url: String) -> String {
        SHA256.hash(data: Data(url.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private func fileURL(_ url: String) -> URL {
        dir.appendingPathComponent(key(url)).appendingPathExtension("img")
    }

    /// Synchronous MEMORY-only lookup (instant; safe on the main thread).
    func memoryImage(_ url: String) -> UIImage? {
        mem.object(forKey: url as NSString)
    }

    /// Memory hit → instant. Otherwise read from disk off-main, decode, and promote
    /// to memory. Returns nil if not cached anywhere (caller should then download).
    func image(for url: String) async -> UIImage? {
        if let m = mem.object(forKey: url as NSString) { return m }
        return await withCheckedContinuation { cont in
            io.async {
                let f = self.fileURL(url)
                guard let data = try? Data(contentsOf: f), let raw = UIImage(data: data) else {
                    cont.resume(returning: nil); return
                }
                // Force the bitmap decode NOW (off-main) — UIImage(data:) is lazy and would
                // otherwise decode on the main thread at draw time, causing scroll hitches.
                // Bounded to display size so a huge original never becomes a huge bitmap in memory.
                let bounded = raw.boundedForDisplay()
                let img = (bounded === raw ? raw.preparingForDisplay() : bounded) ?? raw
                self.mem.setObject(img, forKey: url as NSString)
                // Touch the file so LRU trimming keeps recently-viewed media.
                try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: f.path)
                cont.resume(returning: img)
            }
        }
    }

    /// Store a decoded image in memory + persist its bytes to disk. Pass the original
    /// `data` when available to avoid a re-encode; otherwise it is JPEG-encoded.
    func store(_ image: UIImage, data: Data? = nil, for url: String) {
        mem.setObject(image, forKey: url as NSString)
        let bytes = data ?? image.jpegData(compressionQuality: 0.85)
        guard let bytes else { return }
        let f = fileURL(url)
        io.async { [weak self] in
            try? bytes.write(to: f, options: [.atomic, .completeFileProtectionUnlessOpen])
            self?.trimIfNeeded()
        }
    }

    /// Total bytes currently on disk (for the Settings "storage used" readout).
    func diskBytes() -> Int {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return items.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
    }

    /// Wipe both tiers (Settings → Clear Cache).
    func clear() {
        mem.removeAllObjects()
        io.async { [weak self] in
            guard let self else { return }
            let fm = FileManager.default
            if let items = try? fm.contentsOfDirectory(at: self.dir, includingPropertiesForKeys: nil) {
                for u in items { try? fm.removeItem(at: u) }
            }
        }
    }

    // Drop the oldest files once the budget is exceeded (LRU by modification date).
    private func trimIfNeeded() {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else { return }
        var files = items.compactMap { u -> (URL, Int, Date)? in
            guard let v = try? u.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                  let size = v.fileSize, let date = v.contentModificationDate else { return nil }
            return (u, size, date)
        }
        var total = files.reduce(0) { $0 + $1.1 }
        guard total > maxBytes else { return }
        files.sort { $0.2 < $1.2 }   // oldest first
        for (u, size, _) in files where total > maxBytes {
            try? fm.removeItem(at: u); total -= size
        }
    }
}
