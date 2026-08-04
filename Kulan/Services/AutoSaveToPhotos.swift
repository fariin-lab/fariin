import Foundation
import Photos
import UIKit

// "Save to Photos" (Settings > Chats): copy the photos and videos you RECEIVE into the system
// Photos library, so you do not have to hit Save on each one.
//
// ONLY INCOMING MEDIA. Your own pictures are already in your camera roll, and saving them again
// would quietly duplicate every photo you ever send.
//
// VIEW-ONCE IS NEVER SAVED. The sender marked it to disappear; a setting they cannot see must not
// copy it to the roll behind their back. Same reason the manual Save action hides on those.
//
// It rides the media prefetch pass (`MediaAutoDownloader.sweep`), which already walks a chat's
// messages holding the network policy and the decryption keys, so nothing is downloaded twice for
// this. That also sets the honest limit of the feature: it saves the media of chats that reach
// this device, when they reach it, not media that has never been fetched.
enum AutoSaveToPhotos {
    /// The UserDefaults key the Settings toggle binds to, so there is one spelling of it.
    static let defaultsKey = "chats.saveToPhotos"
    private static let doneKey = "chats.saveToPhotos.done"
    private static let doneCap = 600   // ids remembered, so a long-lived install stops growing

    /// OFF by default. Writing into someone's camera roll is not a thing to assume.
    static var isOn: Bool { UserDefaults.standard.bool(forKey: defaultsKey) }

    // MARK: - Already-saved ledger
    //
    // Re-opening a chat runs the same sweep again, so without this every old photo would land in
    // the roll a second time. The id is claimed BEFORE the work and given back if the save fails,
    // so a failure retries next time but two passes cannot both save the same message.
    private static let lock = NSLock()

    private static func claim(_ id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        var ids = UserDefaults.standard.stringArray(forKey: doneKey) ?? []
        guard !ids.contains(id) else { return false }
        ids.append(id)
        if ids.count > doneCap { ids.removeFirst(ids.count - doneCap) }
        UserDefaults.standard.set(ids, forKey: doneKey)
        return true
    }

    private static func release(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        var ids = UserDefaults.standard.stringArray(forKey: doneKey) ?? []
        ids.removeAll { $0 == id }
        UserDefaults.standard.set(ids, forKey: doneKey)
    }

    // MARK: - Entry point

    /// Offer one message to the camera roll. Returns at once; the fetch and the write run off-main.
    static func consider(_ m: Message, cid: String) {
        guard isOn, !m.viewOnce else { return }
        guard m.authorId != (AuthService.shared.uid ?? "") else { return }   // incoming only
        guard m.isImage || m.isVideo || m.isAlbum else { return }
        guard claim(m.id) else { return }
        Task.detached(priority: .utility) {
            // PERMISSION FIRST, bytes second. The other order downloads and decrypts the whole
            // photo and only then discovers the library is off limits — and since a refusal
            // releases the id so it can retry if you grant access later, that would re-download
            // every picture in every chat you open, forever, on a phone that said no once.
            guard await authorized() else { release(m.id); return }
            let saved: Bool
            if m.isAlbum      { saved = await saveAlbum(m, cid: cid) }
            else if m.isVideo { saved = await saveVideo(m, cid: cid) }
            else              { saved = await saveImage(m, cid: cid) }
            if !saved { release(m.id) }
        }
    }

    // MARK: - The three shapes media arrives in

    private static func saveImage(_ m: Message, cid: String) async -> Bool {
        guard let photo = await image(m.imageUrl, enc: m.enc, cid: cid) else { return false }
        return await write { _ = PHAssetChangeRequest.creationRequestForAsset(from: photo) }
    }

    private static func saveVideo(_ m: Message, cid: String) async -> Bool {
        guard let file = await videoFile(m.videoUrl, enc: m.enc, cid: cid, cacheAs: m.id) else { return false }
        return await write { _ = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: file) }
    }

    /// An album is ONE message holding several items, so it is one authorization pass and one
    /// change block — the roll gets the whole set together instead of a burst of separate writes.
    private static func saveAlbum(_ m: Message, cid: String) async -> Bool {
        var images: [UIImage] = []
        var videos: [URL] = []
        for (i, item) in m.album.enumerated() {
            if item.isVideo {
                // Album items have no message id of their own; key the cache off the parent + index.
                if let f = await videoFile(item.videoUrl, enc: item.videoEnc, cid: cid,
                                           cacheAs: "\(m.id)-\(i)") { videos.append(f) }
            } else if let img = await image(item.imageUrl, enc: item.enc, cid: cid) {
                images.append(img)
            }
        }
        guard !images.isEmpty || !videos.isEmpty else { return false }
        return await write {
            for photo in images { _ = PHAssetChangeRequest.creationRequestForAsset(from: photo) }
            for file in videos { _ = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: file) }
        }
    }

    // MARK: - Getting the bytes

    /// Cache first, network second — the same order the viewer uses, so an already-seen photo
    /// costs nothing to save.
    private static func image(_ url: String?, enc: EncMeta?, cid: String) async -> UIImage? {
        guard let s = url, !s.isEmpty else { return nil }
        if let cached = await DiskImageCache.shared.image(for: s) { return cached }
        guard let u = URL(string: s), let (cipher, _) = try? await MediaSession.shared.data(from: u) else { return nil }
        guard let meta = enc else { return UIImage(data: cipher) }   // legacy plaintext media
        guard let clear = await Crypto.shared.decryptBytes(cid, cipher: cipher, meta: meta) else { return nil }
        return UIImage(data: clear)
    }

    /// Photos needs a FILE for a video, so the decrypted bytes go through VideoCache — which is
    /// where the player wants them anyway, so the download is not wasted if the save then fails.
    private static func videoFile(_ url: String?, enc: EncMeta?, cid: String, cacheAs id: String) async -> URL? {
        if let have = VideoCache.url(for: id) { return have }
        guard let s = url, !s.isEmpty, let u = URL(string: s),
              let (cipher, _) = try? await MediaSession.shared.data(from: u) else { return nil }
        var clear = cipher
        if let meta = enc {
            guard let dec = await Crypto.shared.decryptBytes(cid, cipher: cipher, meta: meta) else { return nil }
            clear = dec
        }
        VideoCache.store(clear, for: id)
        return VideoCache.url(for: id)
    }

    // MARK: - The library

    private static func authorized() async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        return status == .authorized || status == .limited
    }

    private static func write(_ changes: @escaping () -> Void) async -> Bool {
        do { try await PHPhotoLibrary.shared().performChanges(changes); return true }
        catch { return false }
    }
}
