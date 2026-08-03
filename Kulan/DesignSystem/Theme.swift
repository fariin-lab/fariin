import SwiftUI
import UIKit

// Design tokens ported from the RN colors.ts (one deep-contrast theme for both modes).
extension Color {
    init(hex: UInt) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xff) / 255,
            green: Double((hex >> 8) & 0xff) / 255,
            blue: Double(hex & 0xff) / 255,
            opacity: 1
        )
    }
}

// App-wide appearance override (persisted in UserDefaults via @AppStorage).
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

enum Theme {
    static func bg(_ dark: Bool) -> Color { dark ? Color(hex: 0x121214) : Color(hex: 0xFFFFFF) }
    static func bgSecondary(_ dark: Bool) -> Color { dark ? Color(hex: 0x121214) : Color(hex: 0xF2F2F7) }
    static func card(_ dark: Bool) -> Color { dark ? Color(hex: 0x26262B) : Color(hex: 0xFFFFFF) }
    // Light received-bubble = F2F2F2, the owner's exact pick (2026-07-31 screenshot). Must stay in
    // lock-step with UIKitBubbleCell.receivedFill or text rows and media rows show two grays.
    static func received(_ dark: Bool) -> Color { dark ? Color(hex: 0x26262B) : Color(hex: 0xF2F2F2) }
    static func accent(_ dark: Bool) -> Color { dark ? .white : .black }
    static func onAccent(_ dark: Bool) -> Color { dark ? .black : .white }
    // Default outgoing-bubble colour when no custom Chat Color is picked. Apple systemBlue, which is a
    // DIFFERENT value in light vs dark mode (brighter in dark so it pops on the dark background). White
    // text/glyphs read well on both.
    static func defaultBubble(_ dark: Bool) -> Color { dark ? Color(hex: 0x0A84FF) : Color(hex: 0x007AFF) }
    static let secondary = Color(hex: 0x8E8E93)
}

enum AvatarPalette {
    static let gradients: [[Color]] = [
        [Color(hex: 0x2563EB), Color(hex: 0x3B82F6)],
        [Color(hex: 0x7C3AED), Color(hex: 0x8B5CF6)],
        [Color(hex: 0xEC4899), Color(hex: 0xF43F5E)],
        [Color(hex: 0x059669), Color(hex: 0x10B981)],
        [Color(hex: 0xD97706), Color(hex: 0xF59E0B)],
        [Color(hex: 0xDC2626), Color(hex: 0xEF4444)],
        [Color(hex: 0x0891B2), Color(hex: 0x06B6D4)],
        [Color(hex: 0x4F46E5), Color(hex: 0x6366F1)],
    ]
    static func gradient(for name: String) -> [Color] {
        let clean = name.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { return gradients[0] }
        var h = 0
        for ch in clean.unicodeScalars { h = (h &* 31 &+ Int(ch.value)) & 0x7fffffff }
        return gradients[h % gradients.count]
    }
}

extension View {
    /// Real iOS 26 Liquid Glass when available; frosted material fallback below it.
    /// `interactive: true` gives the same touch-reactive glass animation as the toolbar buttons.
    /// `tint:` gives a coloured Liquid Glass (e.g. the blue NEXT button) — still translucent glass,
    /// not a flat fill.
    /// `enabled: false` turns the glass OFF without changing the view tree — for views that
    /// must never unmount mid-gesture (e.g. the hold-to-record mic, whose glass would
    /// otherwise melt into the neighbouring composer glass while scaled/dragged).
    @ViewBuilder
    func liquidGlass(_ shape: some Shape = Capsule(), interactive: Bool = false, tint: Color? = nil, enabled: Bool = true) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect({
                guard enabled else { return Glass.identity }   // glass off, view tree unchanged
                var g: Glass = .regular
                if let tint { g = g.tint(tint) }
                return interactive ? g.interactive() : g
            }(), in: shape)
        } else if let tint {
            self.background(tint.opacity(0.85).opacity(enabled ? 1 : 0), in: shape)
                .background(.ultraThinMaterial.opacity(enabled ? 1 : 0), in: shape)
        } else {
            self.background(.ultraThinMaterial.opacity(enabled ? 1 : 0), in: shape)
        }
    }

    /// Composer dock (build-292 model): `safeAreaBar` floats the composer OVER the messages so the content
    /// and the chat wallpaper scroll UNDER it (Telegram/iMessage look) — the input reads as floating on top
    /// of the conversation, not sitting on a solid strip. `safeAreaInset` was WRONG here: it reserves a
    /// strip and pushes content ABOVE it, so behind the composer there was only the plain (white) app
    /// background instead of the wallpaper/messages. safeAreaBar still grows the bottom safe area and rides
    /// the keyboard, so the native content-inset (.always) keyboard model is unchanged. safeAreaInset is the
    /// pre-iOS-26 fallback.
    @ViewBuilder
    func floatingBottomBar<C: View>(@ViewBuilder content: () -> C) -> some View {
        if #available(iOS 26.0, *) {
            self.safeAreaBar(edge: .bottom, content: content)
        } else {
            self.safeAreaInset(edge: .bottom, spacing: 0, content: content)
        }
    }

}

/// The app's standard 48pt Liquid Glass close button — a round X, used in toolbars in place of a
/// "Cancel" text button (GIF picker, Edit Profile, wallpaper sheet) so every dismiss looks the same.
struct CloseXButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark").font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 48, height: 48)
                .liquidGlass(Circle(), interactive: true)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

