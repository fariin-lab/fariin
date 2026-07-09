import SwiftUI
import UIKit

extension Notification.Name {
    // Posted with the cid as `object` when "Change Wallpaper" is tapped in a profile; the open
    // ThreadView for that cid catches it and presents the picker.
    static let openChatWallpaper = Notification.Name("openChatWallpaper")
}

// A per-chat wallpaper the user sets for THEMSELVES (like WhatsApp) — stored locally, never
// synced to the other person and never uploaded. Three kinds: none (default app background),
// one of the built-in gradients, or a custom photo saved to app storage.
enum ChatWallpaper: Equatable {
    case none
    case gradient(String)   // gradient id (ChatWallpapers.all)
    case photo              // custom photo, on disk keyed by cid

    // Compact string form for UserDefaults.
    var stored: String {
        switch self {
        case .none:            return "none"
        case .gradient(let g): return "g:\(g)"
        case .photo:           return "photo"
        }
    }
    init(stored: String?) {
        switch stored {
        case "photo": self = .photo
        case let s? where s.hasPrefix("g:"): self = .gradient(String(s.dropFirst(2)))
        default: self = .none
        }
    }
}

// A built-in gradient wallpaper with light + dark palettes (so a chat looks right in either mode).
struct WallpaperGradient: Identifiable, Equatable {
    let id: String
    let name: String
    let light: [Color]
    let dark: [Color]
    let tint: Color        // vivid representative colour → the "Apply Wallpaper" button tint
    func colors(_ dark: Bool) -> [Color] { dark ? self.dark : light }
}

enum ChatWallpapers {
    // Kept subtle so message bubbles always read clearly on top (the top→bottom fall is gentle).
    static let all: [WallpaperGradient] = [
        .init(id: "sunset", name: "Sunset",
              light: [Color(hex: 0xFFE9C7), Color(hex: 0xFFC9AE), Color(hex: 0xF6AEC6)],
              dark:  [Color(hex: 0x3A2A2C), Color(hex: 0x2A1E28), Color(hex: 0x1C161C)],
              tint: Color(hex: 0xF08A5D)),
        .init(id: "ocean", name: "Ocean",
              light: [Color(hex: 0xD6ECFF), Color(hex: 0xB8DCF6), Color(hex: 0xA6D5E6)],
              dark:  [Color(hex: 0x16283A), Color(hex: 0x142430), Color(hex: 0x101A22)],
              tint: Color(hex: 0x3DA1FD)),
        .init(id: "dusk", name: "Dusk",
              light: [Color(hex: 0xE7D9FF), Color(hex: 0xD3C1F5), Color(hex: 0xF3C6E4)],
              dark:  [Color(hex: 0x2A2340), Color(hex: 0x231C33), Color(hex: 0x1A1626)],
              tint: Color(hex: 0x9B6DF3)),
        .init(id: "forest", name: "Forest",
              light: [Color(hex: 0xDCF3D8), Color(hex: 0xBFE7C2), Color(hex: 0xA9DCC9)],
              dark:  [Color(hex: 0x1B2E22), Color(hex: 0x18271F), Color(hex: 0x121C18)],
              tint: Color(hex: 0x34C76F)),
        .init(id: "mono", name: "Mono",
              light: [Color(hex: 0xF2F2F5), Color(hex: 0xE4E4E9), Color(hex: 0xD5D5DB)],
              dark:  [Color(hex: 0x1E1E22), Color(hex: 0x191919), Color(hex: 0x121214)],
              tint: Color(hex: 0x8E8E93)),
        .init(id: "rose", name: "Rose",
              light: [Color(hex: 0xFFE1E6), Color(hex: 0xFFC9D5), Color(hex: 0xFAB0C6)],
              dark:  [Color(hex: 0x33212A), Color(hex: 0x2A1B24), Color(hex: 0x1D141A)],
              tint: Color(hex: 0xF06792)),
    ]
    static func gradient(_ id: String) -> WallpaperGradient? { all.first { $0.id == id } }
}

// Observable so setting a wallpaper re-renders the open chat instantly (live preview in the picker).
// The caches are observation-IGNORED (mutating them during a view-body read would trip "modifying
// state during view update"); re-renders are driven by the observed `version` counter, which set()
// bumps. A view that wants to react reads `version` before calling `wallpaper(for:)`.
@Observable final class WallpaperStore {
    static let shared = WallpaperStore()
    private(set) var version = 0
    @ObservationIgnored private var cache: [String: ChatWallpaper] = [:]
    @ObservationIgnored private var photoCache: [String: UIImage] = [:]

    func wallpaper(for cid: String) -> ChatWallpaper {
        if let c = cache[cid] { return c }
        let w = ChatWallpaper(stored: UserDefaults.standard.string(forKey: Self.key(cid)))
        cache[cid] = w
        return w
    }

    func set(_ w: ChatWallpaper, for cid: String) {
        cache[cid] = w
        UserDefaults.standard.set(w.stored, forKey: Self.key(cid))
        version &+= 1                                           // observed → live re-render
    }

    // Custom photo — saved to app storage, keyed by cid. Downscaled so we never hold a huge image.
    @discardableResult
    func savePhoto(_ image: UIImage, for cid: String) -> Bool {
        let scaled = Self.downscale(image, maxDimension: 1600)
        guard let data = scaled.jpegData(compressionQuality: 0.85) else { return false }
        let url = Self.photoURL(cid)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        do { try data.write(to: url, options: .atomic); photoCache[cid] = scaled; version &+= 1; return true }
        catch { return false }
    }

    func photo(for cid: String) -> UIImage? {
        if let c = photoCache[cid] { return c }
        guard let img = UIImage(contentsOfFile: Self.photoURL(cid).path) else { return nil }
        photoCache[cid] = img
        return img
    }

    private static func key(_ cid: String) -> String { "wallpaper.\(cid)" }
    private static func photoURL(_ cid: String) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        // sanitise cid (cids are safe already, but be defensive about slashes)
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
                LinearGradient(colors: g.colors(dark), startPoint: .top, endPoint: .bottom)
            } else {
                Theme.bg(dark)
            }
        case .photo:
            if let img = store.photo(for: cid) {
                // Color.clear is the layout-defining view (size-neutral, fills like the .none color
                // case) and the photo rides as a CLIPPED overlay. A bare scaledToFill Image re-flows
                // when the container height changes (keyboard open/close), which nudged the composer;
                // clipping the overlay keeps the fill from ever feeding layout back, so it's rock-stable.
                Color.clear
                    .overlay { Image(uiImage: img).resizable().scaledToFill() }
                    .clipped()
                    .overlay(dark ? Color.black.opacity(0.28) : Color.white.opacity(0.14))
            } else {
                Theme.bg(dark)   // photo missing (never saved / cleared) → fall back gracefully
            }
        }
    }
}
