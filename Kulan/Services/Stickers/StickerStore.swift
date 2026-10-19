import Foundation
import Observation
import FirebaseAuth
import FirebaseFirestore

// ⛔ THE STICKER KEYBOARD'S SHELF — owner 2026-10-17. Three lists:
//  - `packs`: the built-in packs, read once from the bundle (Resources/Stickers/packs/packs.json,
//    shipped as a folder reference so <packId>/<stickerId>.webp keeps its path). The art is our own
//    and lands later; an empty manifest is a normal state and the keyboard copes with it.
//  - `favorites`: stickers I made (a PNG on disk, source .mine) and stickers I saved from chats
//    (a bundled one is only a reference, no file copy). Newest first.
//  - `recents`: newest first, no duplicates, capped at StickerLimits.recents, as the reference app.
// Favorites and recents are the ACCOUNT's, so SessionWipe calls `wipe()` on sign-out.

@MainActor
@Observable
final class StickerStore {
    static let shared = StickerStore()

    private(set) var packs: [StickerPack] = []
    private(set) var favorites: [Sticker] = []
    private(set) var recents: [Sticker] = []

    /// The first name this list had (agent B's code reads it). Same list as `favorites`.
    var mine: [Sticker] { favorites }

    private struct Saved: Codable {
        var favorites: [Sticker]
        var recents: [Sticker]
    }

