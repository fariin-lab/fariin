import UIKit
import ImageIO

/// ⛔ THE ONE PROFILE-PHOTO PIPELINE — 2026-09-25 photo audit, owner: "sometimes it shows, sometimes
/// it is grey, sometimes it is late … a core system, centralised, hard to break".
///
/// Before this, five views each had their own copy of "memory, then disk, then download": AvatarView,
/// the chat header, the message-row avatar, the stories row and the Glow story card. They disagreed on
/// retries (two retried nothing), shared one 250-slot memory cache with every chat photo and video, kept
/// avatars at up to 2048px in it, and two screens asking for the same photo downloaded it twice. Every
/// avatar now asks this one type, so a rule lives in one place:
///
///  - MEMORY: an avatar-only `NSCache`, images thumbnailed to `avatarPixels`, so browsing a gallery
///    cannot push avatars out and a hundred avatars cost a few MB, not hundreds.
///  - DISK: the same `DiskImageCache` file as before (one copy of the bytes, one LRU, one wipe on
///    sign-out). Eviction there only ever means a re-download; memory keeps what is on screen.
///  - NETWORK: one request per url at a time, shared by every caller (`fetch`).
///  - RETRY: a network failure is retried at 2s and 6s. A 403 (the rules said no) or a 404 (no such
///    photo) is an ANSWER and is never retried — see `ProfilePhotoURLProtocol`.
///  - FRESHNESS: a photo change is a new url (`?v=` is the upload time), so nothing here ever needs
///    invalidating; an old entry simply stops being asked for.
final class ProfilePhotoLoader {
    static let shared = ProfilePhotoLoader()

    /// The largest avatar drawn is the 132pt no-photo profile slot; at 3x that is ~400px.
    static let avatarPixels: CGFloat = 400

    enum FetchResult {
        case image(Data)
        /// 403 or 404: not allowed, or nothing there. Final.
        case noPhoto
        /// Every attempt failed on the network. Worth asking again later.
        case failed
    }

    private let memory = NSCache<NSString, UIImage>()
    private var inFlight: [String: Task<FetchResult, Never>] = [:]
    private let lock = NSLock()

    private init() {
        memory.countLimit = 600
        memory.totalCostLimit = 48 * 1024 * 1024
        // `queue: nil` for the reason written on ThreadMessageCache's observer. Safe to drop: every
        // entry is still on disk and `cachedAvatar` reads it back on the next draw.
        NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification,
                                               object: nil, queue: nil) { [weak self] _ in
            self?.memory.removeAllObjects()
        }
    }

    /// FIRST FRAME. Avatar memory, then the file on disk, synchronously. Safe on the main thread: a
    /// miss is a dictionary and a Set lookup, a hit on disk is one small file thumbnailed by ImageIO.
    func cachedAvatar(_ url: String?) -> UIImage? {
        guard let url, !url.isEmpty else { return nil }
        if let m = memory.object(forKey: url as NSString) { return m }
        guard let data = DiskImageCache.shared.bytesSync(url), let img = Self.thumbnail(data) else { return nil }
        remember(img, url)
        return img
    }

    /// The avatar from memory, disk or network. Callers of the same url share one download.
    func avatar(_ url: String) async -> UIImage? {
        guard !url.isEmpty else { return nil }
        if let m = memory.object(forKey: url as NSString) { return m }
        if let data = await DiskImageCache.shared.rawData(for: url), let img = Self.thumbnail(data) {
            remember(img, url)
            ProfilePhotoIndex.noteLoad(url, ok: true)
            return img
        }
        // My own new photo in the moment after Save: `ProfileStore` seeds the shared cache in memory
        // and the disk write is still queued. Draw that rather than download what I just uploaded.
        if let seeded = DiskImageCache.shared.memoryImage(for: url),
           let data = seeded.jpegData(compressionQuality: 0.9), let img = Self.thumbnail(data) {
            remember(img, url)
            return img
        }
        switch await fetch(url) {
        case .image(let data):
            guard let img = Self.thumbnail(data) else { return nil }
            remember(img, url)
            ProfilePhotoIndex.noteLoad(url, ok: true)
            return img
        case .noPhoto:
            ProfilePhotoIndex.noteLoad(url, ok: false)
            return nil
        case .failed:
            return nil
        }
    }

    /// The bytes, from the network, ONE request per url at a time. Also used by the full-size poster
    /// loader, so the profile page and an avatar on the same person never download it twice. The
    /// shared task is deliberately not cancelled with a caller: the bytes land on disk either way.
    func fetch(_ url: String) async -> FetchResult {
        lock.lock()
        if let running = inFlight[url] {
            lock.unlock()
            return await running.value
        }
        let task = Task<FetchResult, Never> { await Self.download(url) }
        inFlight[url] = task
        lock.unlock()
        let result = await task.value
        lock.lock()
        if inFlight[url] == task { inFlight[url] = nil }
        lock.unlock()
        return result
    }

    private func remember(_ img: UIImage, _ url: String) {
        let cost = img.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
        memory.setObject(img, forKey: url as NSString, cost: cost)
    }

    private static func download(_ s: String) async -> FetchResult {
        guard let url = URL(string: s) else { return .noPhoto }
        for delay in [0.0, 2.0, 6.0] {
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            // A throw is the network (offline, timeout, a dropped connection): try again.
            guard let (data, response) = try? await MediaSession.shared.data(from: url) else { continue }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 200
            if status == 403 || status == 404 { return .noPhoto }
            // Any other non-success (a 5xx, a throttled request) is the server, not an answer.
            guard (200..<300).contains(status) else { continue }
            guard UIImage(data: data) != nil else { return .noPhoto }
            DiskImageCache.shared.storeBytes(data, for: s)
            return .image(data)
        }
        return .failed
    }

    /// ImageIO thumbnail: decodes straight to the small size instead of decoding the full photo and
    /// scaling it, and applies the EXIF orientation.
    static func thumbnail(_ data: Data) -> UIImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: avatarPixels,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }
}