/// One of our own icons inside a MENU row, sized to sit level with the system's SF Symbols.
///
/// A menu's SF Symbol comes from the body font, and its visible glyph lands around 15pt inside a
/// box noticeably bigger than that. So an asset drawn at the size of that BOX reads as oversized
/// beside it, which is what 20pt did — reported twice, on Chats, Add Story and Archive.
///
/// One number in one place. Nine call sites each carrying their own copy is how the first sweep
/// fixed some and left others, and how the wrong number then had to be found nine times.
struct MenuIcon: View {
    let name: String
    var size: CGFloat = 17

    init(_ name: String, size: CGFloat = 17) {
        self.name = name
        self.size = size
    }

    // A PRE-RENDERED UIImage at the target point size, NOT a frame-modified Image. Menus and
    // swipe actions convert their SwiftUI labels into native UIKit elements, and that conversion
    // DROPS view modifiers — .resizable().frame(17) simply never applied, so every custom asset
    // rendered at its intrinsic size and towered over the SF Symbols beside it (owner's Unread /
    // Archive / Add Story / swipe-Pin screenshots, the second time this symptom came back).
    // Baking the size into the bitmap is the one thing the conversion cannot ignore.
    var body: some View {
        Image(uiImage: Self.rendered(name, size)).renderingMode(.template)
    }

    private static var cache: [String: UIImage] = [:]
    private static func rendered(_ name: String, _ size: CGFloat) -> UIImage {
        let key = "\(name)|\(size)"
        if let hit = cache[key] { return hit }
        guard let src = UIImage(named: name), src.size.width > 0, src.size.height > 0 else { return UIImage() }
        let scale = min(size / src.size.width, size / src.size.height)
        let target = CGSize(width: src.size.width * scale, height: src.size.height * scale)
        let img = UIGraphicsImageRenderer(size: target).image { _ in
            src.draw(in: CGRect(origin: .zero, size: target))
        }.withRenderingMode(.alwaysTemplate)
        cache[key] = img
        return img
    }
}

struct AvatarView: View {
    let name: String
    var photoUrl: String?
    var size: CGFloat = 48
    /// Reports whether a REAL photo is on screen, as opposed to the letter fallback. A non-empty
    /// photoUrl is NOT the same thing: a removed or stale url still loads nothing, and a caller that
    /// trusted the string made the avatar "openable" into an empty circle (owner's screenshot).
    var onPhotoResolved: ((Bool) -> Void)?

    @State private var image: UIImage?

    init(name: String, photoUrl: String? = nil, size: CGFloat = 48,
         onPhotoResolved: ((Bool) -> Void)? = nil) {
        self.name = name
        self.photoUrl = photoUrl
        self.size = size
        self.onPhotoResolved = onPhotoResolved
        // FIRST-FRAME seed. Memory, then DISK if memory has not been warmed yet.
        //
        // Memory alone was not enough: it starts empty on every launch and is dropped on every
        // backgrounding, so on a cold start EVERY avatar fell through to its coloured letter and
        // cross-faded to the real photo a frame later, even though the file had been on disk for
        // days. That is the flash of letters the owner photographed on the chat list.
        //
        // The disk read is synchronous and that is deliberate: an avatar is a few KB, it is gated on
        // the cache's in-memory index so a miss never touches the filesystem, and the result is
        // promoted to memory so each photo pays once per launch.
        if let u = photoUrl, !u.isEmpty, let warm = DiskImageCache.shared.smallImageSync(u) {
            _image = State(initialValue: warm)
        }
    }

    private var hasPhoto: Bool { (photoUrl?.isEmpty == false) }
    private var initial: String {
        let c = name.trimmingCharacters(in: .whitespaces).first
        return c.map { String($0).uppercased() } ?? "?"
    }

    var body: some View {
        Group {
            if let image {
                // Cached image -> instant, no AsyncImage reload flash; scaledToFill before clip.
                Image(uiImage: image).resizable().scaledToFill()
                    .transition(.opacity)
            } else {
                fallback
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .animation(.easeOut(duration: 0.25), value: image != nil)   // cross-fade in on load (no blink)
        .task(id: photoUrl) { await load() }
        // Fires on the first frame (memory-cache seed) and again when a load resolves or fails.
        .onChange(of: image != nil, initial: true) { _, has in onPhotoResolved?(has) }
    }

    private func load() async {
        guard hasPhoto, let s = photoUrl, let url = URL(string: s) else { image = nil; return }
        if let cached = await DiskImageCache.shared.image(for: s) { image = cached; return }
        if let (data, _) = try? await MediaSession.shared.data(from: url), let ui = UIImage(data: data) {
            DiskImageCache.shared.store(ui, data: data, for: s)
            image = ui
        }
    }

    private var fallback: some View {
        LinearGradient(colors: AvatarPalette.gradient(for: name), startPoint: .topLeading, endPoint: .bottomTrailing)
            .overlay(Text(initial).font(.system(size: size * 0.42, weight: .bold)).foregroundColor(.white))
    }
}

/// Google's multi-colour "G" mark, for the Google sign-in and connect rows. A plain letter "G" read
/// as a placeholder next to Apple's real glyph, and there is no SF Symbol for it - Apple does not
/// ship third-party brand logos, so this has to be a bundled image.
///
/// It lives in the ASSET CATALOG. It was previously a loose PNG in Resources/Brand, and
/// `Image("google-g")` does not search subfolders, so it silently resolved to nothing and the row
/// drew an empty gap where the logo should be.
struct GoogleGIcon: View {
    var size: CGFloat = 20
    var body: some View {
        Image("google-g")
            .renderingMode(.original)   // keep Google's four colours, never tinted by the row
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
    }
}
