import SwiftUI
import UIKit
import CryptoKit

extension Notification.Name {
    // Posted with the cid as `object` when "Change Wallpaper" is tapped in a profile; the open
    // ThreadView for that cid catches it and presents the picker.
    static let openChatWallpaper = Notification.Name("openChatWallpaper")
}

// A per-chat wallpaper the user sets for THEMSELVES (the standard behavior) — stored locally, never
// synced to the other person and never uploaded. Three kinds: none (default app background),
// one of the built-in gradients, or a photo from the user's LIBRARY (see WallpaperStore):
// every gallery image ever applied is kept locally and reusable, so `.photo` carries the
// library photo's ID — identity, not a per-chat singleton. (The old identity-less `.photo`
// was the root of the "Apply button never reappears for a new photo" bug: a new pick compared
// equal to the old one.)
enum ChatWallpaper: Equatable {
    case none
    case gradient(String)   // gradient id (ChatWallpapers.all)
    case photo(String)      // library photo id (WallpaperStore.libraryIds)
    case color(UInt)        // a plain solid-colour background (hex)
    case preset(String)     // a built-in PHOTO wallpaper (WallpaperPresets.all)

    // Compact string form for UserDefaults.
    var stored: String {
        switch self {
        case .none:            return "none"
        case .gradient(let g): return "g:\(g)"
        case .photo(let id):   return "p:\(id)"
        case .color(let hex):  return "c:\(String(format: "%06X", hex))"
        case .preset(let id):  return "b:\(id)"
        }
    }
    init(stored: String?) {
        switch stored {
        case "photo": self = .photo(Self.legacyMarker)   // pre-library format → migrated in wallpaper(for:)
        case let s? where s.hasPrefix("g:"): self = .gradient(String(s.dropFirst(2)))
        case let s? where s.hasPrefix("p:"): self = .photo(String(s.dropFirst(2)))
        case let s? where s.hasPrefix("c:"): self = .color(UInt(s.dropFirst(2), radix: 16) ?? 0)
        case let s? where s.hasPrefix("b:"): self = .preset(String(s.dropFirst(2)))
        default: self = .none
        }
    }
    static let legacyMarker = "__legacy__"
}

// Built-in PHOTO wallpapers — original generated art bundled in the app (Resources/Wallpapers),
// so "Presets" isn't only gradients. Each has a light + dark file.
struct WallpaperPreset: Identifiable, Equatable {
    let id: String        // asset base name in Resources/Wallpapers (e.g. "wp-dunes")
}

enum WallpaperPresets {
    // Real image wallpapers (not flat gradients) — the theme-paired six first, then extras.
    static let all: [WallpaperPreset] = [
        .init(id: "wp-sunset"), .init(id: "wp-tide"), .init(id: "wp-violet"),
        .init(id: "wp-forest"), .init(id: "wp-graphite"), .init(id: "wp-rose"),
        .init(id: "wp-nightlights"), .init(id: "wp-amber"), .init(id: "wp-teal"),
        .init(id: "wp-daylight"), .init(id: "wp-sand"), .init(id: "wp-ice"),
        .init(id: "wp-dunes"), .init(id: "wp-ocean"), .init(id: "wp-aurora"),
        .init(id: "wp-mesh"), .init(id: "wp-night"), .init(id: "wp-doodle"),
    ]
}

extension WallpaperPreset {
    // Bundled JPEG in Resources/Wallpapers, loaded by base name.
    func image() -> UIImage? {
        Bundle.main.url(forResource: id, withExtension: "jpg").flatMap { UIImage(contentsOfFile: $0.path) }
    }
}

// Solid-colour wallpaper choices (the "Wallpaper Color" grid).
enum WallpaperColors {
    static let all: [UInt] = [
        0x0A0A0A, 0x1C1C1E, 0x2C2C2E, 0x3A3A3C,
        0x0E2A47, 0x123B24, 0x3A1E2E, 0x2A2340,
        0xE9E9EE, 0xD6ECFF, 0xDCF3D8, 0xFFE1E6,
    ]
}

