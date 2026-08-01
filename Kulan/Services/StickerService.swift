import Foundation
import UIKit
import CryptoKit
import FirebaseAuth
import FirebaseFirestore

// Kulan's own stickers. Packs are OURS — published by us, added and removed by everyone else.
// Nobody can create a pack from the app, which is what lets the whole thing skip moderation,
// reporting, takedowns and share links.
//
// Deliberately NOT end-to-end encrypted, and it is worth saying why in the file rather than in a
// commit nobody re-reads. A sticker is a published asset, closer to an emoji than to a photo:
// sealing it per conversation would mean re-uploading the same bytes for every chat you use it in,
// which is exactly the cost that makes a sticker stop feeling instant. The app already takes this
// position for GIFs (Message.isGif carries a plain Giphy url). What IS private — who sent which
// sticker to whom — stays private, because that lives in the message document, which only the
// people in the chat can read.

struct StickerPack: Identifiable, Equatable {
    let id: String
    var name: String
    var author: String
    var coverUrl: String
    /// "png" today. The field exists so an animated pack can ship later without invalidating the
    /// packs people have already installed — an old client sees a format it does not know and skips
    /// the pack rather than drawing garbage.
    var format: String
    var animated: Bool
    var order: Int
    var stickers: [Sticker]

    struct Sticker: Identifiable, Equatable {
        let id: String
        var url: String
        var emoji: String       // what it means: chat-list preview, push text, VoiceOver label
        var width: Double
        var height: Double
    }

    /// Unknown formats are refused rather than half-drawn. `animated` is checked too so a client that
    /// only knows still stickers cannot install a moving pack and show 120 frozen first frames.
    var isRenderable: Bool { format == "png" && !animated }

    init?(id: String, data: [String: Any]) {
        guard let name = data["name"] as? String,
              data["published"] as? Bool == true else { return nil }
        self.id = id
        self.name = name
        self.author = data["author"] as? String ?? "Kulan"
        self.coverUrl = data["coverUrl"] as? String ?? ""
        self.format = data["format"] as? String ?? "png"
        self.animated = data["animated"] as? Bool ?? false
        self.order = (data["order"] as? NSNumber)?.intValue ?? 0
        self.stickers = ((data["stickers"] as? [[String: Any]]) ?? []).compactMap { s in
            guard let sid = s["id"] as? String, let url = s["url"] as? String, !url.isEmpty else { return nil }
            return Sticker(id: sid, url: url,
                           emoji: s["emoji"] as? String ?? "",
                           width: (s["w"] as? NSNumber)?.doubleValue ?? 512,
                           height: (s["h"] as? NSNumber)?.doubleValue ?? 512)
        }
    }
}

@MainActor
final class StickerService: ObservableObject {
    static let shared = StickerService()
    private init() {}

    private var db: Firestore { Firestore.firestore() }
    private var uid: String { Auth.auth().currentUser?.uid ?? AuthService.shared.uid ?? "" }

    /// Every published pack, ordered. The store page's source.
    @Published private(set) var catalogue: [StickerPack] = []
    /// The packs I have added, in MY order — this is what the panel shows.
    @Published private(set) var installed: [StickerPack] = []
    @Published private(set) var loaded = false

    private var installedIds: [String] = []
    private var installedListener: ListenerRegistration?

    func isInstalled(_ packId: String) -> Bool { installedIds.contains(packId) }

    // MARK: Loading

    /// Catalogue from cache first so the store and the panel paint instantly, then the server.
    /// Same shape as the GIF picker's trending cache, and for the same reason: a panel that opens
    /// empty and waits for the network reads as broken even when it is only slow.
    func start() {
        if catalogue.isEmpty, let cached = PackCache.load() { apply(catalogue: cached) }
        Task { await refreshCatalogue() }
        watchInstalled()
    }

    func refreshCatalogue() async {
        guard let snap = try? await db.collection("stickerPacks")
            .whereField("published", isEqualTo: true)
            .getDocuments() else { return }
        let packs = snap.documents
            .compactMap { StickerPack(id: $0.documentID, data: $0.data()) }
            .filter(\.isRenderable)
            .sorted { $0.order == $1.order ? $0.name < $1.name : $0.order < $1.order }
        guard !packs.isEmpty else { return }   // never blank a working catalogue on a bad read
        apply(catalogue: packs)
        PackCache.save(packs)
    }

    private func apply(catalogue packs: [StickerPack]) {
        catalogue = packs
        loaded = true
        rebuildInstalled()
    }

    /// Installed packs live in a SUBCOLLECTION, not on the user document: other people can read user
    /// documents, and which stickers you use is nobody else's business.
    private func watchInstalled() {
        guard !uid.isEmpty, installedListener == nil else { return }
        installedListener = db.collection("users").document(uid)
            .collection("stickers").document("installed")
            .addSnapshotListener { [weak self] snap, _ in
                guard let self else { return }
                let ids = (snap?.data()?["packs"] as? [String]) ?? []
                Task { @MainActor in
                    self.installedIds = ids
                    self.rebuildInstalled()
                }
            }
    }

    /// My order, not the catalogue's — the array's order IS the user's order, so reordering is a
    /// single array write and needs no rank field to drift out of sync.
    private func rebuildInstalled() {
        let byId = Dictionary(uniqueKeysWithValues: catalogue.map { ($0.id, $0) })
        installed = installedIds.compactMap { byId[$0] }
    }

    func stop() {
        installedListener?.remove()
        installedListener = nil
    }

    // MARK: Add / remove / reorder

