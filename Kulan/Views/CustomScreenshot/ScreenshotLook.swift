import SwiftUI
import UIKit

// Customize screenshot (owner 2026-11-13): the look a picture is drawn in.

/// A theme the person can pick under the picture: the chat's own look first, then the app's
/// built-in wallpapers. Only built-ins are offered, never another chat's photo wallpaper.
enum ShotTheme: Hashable, Identifiable {
    case current
    case builtIn(String)   // a `ChatWallpapers` id

    var id: String {
        switch self {
        case .current: return "current"
        case .builtIn(let g): return "g:" + g
        }
    }

    static func all() -> [ShotTheme] {
        [.current] + ChatWallpapers.listed.map { .builtIn($0.id) }
    }
}

/// What sits behind the messages.
enum ShotBackground {
    case plain
    case gradient(WallpaperGradient)
    case photo(UIImage)
    case color(UInt)
}

/// Everything the drawing needs, resolved once. A picture is rendered offscreen to an image, so it
/// must not read live stores or system materials while it draws: a material renders as nothing in
/// an offscreen image, which is why the incoming bubble here is a solid tint, not the chat's blur.
struct ShotLook {
    let background: ShotBackground
    let bubble: ChatColorSpec?
    let dark: Bool

    var onWallpaper: Bool {
        if case .plain = background { return false }
        return true
    }

    static func resolve(_ theme: ShotTheme, cid: String, dark: Bool) -> ShotLook {
        switch theme {
        case .current:
            return ShotLook(background: currentBackground(cid),
                            bubble: ChatColorStore.shared.color(for: cid), dark: dark)
        case .builtIn(let id):
            guard let g = ChatWallpapers.gradient(id) else {
                return ShotLook(background: .plain, bubble: nil, dark: dark)
            }
            return ShotLook(background: .gradient(g), bubble: g.autoColor, dark: dark)
        }
    }

    private static func currentBackground(_ cid: String) -> ShotBackground {
        let store = WallpaperStore.shared
        switch store.wallpaper(for: cid) {
        case .none: return .plain
        case .gradient(let id): return ChatWallpapers.gradient(id).map { .gradient($0) } ?? .plain
        case .preset(let id): return WallpaperPreset(id: id).theme.map { .gradient($0) } ?? .plain
        case .photo(let id): return store.libraryImage(id).map { .photo($0) } ?? .plain
        case .color(let hex): return .color(hex)
        // A moving wallpaper has no still frame of its own to put in a picture; the plain chat
        // background stands in for it.
        case .animated: return .plain
        }
    }

    // MARK: Colours

    var sentFill: AnyShapeStyle {
        if let bubble { return bubble.fill }
        return AnyShapeStyle(Theme.defaultBubble(dark))
    }

    var receivedFill: Color {
        if onWallpaper {
            return dark ? Color(hex: 0x26262B).opacity(0.88) : Color.white.opacity(0.92)
        }
        return Theme.received(dark)
    }

    var receivedText: Color { dark ? .white : .black }
    var receivedMeta: Color { dark ? Color.white.opacity(0.55) : Color.black.opacity(0.45) }
    var sentMeta: Color { Color.white.opacity(0.7) }

    /// Day pills, system lines and the logo badge: a soft capsule that reads on any background.
    var chipFill: Color {
        onWallpaper ? Color.black.opacity(dark ? 0.35 : 0.22)
                    : (dark ? Color(hex: 0x26262B) : Color(hex: 0xEBEBF0))
    }
    /// The footer's "Fariin" and logo: the incoming bubble's colour on a wallpaper, a quiet grey on
    /// the plain background (where that colour would vanish).
    var footerInk: Color {
        onWallpaper ? Color.white.opacity(dark ? 0.75 : 0.95) : receivedMeta
    }

    var chipText: Color { onWallpaper ? .white : (dark ? Color.white.opacity(0.8) : Color.black.opacity(0.6)) }
}

/// The background drawn for a look, at whatever size it is given.
struct ShotBackgroundView: View {
    let look: ShotLook

    var body: some View {
        switch look.background {
        case .plain:
            Theme.bg(look.dark)
        case .gradient(let g):
            GradientWallpaperView(g: g, dark: look.dark)
        case .color(let hex):
            Color(hex: hex)
        case .photo(let img):
            // Clear is the size; the photo fills it as a clipped overlay so it never sizes the page.
            Color.clear
                .overlay { Image(uiImage: img).resizable().scaledToFill() }
                .clipped()
                .overlay(look.dark ? Color.black.opacity(0.20) : Color.clear)
        }
    }
}