// A built-in gradient wallpaper with light + dark palettes (so a chat looks right in either mode).
struct WallpaperGradient: Identifiable, Equatable {
    let id: String
    let name: String
    let light: [Color]
    let dark: [Color]
    let tint: Color        // vivid representative colour → the "Apply Wallpaper" button tint
    let bubbleHex: UInt    // the bubble colour this wallpaper is PAIRED with (a "theme" = both)
    // The real image this theme renders (user spec: themes/presets are photo wallpapers, not flat
    // gradients). The gradient palettes stay as the fallback if the file is ever missing.
    var imageId: String? = nil
    func colors(_ dark: Bool) -> [Color] { dark ? self.dark : light }
    func image() -> UIImage? { imageId.flatMap { WallpaperPreset(id: $0).image() } }
}

/// Renders a built-in theme wallpaper: its real IMAGE when one is bundled, else the gradient
/// palette. One place, so every tile/preview/chat background shows the same thing.
struct GradientWallpaperView: View {
    let g: WallpaperGradient
    let dark: Bool
    var body: some View {
        if let img = g.image() {
            Color.clear.overlay { Image(uiImage: img).resizable().scaledToFill() }.clipped()
        } else {
            // The actual gradient, which is what the doc above promises. This branch used to return
            // GradientWallpaperView(g:dark:) — itself, with identical inputs — so any theme whose
            // bundled image failed to load would recurse until the app died (audit). Latent while
            // the files ship, fatal the day one goes missing.
            LinearGradient(colors: g.colors(dark), startPoint: .top, endPoint: .bottom)
        }
    }
}

enum ChatWallpapers {
    // Kept subtle so message bubbles always read clearly on top (the top→bottom fall is gentle).
    // BUILT-IN wallpapers: never deletable (they aren't part of the user library at all).
    static let all: [WallpaperGradient] = [
        .init(id: "sunset", name: "Sunset",
              light: [Color(hex: 0xFFE9C7), Color(hex: 0xFFC9AE), Color(hex: 0xF6AEC6)],
              dark:  [Color(hex: 0x3A2A2C), Color(hex: 0x2A1E28), Color(hex: 0x1C161C)],
              tint: Color(hex: 0xF08A5D), bubbleHex: 0xF08A5D, imageId: "wp-sunset"),
        .init(id: "ocean", name: "Ocean",
              light: [Color(hex: 0xD6ECFF), Color(hex: 0xB8DCF6), Color(hex: 0xA6D5E6)],
              dark:  [Color(hex: 0x16283A), Color(hex: 0x142430), Color(hex: 0x101A22)],
              tint: Color(hex: 0x3DA1FD), bubbleHex: 0x2E8BF0, imageId: "wp-tide"),
        .init(id: "dusk", name: "Dusk",
              light: [Color(hex: 0xE7D9FF), Color(hex: 0xD3C1F5), Color(hex: 0xF3C6E4)],
              dark:  [Color(hex: 0x2A2340), Color(hex: 0x231C33), Color(hex: 0x1A1626)],
              tint: Color(hex: 0x9B6DF3), bubbleHex: 0x8A5CF0, imageId: "wp-violet"),
        .init(id: "forest", name: "Forest",
              light: [Color(hex: 0xDCF3D8), Color(hex: 0xBFE7C2), Color(hex: 0xA9DCC9)],
              dark:  [Color(hex: 0x1B2E22), Color(hex: 0x18271F), Color(hex: 0x121C18)],
              tint: Color(hex: 0x34C76F), bubbleHex: 0x1FA85A, imageId: "wp-forest"),
        .init(id: "mono", name: "Mono",
              light: [Color(hex: 0xF2F2F5), Color(hex: 0xE4E4E9), Color(hex: 0xD5D5DB)],
              dark:  [Color(hex: 0x1E1E22), Color(hex: 0x191919), Color(hex: 0x121214)],
              tint: Color(hex: 0x8E8E93), bubbleHex: 0x3A3A3C, imageId: "wp-graphite"),
        .init(id: "rose", name: "Rose",
              light: [Color(hex: 0xFFE1E6), Color(hex: 0xFFC9D5), Color(hex: 0xFAB0C6)],
              dark:  [Color(hex: 0x33212A), Color(hex: 0x2A1B24), Color(hex: 0x1D141A)],
              tint: Color(hex: 0xF06792), bubbleHex: 0xE84D86, imageId: "wp-rose"),
    ]

    /// A theme = the paired wallpaper + bubble colour, applied together by a Chat Theme card.
    static func themeColor(_ id: String) -> ChatColorSpec? {
        gradient(id).map { ChatColorSpec(colors: [$0.bubbleHex]) }
    }
    static func gradient(_ id: String) -> WallpaperGradient? { all.first { $0.id == id } }
}

