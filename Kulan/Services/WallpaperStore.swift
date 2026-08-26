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
    case preset(String)     // legacy id for a built-in theme (see WallpaperPreset.theme)

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

/// THE DOODLE SHEET, ONCE. It is an ALPHA MASK — white ink on transparent — so this single file
/// serves every theme in both appearances: the shape comes from here, the colour comes from the
/// theme. It is the whole reason a theme is a row of numbers below instead of a pair of 300 KB
/// photographs, and it is how the reference app ships dozens of themes without shipping dozens of
/// pictures.
///
/// It was extracted from the art we already had rather than redrawn, so the six themes render
/// exactly what they rendered before — their grounds and inks were measured out of the same files.
enum ChatPattern {
    static let sheet: UIImage? = Bundle.main.url(forResource: "wp-pattern", withExtension: "png")
        .flatMap { UIImage(contentsOfFile: $0.path) }?
        .withRenderingMode(.alwaysTemplate)
}

/// A `.preset(id)` stored on a chat. It is NOT a second kind of wallpaper any more — it resolves to
/// a theme in `ChatWallpapers` and renders through the same view. The type survives only because
/// chats have these ids written into UserDefaults; nothing new is ever stored as one.
///
/// The list of them is gone with the `WallpaperPresets` enum: it named the same six themes a second
/// time, from when a preset was a bundled JPEG and a gradient was the fallback palette for it.
struct WallpaperPreset: Identifiable, Equatable {
    let id: String        // e.g. "wp-paper"
}

extension WallpaperPreset {
    /// The theme this preset draws. Two ids kept their original names when the art was introduced
    /// (`sunset` is Paper, `mono` is Graphite) and chats have those strings stored, so the mapping is
    /// a table rather than a string operation — a chat set two months ago must still resolve.
    private static let themeIds: [String: String] = [
        "wp-paper": "sunset", "wp-ocean": "ocean", "wp-forest": "forest",
        "wp-dusk": "dusk", "wp-rose": "rose", "wp-graphite": "mono",
    ]
    var theme: WallpaperGradient? { Self.themeIds[id].flatMap { ChatWallpapers.gradient($0) } }
}

// Solid-colour wallpaper choices (the "Wallpaper Color" grid).
enum WallpaperColors {
    static let all: [UInt] = [
        0x0A0A0A, 0x1C1C1E, 0x2C2C2E, 0x3A3A3C,
        0x0E2A47, 0x123B24, 0x3A1E2E, 0x2A2340,
        0xE9E9EE, 0xD6ECFF, 0xDCF3D8, 0xFFE1E6,
    ]
}

/// A built-in theme, stored as NUMBERS. Four corner colours per appearance plus the bubble colour
/// it is paired with. That is the entire definition — there is no artwork for a theme, because
/// `ChatPattern` is shared by all of them and everything else here is a colour. Adding a theme is
/// adding one of these; it costs no app size and no App Store review.
///
/// The hexes USED to be measured rather than chosen: every ground was read out of the JPEG it
/// replaced, three stops a few digits apart, and the narrowness was described here as the design.
/// It is not the design any more — see the rule above `ChatWallpapers.all` for what replaced it and
/// why the readability it was buying does not actually cost the colour.
struct WallpaperGradient: Identifiable, Equatable {
    let id: String
    let name: String
    /// FOUR CORNERS, not a top-to-bottom ramp: top-left, top-right, bottom-left, bottom-right.
    let lightCorners: [UInt]
    let darkCorners: [UInt]
    let tint: Color        // vivid representative colour → the "Apply Wallpaper" button tint
    let bubbleHex: UInt    // the bubble colour this wallpaper is PAIRED with (a "theme" = both)

    /// The nine colours a 3×3 mesh needs, from the four we store: corners as given, edges as the
    /// blend of the two corners they sit between, centre as the blend of all four. Nine hand-picked
    /// numbers per appearance per theme would be 108 numbers nobody could keep consistent; four
    /// corners is the smallest thing a person can actually design, and the rest is arithmetic.
    func meshColors(_ isDark: Bool) -> [Color] {
        let c = isDark ? darkCorners : lightCorners
        guard c.count == 4 else { return c.map { Color(hex: $0) } }
        let tl = c[0], tr = c[1], bl = c[2], br = c[3]
        let hexes = [tl,               Self.mix(tl, tr), tr,
                     Self.mix(tl, bl), Self.mix(Self.mix(tl, br), Self.mix(tr, bl)), Self.mix(tr, br),
                     bl,               Self.mix(bl, br), br]
        return hexes.map { Color(hex: $0) }
    }

