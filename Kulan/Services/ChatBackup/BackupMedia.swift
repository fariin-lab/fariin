import Foundation
import Sodium

/// Photos, voice notes and (when chosen) videos in the chat backup (owner 2026-11-12).
///
/// Only what is ON THIS PHONE goes in: the decrypted copies the app already keeps (DiskImageCache,
/// AudioCache, VideoCache). Nothing is downloaded for a backup.
///
/// INCREMENTAL. A media file is one CloudKit record named `md-<32 hex>`, NOT tied to a backup set,
/// so the next backup lists it again instead of uploading it again. Each item is locked with its
/// own key, derived from the account's media key (BackupStoreKey.mediaKey) and the item's identity;
/// the media key travels inside the encrypted manifest, so a restored phone keeps using it.
///
/// Manifest addition (format v1, optional keys; a reader that does not know them ignores them):
///   "mediaKey": b64 32 bytes,
///   "media": [{"n": "md-…", "id": messageId, "cid": cid, "slot": "image"|"audio"|"video",
///              "i": album index or null, "url": source url or null}]
/// Each md- file = nonce || secretbox(decrypted bytes) under the item key.
enum BackupMedia {
    enum Slot: String { case image, audio, video }

    struct Entry {
        let name: String
        let id: String
        let cid: String
        let slot: Slot
        let i: Int?
        let url: String?

        var json: [String: Any] {
            ["n": name, "id": id, "cid": cid, "slot": slot.rawValue,
             "i": i.map { NSNumber(value: $0) } ?? NSNull(), "url": url ?? NSNull()]
        }

        init(name: String, id: String, cid: String, slot: Slot, i: Int?, url: String?) {
            self.name = name; self.id = id; self.cid = cid; self.slot = slot; self.i = i; self.url = url
        }

        init?(_ obj: [String: Any]) {
            guard let n = obj["n"] as? String, BackupMedia.isName(n),
                  let id = obj["id"] as? String, !id.isEmpty,
                  let slot = (obj["slot"] as? String).flatMap(Slot.init(rawValue:)) else { return nil }
            self.init(name: n, id: id, cid: obj["cid"] as? String ?? "", slot: slot,
                      i: (obj["i"] as? NSNumber)?.intValue, url: obj["url"] as? String)
        }

        /// Where this item's bytes live on this phone.
        var videoKey: String { i.map { "\(id)-\($0)" } ?? id }
    }

    /// One clip larger than this stays out (a CloudKit asset and the memory to seal it).
    static let maxItemBytes = 100 * 1024 * 1024

    private static let sodium = Sodium()

    static func isName(_ s: String) -> Bool {
        guard s.count == 35, s.hasPrefix("md-") else { return false }
        return s.dropFirst(3).allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    private static func identity(id: String, slot: Slot, i: Int?, url: String?) -> Bytes {
        Bytes("\(id)|\(slot.rawValue)|\(i ?? -1)|\(url ?? "")".utf8)
    }

    static func name(master: Bytes, id: String, slot: Slot, i: Int?, url: String?) -> String? {
        guard let h = sodium.genericHash.hash(message: identity(id: id, slot: slot, i: i, url: url),
                                              key: master, outputLength: 16) else { return nil }
        return "md-" + h.map { String(format: "%02x", $0) }.joined()
    }

    static func key(master: Bytes, _ e: Entry) -> Bytes? {
        sodium.genericHash.hash(message: Bytes("key|".utf8) + identity(id: e.id, slot: e.slot, i: e.i, url: e.url),
                                key: master, outputLength: BackupArchive.keyBytes)
    }

    /// The media of one message that this phone holds, as entries. View-once and deleted messages
    /// never go in; videos only when `videos`.
    static func entries(_ m: Message, cid: String, master: Bytes, videos: Bool) -> [Entry] {
        guard !m.viewOnce, !m.deleted else { return [] }
        var out: [Entry] = []
        func add(_ slot: Slot, _ i: Int?, _ url: String?) {
            if let n = name(master: master, id: m.id, slot: slot, i: i, url: url) {
                out.append(Entry(name: n, id: m.id, cid: cid, slot: slot, i: i, url: url))
            }
        }
        if !m.album.isEmpty {
            for (i, item) in m.album.enumerated() {
                if !item.imageUrl.isEmpty { add(.image, i, item.imageUrl) }   // photo, or a clip's poster
                if videos, item.isVideo { add(.video, i, nil) }
            }
            return out
        }
        if let u = m.imageUrl, !u.isEmpty { add(.image, nil, u) }
        if let u = m.thumbUrl, !u.isEmpty { add(.image, nil, u) }
        if m.isAudio { add(.audio, nil, nil) }
        if videos, m.isVideo { add(.video, nil, nil) }
        return out
    }

    /// The decrypted bytes on this phone, or nil (not here, or too big).
    static func localSize(_ e: Entry) -> Int? {
        let fm = FileManager.default
        switch e.slot {
        case .image:
            guard let u = e.url else { return nil }
            let n = DiskImageCache.shared.diskBytes(for: u).total
            return n > 0 && n <= maxItemBytes ? n : nil
        case .audio:
            guard let f = AudioCache.url(for: e.id),
                  let n = (try? fm.attributesOfItem(atPath: f.path)[.size] as? NSNumber)?.intValue else { return nil }
            return n > 0 && n <= maxItemBytes ? n : nil
        case .video:
            guard let f = VideoCache.url(for: e.videoKey),
                  let n = (try? fm.attributesOfItem(atPath: f.path)[.size] as? NSNumber)?.intValue else { return nil }
            return n > 0 && n <= maxItemBytes ? n : nil
        }
    }

    static func localBytes(_ e: Entry) -> Data? {
        switch e.slot {
        case .image: return e.url.flatMap { DiskImageCache.shared.bytesSync($0) }
        case .audio: return AudioCache.url(for: e.id).flatMap { try? Data(contentsOf: $0) }
        case .video: return VideoCache.url(for: e.videoKey).flatMap { try? Data(contentsOf: $0) }
        }
    }

    /// Restore: put one item's bytes where the app looks for them. Never replaces a copy already here.
    static func put(_ bytes: Data, _ e: Entry) {
        switch e.slot {
        case .image:
            guard let u = e.url, !DiskImageCache.shared.isCached(u) else { return }
            DiskImageCache.shared.storeBytes(bytes, for: u)
        case .audio:
            guard AudioCache.url(for: e.id) == nil else { return }
            AudioCache.store(bytes, for: e.id)
        case .video:
            guard VideoCache.url(for: e.videoKey) == nil else { return }
            _ = VideoCache.store(bytes, for: e.videoKey)
        }
    }
}
