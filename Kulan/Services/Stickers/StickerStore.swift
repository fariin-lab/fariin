import Foundation
import Observation

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
        packs = Self.loadManifest()
        load()
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
            return Bundle.main.url(forResource: s.stickerId, withExtension: "webp",
                                   subdirectory: "packs/\(s.packId)")
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

    /// A sticker I drew: written to disk, then first in Favorites.
    @discardableResult
    func addMine(png: Data, emoji: String) throws -> Sticker {
        let id = UUID().uuidString.lowercased()
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
