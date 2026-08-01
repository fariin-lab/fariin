import UIKit
import CryptoKit

extension UIImage {
    // The standard quantized-decode idea: never hold a bitmap bigger than the screen needs. A 12MP photo
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
// network request — and it stays viewable offline (the standard messenger behaviour).
//
// Encrypted chat media is stored DECRYPTED but with iOS file protection
// (.completeFileProtectionUnlessOpen), so it is encrypted at rest while the device
// is locked — the standard approach used by secure messengers.
//
// A size budget (LRU by last-access date) keeps the cache from bloating storage;
// iOS may additionally purge the Caches dir under storage pressure, which is fine.
final class DiskImageCache {
    static let shared = DiskImageCache()

    private let mem = NSCache<NSString, UIImage>()
    private let dir: URL
    // WRITES + TRIMMING stay SERIAL: two writers and the LRU trim must not interleave.
    private let io = DispatchQueue(label: "DiskImageCache.io", qos: .utility)
    // READS are CONCURRENT and user-initiated. They were on the serial `io` queue at .utility, so
    // after a relaunch - when the memory cache is empty and every visible photo needs a disk read -
    // all of them queued behind each other, one file read plus one full bitmap decode at a time, at a
    // QoS iOS deliberately throttles. That is what made already-seen photos fill in one by one from
    // grey placeholders. Nothing was being re-downloaded; the reads were just single-file.
    private let read = DispatchQueue(label: "DiskImageCache.read", qos: .userInitiated,
                                     attributes: .concurrent)
    private let maxBytes = 250 * 1024 * 1024   // 250 MB budget

    private init() {
        mem.countLimit = 250
        // Application Support, NOT Caches: iOS reclaims Caches under storage pressure, which was making
        // cached photos/avatars re-download after the OS purged them. Application Support is permanent
        // (secure messengers store media here); the 250 MB LRU below bounds growth ourselves. Excluded
        // from iCloud backup + file-protected at rest.
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        dir = base.appendingPathComponent("MediaCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        var mutableDir = dir; try? mutableDir.setResourceValues(values)
        // One-time migration: move any files from the old Caches location so nothing re-downloads
        // on the first launch after this change.
        let oldDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MediaCache", isDirectory: true)
        if FileManager.default.fileExists(atPath: oldDir.path) {
            io.async { [dir] in
                let fm = FileManager.default
                if let items = try? fm.contentsOfDirectory(at: oldDir, includingPropertiesForKeys: nil) {
                    for u in items {
                        let dest = dir.appendingPathComponent(u.lastPathComponent)
                        if !fm.fileExists(atPath: dest.path) { try? fm.moveItem(at: u, to: dest) }
                    }
                }
                try? fm.removeItem(at: oldDir)
            }
        }
        // The standard LRU cache evacuates in the background: decoded UIImages are the app's biggest heap
        // objects, and a backgrounded app holding hundreds of them is first in line for jetsam (and
        // background thermal work). The disk tier stays, so reopening is still instant.
        // Evict on real MEMORY PRESSURE, not on every backgrounding. Clearing on background meant that
        // switching to another app and coming straight back re-shimmered every visible photo - the user
        // reported this as "restarting the app", but it fired far more often than that. NSCache already
        // evacuates itself under pressure and when the app is jetsam-eligible, so the original concern is
        // handled by the system; throwing the whole tier away on every app switch was pure cost.
        NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.mem.removeAllObjects()
        }
        seedIndex()   // one directory listing, no file reads — see isCached
    }

    // WHAT IS ON DISK, answerable synchronously and with ZERO file IO.
    //
    // The problem this solves: the only synchronous "do I already have this?" check in the app was
    // `memoryImage`, i.e. memory only - and memory is empty on every launch AND wiped on every
    // backgrounding (see the observer above). So a photo that has been on disk for a week still had no
    // way to say so before the first frame was committed, and every view fell through to a skeleton
    // shimmer and only swapped in the real image a frame or more later. Nothing was being re-downloaded;
    // the app simply could not tell.
    //
    // A `Set` of hashed filenames answers it instantly. It is seeded once from a SINGLE directory
    // listing - no file reads, no decodes - and kept in step by every path that adds or removes a file.
    // Deliberately NOT a disk probe per lookup: `fileExists` on the main thread during a scroll is the
    // kind of hitch this cache exists to avoid.
    private var index = Set<String>()
    private let indexLock = NSLock()