// Wallpaper management system (all LOCAL, nothing ever uploaded):
//   • Per-chat ACTIVE wallpaper (UserDefaults "wallpaper.<cid>").
//   • A persistent USER LIBRARY of every gallery photo ever imported — files in
//     ApplicationSupport/Wallpapers/library/<id>.jpg + the ordered id list in UserDefaults.
//     Applying a different wallpaper never deletes library photos; Reset only clears the ACTIVE
//     wallpaper; only an explicit Delete (long-press) removes a library photo.
//   • Deduplication: imports are hashed (SHA256 of the encoded JPEG) — re-importing the same image
//     returns the existing library id instead of a duplicate tile.
//   • Migration: the pre-library per-chat photo ("photo" + Wallpapers/<cid>.jpg) is imported into
//     the library on first read, so nothing the user had disappears.
// Observable so setting a wallpaper re-renders the open chat instantly (live preview in the picker).
// Caches are observation-IGNORED; re-renders are driven by the observed `version` / `libraryIds`.
@Observable final class WallpaperStore {
    static let shared = WallpaperStore()
    private(set) var version = 0
    private(set) var libraryIds: [String]                       // user-imported photo ids, newest FIRST
    @ObservationIgnored private var cache: [String: ChatWallpaper] = [:]
    @ObservationIgnored private var imageCache: [String: UIImage] = [:]
    @ObservationIgnored private var hashes: [String: String]   // photo id -> content hash (dedup)

    private init() {
        libraryIds = UserDefaults.standard.stringArray(forKey: "wallpaper.library.v1") ?? []
        hashes = (UserDefaults.standard.dictionary(forKey: "wallpaper.libraryHashes.v1") as? [String: String]) ?? [:]
    }

    // MARK: - Active wallpaper (per chat)

    func wallpaper(for cid: String) -> ChatWallpaper {
        if let c = cache[cid] { return c }
        // No per-chat pick → fall back to the all-chats default ("Apply For All Chats").
        // An explicit per-chat "none" is stored as the string "none", so it does NOT fall through.
        let raw = UserDefaults.standard.string(forKey: Self.key(cid))
            ?? UserDefaults.standard.string(forKey: Self.defaultKey)
        var w = ChatWallpaper(stored: raw)
        // MIGRATION: legacy per-chat photo → import into the library, rewrite the stored value.
        if case .photo(ChatWallpaper.legacyMarker) = w {
            if let img = UIImage(contentsOfFile: Self.legacyPhotoURL(cid).path),
               let id = addToLibrary(img) {
                w = .photo(id)
                UserDefaults.standard.set(w.stored, forKey: Self.key(cid))
                try? FileManager.default.removeItem(at: Self.legacyPhotoURL(cid))
            } else {
                w = .none
            }
        }
        cache[cid] = w
        return w
    }

    func set(_ w: ChatWallpaper, for cid: String) {
        cache[cid] = w
        UserDefaults.standard.set(w.stored, forKey: Self.key(cid))
        version &+= 1                                           // observed → live re-render
    }

    /// Remove the per-chat pick so this chat follows the all-chats default again.
    func clearOverride(for cid: String) {
        cache[cid] = nil
        UserDefaults.standard.removeObject(forKey: Self.key(cid))
        version &+= 1
    }

    /// "Apply For All Chats": the pick becomes the default every chat falls back to, and
    /// per-chat picks are cleared so it truly shows everywhere.
    func applyToAllChats(_ w: ChatWallpaper) {
        let d = UserDefaults.standard
        for k in d.dictionaryRepresentation().keys
            where k.hasPrefix("wallpaper.") && !k.hasPrefix("wallpaper.library") && k != Self.defaultKey {
            d.removeObject(forKey: k)
        }
        cache = [:]
        d.set(w.stored, forKey: Self.defaultKey)
        version &+= 1
    }

    // MARK: - User photo library (persistent history; local only)

    func libraryImage(_ id: String) -> UIImage? {
        if let c = imageCache[id] { return c }
        guard let img = UIImage(contentsOfFile: Self.libraryURL(id).path) else { return nil }
        imageCache[id] = img
        return img
    }