    /// The single colour this theme is "about" — used where one flat colour is all there is room
    /// for (a tiny swatch, a blurred stand-in). The blend of its four corners.
    func flat(_ isDark: Bool) -> Color {
        let c = isDark ? darkCorners : lightCorners
        guard c.count == 4 else { return Color(hex: c.first ?? 0) }
        return Color(hex: Self.mix(Self.mix(c[0], c[1]), Self.mix(c[2], c[3])))
    }

    private static func mix(_ a: UInt, _ b: UInt) -> UInt {
        let r = (((a >> 16) & 0xFF) + ((b >> 16) & 0xFF)) / 2
        let g = (((a >> 8) & 0xFF) + ((b >> 8) & 0xFF)) / 2
        let bl = ((a & 0xFF) + (b & 0xFF)) / 2
        return (r << 16) | (g << 8) | bl
    }

    /// The grid the mesh is drawn on. The interior point is deliberately OFF centre: on a perfect
    /// grid the four colours meet in a symmetrical cross and the result reads as a manufactured
    /// gradient. Moved a little up and to the right, the colours pool unevenly and it reads as
    /// something that was painted.
    static let meshPoints: [SIMD2<Float>] = [
        [0, 0],   [0.5, 0],     [1, 0],
        [0, 0.5], [0.58, 0.42], [1, 0.5],
        [0, 1],   [0.5, 1],     [1, 1],
    ]
}

/// The one place a built-in theme becomes pixels: the ground gradient, with the shared pattern inked
/// over it. Every tile, preview and chat background goes through here, so none of them can drift
/// from the others — which is what the old two-path version (bundled image, else gradient) could not
/// promise, since the two paths did not look alike.
struct GradientWallpaperView: View {
    let g: WallpaperGradient
    let dark: Bool
    var blur: CGFloat = 0

    var body: some View {
        ground
            .overlay { ink }
            .blur(radius: blur)
    }

    /// A MESH, not a ramp. The old one was a three-stop LinearGradient between colours a few hex
    /// digits apart, which is a solid colour with extra steps — owner 2026-08-19, holding ours up
    /// against a picker full of colour: "ours looks dead".
    ///
    /// Colour arrives in a wallpaper from two places, and we were using neither. It moves DIAGONALLY
    /// (four corners bleeding into each other, so no two parts of the screen are the same), and it
    /// is SATURATED but even in brightness. That second half is the whole trick and it is the
    /// opposite of what this file used to do: we bought a readable background by draining the colour
    /// out of it, when the way to buy it is to keep every corner at the same lightness and let hue
    /// do the work. A bubble wins against a loud background as long as the background does not also
    /// go light and dark underneath it.
    private var ground: some View {
        MeshGradient(width: 3, height: 3,
                     points: WallpaperGradient.meshPoints,
                     colors: g.meshColors(dark))
    }

    /// The doodles are the GROUND AGAIN, darkened, showing through the pattern's own shape — so a
    /// doodle over the pink corner is pink and the same doodle over the blue corner is blue, and the
    /// texture moves with the colour instead of lying on top of it as one flat grey. That flat grey
    /// ink is the other half of why ours read as dead.
    ///
    /// Color.clear is the layout-defining view and the sheet rides as a CLIPPED overlay, the same
    /// shape the photo wallpaper uses: a bare scaledToFill re-flows when the container height
    /// changes (keyboard open/close) and nudges the composer.
    @ViewBuilder private var ink: some View {
        if let sheet = ChatPattern.sheet {
            ground
                .overlay(dark ? Color.white.opacity(0.10) : Color.black.opacity(0.15))
                .mask {
                    Color.clear
                        .overlay { Image(uiImage: sheet).resizable().scaledToFill() }
                        .clipped()
                }
        }
    }
}

