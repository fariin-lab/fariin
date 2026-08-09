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

// Built-in wallpapers — original art bundled in the app (Resources/Wallpapers). Each is a PAIR:
// `<id>-light.jpg` and `<id>-dark.jpg`, and the app picks by colour scheme.
struct WallpaperPreset: Identifiable, Equatable {
    let id: String        // base name in Resources/Wallpapers (e.g. "wp-paper")
}

enum WallpaperPresets {
    /// ONE PATTERN, SIX GROUNDS, AND A LIGHT AND A DARK OF EACH — his instruction, and it is how
    /// WhatsApp actually ships this. Their picker is not a row of different drawings; it is the same
    /// doodle sheet over a row of colours, which is exactly why it reads as one set rather than a
    /// collection somebody accumulated.
    ///
    /// The trick in the pattern is the contrast, not the drawing: the ground carries the colour, the
    /// hairline doodles carry texture, and the gap between them is small enough that a message
    /// bubble always wins. So there is nothing here to read as "busy" and nothing to fight the
    /// messages, which is the whole job of a chat background.
    ///
    /// The grounds are keyed to the app's own chat accents, so a wallpaper and the bubble colour it
    /// pairs with belong together, and the ids ARE the theme ids so `imageId` is never a guess.
    static let all: [WallpaperPreset] = [
        .init(id: "wp-paper"), .init(id: "wp-ocean"), .init(id: "wp-forest"),
        .init(id: "wp-dusk"), .init(id: "wp-rose"), .init(id: "wp-graphite"),
    ]
}

extension WallpaperPreset {
    /// The bundled JPEG for this scheme. A wallpaper is a PAIR now — the pattern is the same in both
    /// and only the ground and the ink change, so a chat that follows the system appearance keeps
    /// the same wallpaper rather than swapping to a different one at sunset.
    func image(dark: Bool) -> UIImage? {
        Bundle.main.url(forResource: "\(id)-\(dark ? "dark" : "light")", withExtension: "jpg")
            .flatMap { UIImage(contentsOfFile: $0.path) }
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
    func image(_ dark: Bool) -> UIImage? { imageId.flatMap { WallpaperPreset(id: $0).image(dark: dark) } }
}

/// Renders a built-in theme wallpaper: its real IMAGE when one is bundled, else the gradient
/// palette. One place, so every tile/preview/chat background shows the same thing.
struct GradientWallpaperView: View {
    let g: WallpaperGradient
    let dark: Bool
    var body: some View {
        if let img = g.image(dark) {
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
    /// The palettes are the GROUNDS of the art, so the fallback looks like the wallpaper it stands
    /// in for rather than being a second design. They differ per mode again, because the wallpapers
    /// do: every one is a light paper and a dark paper carrying the same doodle sheet.
    ///
    /// `sunset` and `mono` kept their ids — a chat that stored either still resolves — and now point
    /// at the paper and graphite grounds.
    static let all: [WallpaperGradient] = [
        .init(id: "sunset", name: "Paper",
              light: [Color(hex: 0xEDE4DA), Color(hex: 0xEAE0D6), Color(hex: 0xE6DCD1)],
              dark:  [Color(hex: 0x0C1116), Color(hex: 0x0B0F14), Color(hex: 0x090D11)],
              tint: Color(hex: 0xF08A5D), bubbleHex: 0xF08A5D, imageId: "wp-paper"),
        .init(id: "ocean", name: "Ocean",
              light: [Color(hex: 0xE3ECF5), Color(hex: 0xDDE8F3), Color(hex: 0xD6E3F0)],
              dark:  [Color(hex: 0x0A141D), Color(hex: 0x09121A), Color(hex: 0x070F16)],
              tint: Color(hex: 0x3DA1FD), bubbleHex: 0x2E8BF0, imageId: "wp-ocean"),
        .init(id: "dusk", name: "Dusk",
              light: [Color(hex: 0xEAE5F5), Color(hex: 0xE4DEF2), Color(hex: 0xDED7EE)],
              dark:  [Color(hex: 0x100C1A), Color(hex: 0x0E0A17), Color(hex: 0x0B0813)],
              tint: Color(hex: 0x9B6DF3), bubbleHex: 0x8A5CF0, imageId: "wp-dusk"),
        .init(id: "forest", name: "Forest",
              light: [Color(hex: 0xE2EFE4), Color(hex: 0xDBEBDF), Color(hex: 0xD4E7D9)],
              dark:  [Color(hex: 0x0A1410), Color(hex: 0x09110E), Color(hex: 0x070F0C)],
              tint: Color(hex: 0x34C76F), bubbleHex: 0x1FA85A, imageId: "wp-forest"),
        .init(id: "mono", name: "Graphite",
              light: [Color(hex: 0xEFEFF1), Color(hex: 0xE9E9EC), Color(hex: 0xE3E3E7)],
              dark:  [Color(hex: 0x101012), Color(hex: 0x0E0E10), Color(hex: 0x0B0B0D)],
              tint: Color(hex: 0x8E8E93), bubbleHex: 0x3A3A3C, imageId: "wp-graphite"),
        .init(id: "rose", name: "Rose",
              light: [Color(hex: 0xF6E6EA), Color(hex: 0xF2E0E5), Color(hex: 0xEED9E0)],
              dark:  [Color(hex: 0x150B10), Color(hex: 0x12090E), Color(hex: 0x0F080C)],
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

    /// Does this chat have its OWN stored pick (vs inheriting the all-chats default)?
    /// The picker needs the raw answer, which `wallpaper(for:)` hides behind its fallback.
    func hasOverride(for cid: String) -> Bool {
        UserDefaults.standard.string(forKey: Self.key(cid)) != nil
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
            if let img = WallpaperPreset(id: id).image(dark: dark) {
                Color.clear
                    .overlay { Image(uiImage: img).resizable().scaledToFill() }
                    .clipped()
                    // ⚠️ NO SCRIM ON A BUILT-IN, and that is a decision rather than an omission.
                    // The scrim exists because an imported gallery photo can be anything — a white
                    // beach, a face, a screenshot — and bubbles have to survive it. A built-in is
                    // not anything: it is a flat ground with hairline doodles at a contrast chosen
                    // so the bubbles already win, and it ships in a light AND a dark version so it
                    // never needs correcting toward the scheme. Washing 28% black over that only
                    // removes the pattern it was made for. See `WallpaperPresets`.
            } else {
                Theme.bg(dark)
            }
        }
    }
}