    private init() {
        shipped = Self.loadManifest()
        remote = Self.loadCatalog()
        rebuildPacks()
        load()
        // The admin panel's catalog, live once someone is signed in (rules: signed-in read).
        authHandle = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            MainActor.assumeIsolated { self?.watchCatalog(signedIn: user != nil) }
        }
    }

    // MARK: Packs from the admin panel (2026-10-18)

    // ⛔ STICKER PACKS MANAGED ONLINE — owner 2026-10-18: "add, remove and manage packs from the admin
    // panel without an app update; new stickers appear automatically; manage the existing ones too".
    // `stickerPacks/{id}` (functions-admin spack* ops): for a pack that ships in the app, an OVERRIDE
    // (title, order, on/off, hidden stickers); for a pack that lives on the server, the whole pack with
    // a download link per sticker. A server sticker is still `.bundled` to everything else: a message
    // carries its pack id, sticker id and that link (`StickerSend.publicURL`), so the receiving phone,
    // even a build older than this, draws it from the link the way it draws any pack it lacks.
    private struct RemotePack: Codable {
        struct Item: Codable {
            var id: String
            var emoji: String?
            var ext: String?
            var url: String?
            var animated: Bool?
            var hidden: Bool?
        }
        var id: String
        var kind: String
        var title: String
        var order: Int
        var enabled: Bool
        var deleted: Bool
        var stickers: [Item]
    }

    private var shipped: [StickerPack] = []
    private var remote: [RemotePack] = []
    @ObservationIgnored private var authHandle: AuthStateDidChangeListenerHandle?
    @ObservationIgnored private var catalogListener: ListenerRegistration?
    @ObservationIgnored private var downloading: Set<String> = []

    /// Bumped when a server sticker's file lands, so a grid can draw what was a shimmer.
    private(set) var artVersion = 0
    static let artArrived = Notification.Name("StickerStore.artArrived")
    static let packsChanged = Notification.Name("StickerStore.packsChanged")

    private func watchCatalog(signedIn: Bool) {
        catalogListener?.remove(); catalogListener = nil
        guard signedIn else { return }
        catalogListener = Firestore.firestore().collection("stickerPacks").addSnapshotListener { [weak self] snap, _ in
            guard let snap else { return }   // refused or offline: keep the last catalog
            let packs: [RemotePack] = snap.documents.map { d in
                let x = d.data()
                let items: [RemotePack.Item] = ((x["stickers"] as? [[String: Any]]) ?? []).compactMap { st in
                    guard let id = st["id"] as? String, !id.isEmpty else { return nil }
                    return RemotePack.Item(id: id, emoji: st["emoji"] as? String, ext: st["ext"] as? String,
                                           url: st["url"] as? String, animated: st["animated"] as? Bool,
                                           hidden: st["hidden"] as? Bool)
                }
                return RemotePack(id: d.documentID, kind: x["kind"] as? String ?? "",
                                  title: x["title"] as? String ?? "", order: x["order"] as? Int ?? 0,
                                  enabled: x["enabled"] as? Bool ?? true, deleted: x["deleted"] as? Bool ?? false,
                                  stickers: items)
            }
            MainActor.assumeIsolated {
                guard let self else { return }
                self.remote = packs
                self.rebuildPacks()
                Self.saveCatalog(packs)
            }
        }
    }

    /// The keyboard's packs: the app's own with their overrides, then the server's, in panel order.
    private func rebuildPacks() {
        var urls: [String: String] = [:]
        var exts: [String: String] = [:]
        var entries: [(order: Int, pack: StickerPack)] = []
        var overrides: [String: RemotePack] = [:]
        for r in remote where r.kind == "bundled" { overrides[r.id] = r }
        for (i, p) in shipped.enumerated() {
            guard let o = overrides[p.id] else { entries.append((i, p)); continue }
            guard o.enabled else { continue }
            let hidden = Set(o.stickers.filter { $0.hidden == true }.map(\.id))
            let kept = p.stickers.filter { !hidden.contains($0.stickerId) }
            if !kept.isEmpty {
                entries.append((o.order, StickerPack(id: p.id, title: o.title.isEmpty ? p.title : o.title, stickers: kept)))
            }
        }
        for r in remote where r.kind == "server" {
            // Every link is kept, hidden and removed packs included: messages already sent still need them.
            for it in r.stickers {
                if let u = it.url, !u.isEmpty { urls["\(r.id)/\(it.id)"] = u }
                exts["\(r.id)/\(it.id)"] = it.ext ?? "webp"
            }
            guard r.enabled, !r.deleted else { continue }
            let items = r.stickers.filter { $0.hidden != true && !($0.url ?? "").isEmpty }.map {
                Sticker(source: .bundled, packId: r.id, stickerId: $0.id, emoji: $0.emoji ?? "", animated: $0.animated ?? false)
            }
            if !items.isEmpty {
                entries.append((r.order, StickerPack(id: r.id, title: r.title.isEmpty ? r.id : r.title, stickers: items)))
            }
        }
        StickerCatalogLinks.set(urls, exts: exts)
        let next = entries.enumerated().sorted { a, b in
            a.element.order != b.element.order ? a.element.order < b.element.order : a.offset < b.offset
        }.map(\.element.pack)
        guard next != packs else { return }
        packs = next
        NotificationCenter.default.post(name: Self.packsChanged, object: nil)
    }

    /// Server stickers' files on this phone (Caches: not account data, and fine to lose).
    private static var catalogArtDir: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StickerCatalog", isDirectory: true)
    }
    private static var catalogURL: URL { catalogArtDir.appendingPathComponent("catalog.json") }

    private static func loadCatalog() -> [RemotePack] {
        guard let d = try? Data(contentsOf: catalogURL) else { return [] }
        return (try? JSONDecoder().decode([RemotePack].self, from: d)) ?? []
    }
    private static func saveCatalog(_ packs: [RemotePack]) {
        guard let d = try? JSONEncoder().encode(packs) else { return }
        try? FileManager.default.createDirectory(at: catalogArtDir, withIntermediateDirectories: true)
        try? d.write(to: catalogURL, options: .atomic)
    }

    /// The local copy of a server sticker, or nil while it downloads (the tile shimmers meanwhile and
    /// `artArrived` is posted when it lands).
    private func catalogFile(for s: Sticker) -> URL? {
        let key = "\(s.packId)/\(s.stickerId)"
        guard let link = StickerCatalogLinks.url(key), let remoteURL = URL(string: link),
              remoteURL.scheme == "https" else { return nil }
        let ext = StickerCatalogLinks.ext(key) ?? "webp"
        let dir = Self.catalogArtDir.appendingPathComponent(s.packId, isDirectory: true)
        let file = dir.appendingPathComponent("\(s.stickerId).\(ext)")
        if FileManager.default.fileExists(atPath: file.path) { return file }
        guard !downloading.contains(key) else { return nil }
        downloading.insert(key)
        Task.detached(priority: .utility) {
            var ok = false
            if let (data, resp) = try? await URLSession.shared.data(from: remoteURL),
               (resp as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty {
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                ok = (try? data.write(to: file, options: .atomic)) != nil
            }
            await MainActor.run {
                StickerStore.shared.downloading.remove(key)
                if ok {
                    StickerStore.shared.artVersion &+= 1
                    NotificationCenter.default.post(name: StickerStore.artArrived, object: key)
                }
            }
        }
        return nil
    }

    // MARK: Files

    private static var rootDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Stickers", isDirectory: true)
    }
    private static var mineDir: URL { rootDir.appendingPathComponent("mine", isDirectory: true) }
    private static var indexURL: URL { rootDir.appendingPathComponent("index.json") }

    func fileURL(for s: Sticker) -> URL? {
        switch s.source {
        case .bundled:
            if let u = Bundle.main.url(forResource: s.stickerId, withExtension: "webp",
                                       subdirectory: "packs/\(s.packId)") { return u }
            return catalogFile(for: s)   // a pack from the admin panel
        case .mine:
            let u = Self.mineDir.appendingPathComponent("\(s.stickerId).png")
            return FileManager.default.fileExists(atPath: u.path) ? u : nil
        }
    }

    func sticker(packId: String, stickerId: String) -> Sticker? {
        if let p = packs.first(where: { $0.id == packId }),
           let s = p.stickers.first(where: { $0.stickerId == stickerId }) { return s }
        return favorites.first { $0.packId == packId && $0.stickerId == stickerId }
    }

    // MARK: Favorites

    /// A sticker I drew, or one somebody made saved from a chat: written to disk, then first in
    /// Favorites.
    ///
    /// ⛔ ONE STICKER, ONE FAVORITE — owner 2026-10-19: the same custom sticker could be saved again
    /// from every message it came in, because the copy got a new id the message never matched, so
    /// the menu kept offering "Save to Favorites". `keepingId` (the message's own sticker id) makes
    /// the copy answer to that message; and a picture already kept, byte for byte, is moved to the
    /// front (taking that id) instead of being written a second time.
    @discardableResult
    func addMine(png: Data, emoji: String, keepingId: String? = nil) throws -> Sticker {
        if let keepingId, let i = favorites.firstIndex(where: { $0.packId == "mine" && $0.stickerId == keepingId }) {
            let s = favorites.remove(at: i)
            favorites.insert(s, at: 0)
            save()
            return s
        }
        if let i = favorites.firstIndex(where: { $0.source == .mine && mineBytes($0) == png }) {
            var s = favorites.remove(at: i)
            if let keepingId, keepingId != s.stickerId, Self.safeStem(keepingId) {
                let from = Self.mineDir.appendingPathComponent("\(s.stickerId).png")
                let to = Self.mineDir.appendingPathComponent("\(keepingId).png")
                if (try? FileManager.default.moveItem(at: from, to: to)) != nil {
                    let old = s.id
                    s = Sticker(source: .mine, packId: "mine", stickerId: keepingId, emoji: s.emoji, animated: false)
                    recents = recents.map { $0.id == old ? s : $0 }
                }
            }
            favorites.insert(s, at: 0)
            save()
            return s
        }
        let id = keepingId.flatMap { Self.safeStem($0) ? $0 : nil } ?? UUID().uuidString.lowercased()
        try FileManager.default.createDirectory(at: Self.mineDir, withIntermediateDirectories: true)
        try png.write(to: Self.mineDir.appendingPathComponent("\(id).png"), options: .atomic)
        let s = Sticker(source: .mine, packId: "mine", stickerId: id, emoji: emoji, animated: false)
        favorites.insert(s, at: 0)
        save()
        return s
    }

    /// Saved from a chat. A built-in one is kept as a reference only; the caller has already put a
    /// received .mine sticker's PNG where `fileURL` finds it (or uses `addMine`).
    func addFavorite(_ s: Sticker) {
        favorites.removeAll { $0.id == s.id }
        favorites.insert(s, at: 0)
        save()
    }

    func isFavorite(_ s: Sticker) -> Bool { favorites.contains { $0.id == s.id } }

    private func mineBytes(_ s: Sticker) -> Data? {
        try? Data(contentsOf: Self.mineDir.appendingPathComponent("\(s.stickerId).png"))
    }

    /// A sticker id from a message names a file here, so only a plain stem is used as one.
    private static func safeStem(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64 && id.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
    }

    /// Takes stickers out of Favorites. A PNG I made goes with it (only source .mine owns a file),
    /// and so does its recents entry, since it would have no picture left to draw.
    func removeFavorites(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        for s in favorites where ids.contains(s.id) && s.source == .mine {
            try? FileManager.default.removeItem(at: Self.mineDir.appendingPathComponent("\(s.stickerId).png"))
        }
        let gone = Set(favorites.filter { ids.contains($0.id) && $0.source == .mine }.map(\.id))
        favorites.removeAll { ids.contains($0.id) }
        if !gone.isEmpty { recents.removeAll { gone.contains($0.id) } }
        save()
    }

    /// The first name `removeFavorites` had.
    func deleteMine(_ ids: Set<String>) { removeFavorites(ids) }

    // MARK: Recents

    func noteUsed(_ s: Sticker) {
        recents.removeAll { $0.id == s.id }
        recents.insert(s, at: 0)
        if recents.count > StickerLimits.recents { recents = Array(recents.prefix(StickerLimits.recents)) }
        save()
    }

    /// Only the list; never a file.
    func removeFromRecents(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        recents.removeAll { ids.contains($0.id) }
        save()
    }

    // MARK: Sign-out

    func wipe() {
        favorites = []
        recents = []
        try? FileManager.default.removeItem(at: Self.rootDir)
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: Self.indexURL),
              let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return }
        // A made sticker whose file went missing is dropped rather than drawn as a blank tile.
        let fm = FileManager.default
        let alive: (Sticker) -> Bool = { s in
            s.source == .bundled
                || fm.fileExists(atPath: Self.mineDir.appendingPathComponent("\(s.stickerId).png").path)
        }
        favorites = saved.favorites.filter(alive)
        recents = Array(saved.recents.filter(alive).prefix(StickerLimits.recents))
        mergeDuplicateMine()
    }

    /// Copies of one picture saved before 2026-10-19 (see `addMine`): the first kept, the rest
    /// dropped with their files, recents pointed at the one kept.
    private func mergeDuplicateMine() {
        var seen: [Data: Sticker] = [:]
        var drop: [String: Sticker] = [:]
        for s in favorites where s.source == .mine {
            guard let bytes = mineBytes(s) else { continue }
            if let kept = seen[bytes] { drop[s.id] = kept } else { seen[bytes] = s }
        }
        guard !drop.isEmpty else { return }
        for s in favorites where drop[s.id] != nil {
            try? FileManager.default.removeItem(at: Self.mineDir.appendingPathComponent("\(s.stickerId).png"))
        }
        favorites.removeAll { drop[$0.id] != nil }
        var out: [Sticker] = []
        for r in recents {
            let s = drop[r.id] ?? r
            if !out.contains(where: { $0.id == s.id }) { out.append(s) }
        }
        recents = out
        save()
    }

    private func save() {
        let saved = Saved(favorites: favorites, recents: recents)
        do {
            try FileManager.default.createDirectory(at: Self.rootDir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(saved)
            try data.write(to: Self.indexURL, options: .atomic)
        } catch {
            // Best effort: the lists in memory are still right for this run.
        }
    }

    private struct Manifest: Decodable {
        struct Pack: Decodable {
            let id: String
            let title: String
            let stickers: [Item]
        }
        struct Item: Decodable {
            let id: String
            let emoji: String
            let animated: Bool?
        }
        let packs: [Pack]
    }

    private static func loadManifest() -> [StickerPack] {
        guard let url = Bundle.main.url(forResource: "packs", withExtension: "json", subdirectory: "packs"),
              let data = try? Data(contentsOf: url),
              let m = try? JSONDecoder().decode(Manifest.self, from: data) else { return [] }
        return m.packs.compactMap { p in
            let items = p.stickers.map {
                Sticker(source: .bundled, packId: p.id, stickerId: $0.id, emoji: $0.emoji,
                        animated: $0.animated ?? true)
            }
            // A pack with no art files in this build is left out, not shown as empty tiles.
            let present = items.filter {
                Bundle.main.url(forResource: $0.stickerId, withExtension: "webp", subdirectory: "packs/\(p.id)") != nil
            }
            return present.isEmpty ? nil : StickerPack(id: p.id, title: p.title, stickers: present)
        }
    }
}

/// The download links of the panel's server stickers, by "pack/sticker". Read off the main actor too
/// (a received sticker's bytes load in the background), so it is its own small locked box.
enum StickerCatalogLinks {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var urls: [String: String] = [:]
    nonisolated(unsafe) private static var exts: [String: String] = [:]

    static func set(_ u: [String: String], exts e: [String: String]) {
        lock.lock(); urls = u; exts = e; lock.unlock()
    }
    static func url(_ key: String) -> String? { lock.lock(); defer { lock.unlock() }; return urls[key] }
    static func ext(_ key: String) -> String? { lock.lock(); defer { lock.unlock() }; return exts[key] }
}