enum ChatWallpapers {
    // BUILT-IN themes: never deletable (they aren't part of the user library at all).
    /// ONE PATTERN, SIX GROUNDS, A LIGHT AND A DARK OF EACH — his instruction, and how the reference
    /// apps actually ship this. Their picker is not a row of different drawings; it is the same
    /// doodle sheet over a row of colours, which is why it reads as one set rather than a collection
    /// somebody accumulated. Ours is now built that way for real: the sheet is `ChatPattern` and
    /// everything below is colour.
    ///
    /// The trick is the contrast, not the drawing. The ground carries the colour, the hairline
    /// doodles carry the texture, and the gap between them is small enough that a message bubble
    /// always wins — which is the whole job of a chat background.
    ///
    /// `sunset` and `mono` kept their ids — a chat that stored either still resolves — and are the
    /// Sunset and Graphite grounds. (`sunset` was called Paper while it was the drained one.)
    /// ⚠️ THE RULE THESE ARE BUILT ON, and it replaces the one that was here.
    ///
    /// The old six were measured out of the JPEGs they replaced, and those had been drained on
    /// purpose so a bubble could win: three stops a few hex digits apart, plus one flat grey ink.
    /// That bought readability by removing the colour, and it looked exactly like that.
    ///
    /// The trade is not real. A background stays readable when its BRIGHTNESS is even, not when its
    /// colour is gone — a bubble loses only where the ground goes light under one half of it and
    /// dark under the other. So every corner of a palette sits inside a narrow lightness band
    /// (about 216-234 in light, 35-47 in dark, on the usual 0.299/0.587/0.114 weighting) while the
    /// HUES are pushed as far apart as they can go. Loud and flat is the target; pale and flat was
    /// the mistake.
    ///
    /// Four corners each, top-left, top-right, bottom-left, bottom-right; the mesh fills in the
    /// rest. Adding a theme is still adding one row here — no asset, no app-size cost, no review.
    /// Graphite deliberately breaks the loudness half and not the flatness half: someone who wants
    /// a quiet chat should have one, and it is the only palette here whose corners are neutral.
    static let all: [WallpaperGradient] = [
        .init(id: "sunset", name: "Sunset",
              lightCorners: [0xFFD9C2, 0xFFE7B0, 0xFFC6D4, 0xEBC9F0],
              darkCorners:  [0x3C2119, 0x372A12, 0x361A28, 0x2C1C33],
              tint: Color(hex: 0xF08A5D), bubbleHex: 0xF08A5D),
        .init(id: "ocean", name: "Ocean",
              lightCorners: [0xBEE3FF, 0xC6F1EA, 0xD3DCFF, 0xAFDDF6],
              darkCorners:  [0x12314F, 0x113638, 0x1A2A55, 0x0F2D46],
              tint: Color(hex: 0x3DA1FD), bubbleHex: 0x2E8BF0),
        .init(id: "dusk", name: "Dusk",
              lightCorners: [0xE2CCFA, 0xF6CDEA, 0xCED4FA, 0xEBD2FF],
              darkCorners:  [0x2C1F4E, 0x3E1F44, 0x22224E, 0x341C4A],
              tint: Color(hex: 0x9B6DF3), bubbleHex: 0x8A5CF0),
        .init(id: "forest", name: "Forest",
              lightCorners: [0xCFEFCB, 0xE7F4C2, 0xC4EEDD, 0xDCF2CE],
              darkCorners:  [0x143A25, 0x1E3C1B, 0x113A33, 0x1A3A1F],
              tint: Color(hex: 0x34C76F), bubbleHex: 0x1FA85A),
        .init(id: "mono", name: "Graphite",
              lightCorners: [0xEFEFF2, 0xE6E6EB, 0xF2F1F5, 0xE9E8EE],
              darkCorners:  [0x18181B, 0x131316, 0x1C1C20, 0x141417],
              tint: Color(hex: 0x8E8E93), bubbleHex: 0x3A3A3C),
        .init(id: "rose", name: "Rose",
              lightCorners: [0xFFD2DB, 0xFFE2CE, 0xF9CBE7, 0xFFD8E9],
              darkCorners:  [0x3E1E2B, 0x40261E, 0x351A33, 0x3A1F3C],
              tint: Color(hex: 0xF06792), bubbleHex: 0xE84D86),
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

    /// Is there anything behind this chat's messages other than the plain app background?
    ///
    /// Read by the bubbles, not by the background: an incoming bubble is a flat colour on the plain
    /// background and a blur material on anything else (see `Theme.receivedStyle`). A solid `.color`
    /// wallpaper counts — it is still a surface the bubble can pick light off, and treating it as
    /// "no wallpaper" would give a chat two different bubble treatments for two things the user
    /// picked from the same screen.
    func hasWallpaper(for cid: String) -> Bool {
        wallpaper(for: cid) != .none
    }

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
// background (so nothing changes for chats without a wallpaper). A photo is dimmed in DARK MODE
// ONLY, by the reference app's 0.20 — see the overlay below for both numbers and why light mode
// now gets nothing.
struct ChatWallpaperBackground: View {
    let cid: String
    /// False only when this is being RENDERED TO AN IMAGE as the source for the incoming-bubble
    /// blur (see `WallpaperBlur`): the reference app blurs the undimmed wallpaper and does all its
    /// darkening in the wash, so blurring our photo scrim in first would darken a bubble twice.
    /// On screen this is always true and nothing about the picture changes.
    var includesScrim: Bool = true
    /// The box the photo solves its fill against, when it must not be the container's.
    ///
    /// nil keeps the old behaviour — fill whatever you are given — which is right for the places
    /// that draw this at their own size: the colour picker's preview, the chat peek platter, the
    /// announcements channel. Only the full-screen chat passes a size, and it passes the window's.
    var pictureSize: CGSize? = nil
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
                //
                // ⛔ AND THE PICTURE IS SOLVED AGAINST THE WINDOW, TOP-ANCHORED — owner, 2026-08-26:
                // with the keyboard up, tapping "+" or the GIF button made the wallpaper jump.
                //
                // Clipping stopped the photo feeding layout back OUT, but it did not stop layout
                // feeding IN. `scaledToFill` solves against the box it is offered, and that box was
                // the container — so every time the container's height changed (the keyboard
                // leaving while the attach panel arrives is two height changes in one transition)
                // the fill re-solved and the visible crop slid. Nothing was animating it; it was a
                // different crop of the same photo each pass.
                //
                // ⚠️ IT WAS ALSO A DISAGREEMENT WITH THE BUBBLES. `WallpaperBlur.renderWallpaper`
                // makes the blurred picture at `windowFrame` size, and every incoming bubble shows a
                // SLICE of that picture positioned in window coordinates. While the on-screen photo
                // was cropped to a shorter container, the bubbles were cut from a crop that was not
                // the one on screen. One constant box fixes both: the picture is the window's, so
                // the slices and the wallpaper are the same picture again.
                //
                // Top-anchored because the container is pinned to the window's top edge and only its
                // BOTTOM moves; centring would push the photo up by half of every height change.
                Color.clear
                    .overlay(alignment: .top) {
                        let picture = Image(uiImage: img).resizable().scaledToFill()
                        if let pictureSize {
                            picture.frame(width: pictureSize.width, height: pictureSize.height)
                        } else {
                            picture
                        }
                    }
                    .clipped()
                    // ⛔ THEIR NUMBERS, READ FROM THEIR SOURCE — his order 2026-08-24 after asking for
                    // the exact amounts rather than for an eyeball match.
                    //
                    //   light   nothing at all
                    //   dark    black at 0.20   (`dimmingView.backgroundColor = .ows_blackAlpha20`,
                    //                            applied only when the dark theme is on)
                    //
                    // ⚠️ THE LIGHT-MODE CHANGE IS NOT A BRIGHTNESS CHANGE, IT IS A REMOVAL. Ours laid
                    // white at 0.14 over a light-mode photo, which does not darken a picture, it fades
                    // it — the washed-out look in daylight. They lay nothing over it, so the photo is
                    // the photo. The old comment justified the scrim by bubble readability; theirs
                    // solves that in the BUBBLE instead, which is the wallpaper-slice wash we already
                    // ported, so the same job is not wanted twice.
                    //
                    // Dark goes 0.28 → 0.20, so the picture is 40% less dimmed than it was.
                    //
                    // ⚠️ Theirs is also a per-chat switch the user can turn off, defaulting on. Not
                    // built here — he asked for the amount, not the setting.
                    .overlay(includesScrim && dark ? Color.black.opacity(0.20) : Color.clear)
            } else {
                Theme.bg(dark)   // photo deleted from the library → fall back gracefully
            }
        case .color(let hex):
            Color(hex: hex)
        case .preset(let id):
            // ⚠️ NO SCRIM ON A BUILT-IN, and that is a decision rather than an omission.
            // The scrim exists because an imported gallery photo can be anything — a white
            // beach, a face, a screenshot — and bubbles have to survive it. A built-in is
            // not anything: it is a flat ground with hairline doodles at a contrast chosen
            // so the bubbles already win, and it carries a light AND a dark palette so it
            // never needs correcting toward the scheme. Washing 28% black over that only
            // removes the pattern it was made for. See `ChatWallpapers`.
            if let g = WallpaperPreset(id: id).theme {
                GradientWallpaperView(g: g, dark: dark)
            } else {
                Theme.bg(dark)
            }
        }
    }
}