    // Import a gallery photo into the library (downscaled JPEG). Content-hash dedup: importing the
    // same image again returns the EXISTING id — no duplicate tiles, and the id (identity) is what
    // makes "same photo re-applied" and "different photo picked" distinguishable.
    @discardableResult
    func addToLibrary(_ image: UIImage) -> String? {
        let scaled = Self.downscale(image, maxDimension: 1600)
        guard let data = scaled.jpegData(compressionQuality: 0.85) else { return nil }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        if let existing = hashes.first(where: { $0.value == hash })?.key,
           libraryIds.contains(existing) {
            return existing                                      // duplicate import → reuse
        }
        let id = UUID().uuidString
        let url = Self.libraryURL(id)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        do { try data.write(to: url, options: .atomic) } catch { return nil }
        imageCache[id] = scaled
        hashes[id] = hash
        libraryIds.insert(id, at: 0)                             // newest first (observed → picker updates)
        persistLibrary()
        return id
    }

    // Delete a USER-IMPORTED wallpaper from the library (built-ins are not in the library and can
    // never be deleted). Chats still pointing at it fall back gracefully to the default background.
    func deleteFromLibrary(_ id: String) {
        libraryIds.removeAll { $0 == id }
        hashes.removeValue(forKey: id)
        imageCache.removeValue(forKey: id)
        try? FileManager.default.removeItem(at: Self.libraryURL(id))
        persistLibrary()
        version &+= 1
    }

    private func persistLibrary() {
        UserDefaults.standard.set(libraryIds, forKey: "wallpaper.library.v1")
        UserDefaults.standard.set(hashes, forKey: "wallpaper.libraryHashes.v1")
    }

    // MARK: - Paths / helpers

    private static func key(_ cid: String) -> String { "wallpaper.\(cid)" }
    static let defaultKey = "wallpaper.__default__"   // the all-chats fallback
    private static var base: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }
    private static func libraryURL(_ id: String) -> URL {
        base.appendingPathComponent("Wallpapers/library/\(id).jpg")
    }
    private static func legacyPhotoURL(_ cid: String) -> URL {
        let safe = cid.replacingOccurrences(of: "/", with: "_")
        return base.appendingPathComponent("Wallpapers/\(safe).jpg")
    }
    private static func downscale(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let w = image.size.width, h = image.size.height
        let m = max(w, h)
        guard m > maxDimension else { return image }
        let scale = maxDimension / m
        let size = CGSize(width: w * scale, height: h * scale)
        let fmt = UIGraphicsImageRendererFormat.default()
        return UIGraphicsImageRenderer(size: size, format: fmt).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}

// The wallpaper layer that sits behind a chat's messages. `.none` renders the plain app
// background (so nothing changes for chats without a wallpaper). Photos get a light scrim so
// bubbles and the floating header/composer stay readable on busy images.
struct ChatWallpaperBackground: View {
    let cid: String
    @Environment(\.colorScheme) private var scheme
    private var store: WallpaperStore { .shared }

    var body: some View {
        let dark = scheme == .dark
        let _ = store.version   // observe: re-render when the wallpaper is changed live from the picker
        switch store.wallpaper(for: cid) {
        case .none:
            Theme.bg(dark)
        case .gradient(let id):
            if let g = ChatWallpapers.gradient(id) {
                GradientWallpaperView(g: g, dark: dark)
            } else {
                Theme.bg(dark)
            }
        case .photo(let id):
            if let img = store.libraryImage(id) {
                // Color.clear is the layout-defining view (size-neutral, fills like the .none color
                // case) and the photo rides as a CLIPPED overlay. A bare scaledToFill Image re-flows
                // when the container height changes (keyboard open/close), which nudged the composer;
                // clipping the overlay keeps the fill from ever feeding layout back, so it's rock-stable.
                Color.clear
                    .overlay { Image(uiImage: img).resizable().scaledToFill() }
                    .clipped()
                    .overlay(dark ? Color.black.opacity(0.28) : Color.white.opacity(0.14))
            } else {
                Theme.bg(dark)   // photo deleted from the library → fall back gracefully
            }
        case .color(let hex):
            Color(hex: hex)
        case .preset(let id):
            if let img = WallpaperPreset(id: id).image() {
                Color.clear
                    .overlay { Image(uiImage: img).resizable().scaledToFill() }
                    .clipped()
                    .overlay(dark ? Color.black.opacity(0.28) : Color.white.opacity(0.14))
            } else {
                Theme.bg(dark)
            }
        }
    }
}