    func add(_ packId: String) async {
        guard !uid.isEmpty, !installedIds.contains(packId) else { return }
        var next = installedIds
        next.append(packId)
        await writeInstalled(next)
        // Pull the images down now, while the user is looking at a confirmation, so the panel is
        // instant the first time it opens — and works with no signal at all.
        if let pack = catalogue.first(where: { $0.id == packId }) { await prefetch(pack) }
    }

    func remove(_ packId: String) async {
        guard !uid.isEmpty else { return }
        await writeInstalled(installedIds.filter { $0 != packId })
    }

    func reorder(_ ids: [String]) async {
        guard !uid.isEmpty, ids.count == installedIds.count else { return }
        await writeInstalled(ids)
    }

    private func writeInstalled(_ ids: [String]) async {
        installedIds = ids           // optimistic: the listener echo confirms it
        rebuildInstalled()
        try? await db.collection("users").document(uid)
            .collection("stickers").document("installed")
            .setData(["packs": ids], merge: true)
    }

    // MARK: Images

    /// Warm the disk cache for a whole pack. Bounded concurrency: a 100-sticker pack firing 100
    /// simultaneous requests is how you get a stalled first open on a slow connection.
    func prefetch(_ pack: StickerPack) async {
        let urls = pack.stickers.map(\.url)
        await withTaskGroup(of: Void.self) { group in
            var next = urls.makeIterator()
            for _ in 0..<min(6, urls.count) {
                guard let u = next.next() else { break }
                group.addTask { _ = await StickerImages.load(u) }
            }
            while await group.next() != nil {
                guard let u = next.next() else { continue }
                group.addTask { _ = await StickerImages.load(u) }
            }
        }
    }
}

/// Sticker PNGs on disk, permanently. A sticker is sent again and again — re-downloading it is pure
/// waste, and the panel has to be usable offline. Same shape as GifBytesCache, which already proved
/// this out for GIFs.
enum StickerImages {
    private static let memory = NSCache<NSString, UIImage>()

    private static var dir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let d = base.appendingPathComponent("sticker-cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        var mutable = d; try? mutable.setResourceValues(values)
        return d
    }()

    private static func file(_ url: String) -> URL {
        let key = SHA256.hash(data: Data(url.utf8)).map { String(format: "%02x", $0) }.joined()
        return dir.appendingPathComponent(key).appendingPathExtension("png")
    }

    /// Memory, then disk, then the network. nil only if all three fail.
    static func load(_ url: String) async -> UIImage? {
        if let hit = memory.object(forKey: url as NSString) { return hit }
        let path = file(url)
        if let bytes = try? Data(contentsOf: path), let img = UIImage(data: bytes) {
            memory.setObject(img, forKey: url as NSString)
            return img
        }
        guard let u = URL(string: url),
              let (bytes, _) = try? await URLSession.shared.data(from: u),
              let img = UIImage(data: bytes) else { return nil }
        try? bytes.write(to: path, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        memory.setObject(img, forKey: url as NSString)
        return img
    }

    /// Already on disk? Lets a view draw on its first frame instead of flashing a placeholder.
    static func cached(_ url: String) -> UIImage? {
        if let hit = memory.object(forKey: url as NSString) { return hit }
        guard let bytes = try? Data(contentsOf: file(url)), let img = UIImage(data: bytes) else { return nil }
        memory.setObject(img, forKey: url as NSString)
        return img
    }
}

/// The catalogue, kept between launches so the store and the panel paint before the network answers.
private enum PackCache {
    private static var file: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("sticker-packs.json")
    }

    static func save(_ packs: [StickerPack]) {
        let raw = packs.map { p -> [String: Any] in
            ["id": p.id, "name": p.name, "author": p.author, "coverUrl": p.coverUrl,
             "format": p.format, "animated": p.animated, "order": p.order, "published": true,
             "stickers": p.stickers.map { ["id": $0.id, "url": $0.url, "emoji": $0.emoji,
                                           "w": $0.width, "h": $0.height] }]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: raw) else { return }
        try? data.write(to: file, options: .atomic)
    }

    static func load() -> [StickerPack]? {
        guard let data = try? Data(contentsOf: file),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        let packs = raw.compactMap { d -> StickerPack? in
            guard let id = d["id"] as? String else { return nil }
            return StickerPack(id: id, data: d)
        }
        return packs.isEmpty ? nil : packs
    }
}

/// Recently used stickers, on the device only — Signal keeps theirs local too, and syncing them
/// would cost a write on every sticker sent for something nobody misses on a new phone.
enum StickerRecents {
    private static let key = "stickerRecents.v1"
    private static let cap = 24

    static func all() -> [StickerPack.Sticker] {
        (UserDefaults.standard.array(forKey: key) as? [[String: Any]] ?? []).compactMap { d in
            guard let id = d["i"] as? String, let url = d["u"] as? String else { return nil }
            return StickerPack.Sticker(id: id, url: url, emoji: d["e"] as? String ?? "",
                                       width: d["w"] as? Double ?? 512, height: d["h"] as? Double ?? 512)
        }
    }

    static func note(_ s: StickerPack.Sticker) {
        var list = (UserDefaults.standard.array(forKey: key) as? [[String: Any]] ?? [])
            .filter { ($0["i"] as? String) != s.id }
        list.insert(["i": s.id, "u": s.url, "e": s.emoji, "w": s.width, "h": s.height], at: 0)
        UserDefaults.standard.set(Array(list.prefix(cap)), forKey: key)
    }
}
