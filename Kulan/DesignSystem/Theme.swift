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
    static func received(_ dark: Bool) -> Color { dark ? Color(hex: 0x26262B) : Color(hex: 0xE9E9EB) }
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

    /// FLOATING composer (`safeAreaInset`, no bar background) — the composer's own glass pills float over
    /// the wallpaper with NO frosted bar behind them, so there is no bottom band/border. `safeAreaBar`
    /// (a full-width native blur bar) DID band, because the message list does not scroll under it the way
    /// it scrolls under the system nav bar (the composer is not a system bar, so the under-bar trick that
    /// fixed the header can't apply without re-feeding the composer inset — the change that broke sending
    /// before). Transparent float = borderless and safe. scroll/sending untouched.
    func floatingBottomBar<C: View>(@ViewBuilder content: () -> C) -> some View {
        self.safeAreaInset(edge: .bottom, spacing: 0, content: content)
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

struct AvatarView: View {
    let name: String
    var photoUrl: String?
    var size: CGFloat = 48

    @State private var image: UIImage?

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
    }

    private func load() async {
        guard hasPhoto, let s = photoUrl, let url = URL(string: s) else { image = nil; return }
        if let cached = await DiskImageCache.shared.image(for: s) { image = cached; return }
        if let (data, _) = try? await URLSession.shared.data(from: url), let ui = UIImage(data: data) {
            DiskImageCache.shared.store(ui, data: data, for: s)
            image = ui
        }
    }

    private var fallback: some View {
        LinearGradient(colors: AvatarPalette.gradient(for: name), startPoint: .topLeading, endPoint: .bottomTrailing)
            .overlay(Text(initial).font(.system(size: size * 0.42, weight: .bold)).foregroundColor(.white))
    }
}