    private func indexInsert(_ k: String) { indexLock.lock(); index.insert(k); indexLock.unlock() }
    private func indexRemove(_ k: String) { indexLock.lock(); index.remove(k); indexLock.unlock() }

    /// Is this URL already on disk? Pure in-memory set lookup, safe to call on the main thread from a
    /// view body. A false positive is harmless: the view holds a blank frame instead of a shimmer and
    /// the normal async load fills it exactly as before.
    func isCached(_ url: String) -> Bool {
        if mem.object(forKey: url as NSString) != nil { return true }
        let k = key(url)
        indexLock.lock(); defer { indexLock.unlock() }
        return index.contains(k)
    }

    private func seedIndex() {
        io.async { [weak self] in
            guard let self else { return }
            let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            // BOTH kinds seed the index — an owned photo is still "cached" for isCached's purposes.
            let keys = names.filter { $0.hasSuffix(".\(Self.cacheExt)") || $0.hasSuffix(".\(Self.ownedExt)") }
                .map { String($0.dropLast(4)) }
            indexLock.lock(); index.formUnion(keys); indexLock.unlock()
        }
    }

    private func key(_ url: String) -> String {
        SHA256.hash(data: Data(url.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    // TWO KINDS OF FILE IN ONE DIRECTORY, told apart by extension.
    //
    //   .img = CACHE. Re-downloadable (avatars, wallpapers, link previews, stickers). May be
    //          trimmed by the budget, swept by Keep Media, or wiped by Clear Cache.
    //   .own = OWNED. This phone's ONLY copy of a chat photo, the same promise VideoCache and
    //          AudioCache already make. NEVER deleted by trim, sweep or clear.
    //
    // The mailman model deletes the server object once the recipient has the file, so an owned
    // photo has nowhere to come back from. Every deleter below must skip `.own` or it is silent,
    // permanent data loss — exactly the bug that took Clear Cache off the About screen when it was
    // wiping voice notes.
    private static let cacheExt = "img"
    private static let ownedExt = "own"

    private func fileURL(_ url: String, owned: Bool = false) -> URL {
        dir.appendingPathComponent(key(url))
            .appendingPathExtension(owned ? Self.ownedExt : Self.cacheExt)
    }

    /// Where this url's bytes actually are: the owned copy wins, else the cache copy.
    private func existingFileURL(_ url: String) -> URL {
        let owned = fileURL(url, owned: true)
        return FileManager.default.fileExists(atPath: owned.path) ? owned : fileURL(url)
    }

    private static func isOwned(_ u: URL) -> Bool { u.pathExtension == ownedExt }

    /// Synchronous MEMORY-only lookup (instant; safe on the main thread).
    func memoryImage(_ url: String) -> UIImage? {
        mem.object(forKey: url as NSString)
    }

    /// SYNCHRONOUS first-frame read, for SMALL images only. Blocks the caller.
    ///
    /// `isCached` can already say "this file is on disk" instantly, but saying so is not enough: an
    /// AvatarView still had nothing to draw on the frame it was created, so every avatar rendered
    /// its coloured letter and then cross-faded to the real photo a frame or more later. On a cold
    /// launch that is EVERY avatar at once, because memory starts empty, and it reads as the app
    /// not knowing who its own contacts are (owner screenshots).
    ///
    /// Justified here because avatars are tiny. The `isCached` gate means a miss costs a Set lookup
    /// rather than a file probe, and the result is promoted to memory, so each url pays once per
    /// launch and every later row hits memory. Do NOT use this for full-size photos or video
    /// posters: those are big enough that reading them on the main thread would stutter a scroll.
    func smallImageSync(_ url: String) -> UIImage? {
        if let m = mem.object(forKey: url as NSString) { return m }
        guard isCached(url), let data = try? Data(contentsOf: existingFileURL(url)),
              let raw = UIImage(data: data) else { return nil }
        let img = raw.boundedForDisplay() ?? raw
        mem.setObject(img, forKey: url as NSString)
        return img
    }

    /// Memory only, and synchronous. For a view that has to draw on its FIRST frame: the async path
    /// below costs at least one frame even on a hit, and one frame of placeholder is a visible flash
    /// on anything that animates out of something already on screen. NSCache is thread-safe, so this
    /// is safe to call from a view's initialiser.
    func memoryImage(for url: String) -> UIImage? { mem.object(forKey: url as NSString) }

    /// Memory hit → instant. Otherwise read from disk off-main, decode, and promote
    /// to memory. Returns nil if not cached anywhere (caller should then download).
    func image(for url: String) async -> UIImage? {
        if let m = mem.object(forKey: url as NSString) { return m }
        return await withCheckedContinuation { cont in
            read.async {
                let f = self.existingFileURL(url)
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
    /// `owned: true` marks this as a chat photo the phone must KEEP (see the .own note above).
    func store(_ image: UIImage, data: Data? = nil, for url: String, owned: Bool = false) {
        mem.setObject(image, forKey: url as NSString)
        let bytes = data ?? image.jpegData(compressionQuality: 0.85)
        guard let bytes else { return }
        let f = fileURL(url, owned: owned)
        // Promoting cache -> owned: drop the old .img so the photo is not stored twice.
        if owned { try? FileManager.default.removeItem(at: fileURL(url)) }
        let k = key(url)
        io.async { [weak self] in
            // completeFileProtectionUntilFirstUserAuthentication, matching VideoCache and AudioCache.
            // `UnlessOpen` files cannot be OPENED while the device is locked, so a push-triggered launch
            // on a locked phone read nil, concluded "not cached", and re-downloaded.
            try? bytes.write(to: f, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            self?.indexInsert(k)
            self?.trimIfNeeded()
        }
    }

    /// Total bytes currently on disk (for the Settings "storage used" readout).
    func diskBytes() -> Int {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return items.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
    }

    /// Keep Media (Settings > Storage): drop cached files older than N days. Safe — this
    /// cache is re-downloadable by design (unlike the video/voice only-copies).
    func sweep(olderThanDays days: Int) {
        guard days > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        io.async { [weak self] in
            guard let self else { return }
            let fm = FileManager.default
            guard let items = try? fm.contentsOfDirectory(
                at: self.dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
            for u in items where !Self.isOwned(u) {
                if let d = (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                   d < cutoff {
                    try? fm.removeItem(at: u)
                    self.indexRemove(u.deletingPathExtension().lastPathComponent)
                }
            }
        }
    }

    /// Wipe both tiers (Settings → Clear Cache).
    func clear() {
        mem.removeAllObjects()
        io.async { [weak self] in
            guard let self else { return }
            let fm = FileManager.default
            if let items = try? fm.contentsOfDirectory(at: self.dir, includingPropertiesForKeys: nil) {
                // Clear Cache clears the CACHE. Owned chat photos survive it, the same reason the
                // About screen's Clear Cache button was removed when it was wiping voice notes.
                for u in items where !Self.isOwned(u) {
                    try? fm.removeItem(at: u)
                    self.indexRemove(u.deletingPathExtension().lastPathComponent)
                }
            }
        }
    }

    // Drop the oldest files once the budget is exceeded (LRU by modification date).
    private func trimIfNeeded() {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else { return }
        var files = items.compactMap { u -> (URL, Int, Date)? in
            guard !Self.isOwned(u) else { return nil }   // owned photos are not the budget's to spend
            guard let v = try? u.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                  let size = v.fileSize, let date = v.contentModificationDate else { return nil }
            return (u, size, date)
        }
        var total = files.reduce(0) { $0 + $1.1 }
        guard total > maxBytes else { return }
        files.sort { $0.2 < $1.2 }   // oldest first
        for (u, size, _) in files where total > maxBytes {
            try? fm.removeItem(at: u); total -= size
            indexRemove(u.deletingPathExtension().lastPathComponent)
        }
    }
}
