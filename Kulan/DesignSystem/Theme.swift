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

    /// THE SURFACE BEHIND A BUBBLE THAT IS NOT MINE, decided once and read by both render paths.
    ///
    /// Without a wallpaper it is `received` and nothing has changed. With one it is a SLICE of the
    /// blurred, washed wallpaper — the reference app's `CVWallpaperBlurView`, ported in
    /// `WallpaperBlur` with its numbers — so every bubble shows the part of the picture that sits
    /// under it, and a picture with light in it puts that light INSIDE the bubble. Reduce
    /// Transparency wins over all of it, exactly as theirs checks it first: the plain theme
    /// background, not the received grey, because the grey is a bubble-on-background colour and
    /// there is a picture here instead.
    ///
    /// `.material` is the one branch theirs does not have. It is what a surface falls back to when a
    /// wallpaper is present but no slice could be made for it — a preview platter that is not the
    /// size of the window, or a render that failed — and it is an approximation, kept only so those
    /// places still read as "on a wallpaper" rather than going flat.
    enum ReceivedSurface: Equatable {
        case flat(Color)
        case slice(WallpaperBlurState)
        case material
    }

    static func receivedSurface(_ dark: Bool, onWallpaper: Bool,
                                blur: WallpaperBlurState?) -> ReceivedSurface {
        guard onWallpaper else { return .flat(received(dark)) }
        if UIAccessibility.isReduceTransparencyEnabled { return .flat(bg(dark)) }
        if let blur { return .slice(blur) }
        return .material
    }

    /// The previews' version of the above — the colour-picker platter and the chat peek, which
    /// draw the wallpaper at a size that is not the window's and so cannot take a slice. Same
    /// decision, with `.material` drawn as the system material it approximates.
    static func receivedStyle(_ dark: Bool, onWallpaper: Bool) -> AnyShapeStyle {
        switch receivedSurface(dark, onWallpaper: onWallpaper, blur: nil) {
        case .flat(let c): return AnyShapeStyle(c)
        case .slice, .material: return AnyShapeStyle(dark ? Material.ultraThin : Material.thin)
        }
    }
    static func accent(_ dark: Bool) -> Color { dark ? .white : .black }
    static func onAccent(_ dark: Bool) -> Color { dark ? .black : .white }
    // Default outgoing-bubble colour when no custom Chat Color is picked. Apple systemBlue, which is a
    // DIFFERENT value in light vs dark mode (brighter in dark so it pops on the dark background). White
    // text/glyphs read well on both.
    static func defaultBubble(_ dark: Bool) -> Color { dark ? Color(hex: 0x0A84FF) : Color(hex: 0x007AFF) }
    static let secondary = Color(hex: 0x8E8E93)

    /// ⚠️ THE TOP CORNER OF A PANEL THAT STANDS IN FOR A SYSTEM SHEET, AND THERE IS ONE OF IT.
    ///
    /// This app draws its own sheets in two places — the viewers panel and the sticker tray — because
    /// the system's own presentation could not do what each needed. Both then have to answer the same
    /// question, "what does an Apple sheet's corner look like", and answering it twice is how they
    /// drifted: the tray was judged at 32 against the device-matched radius the system drew for it,
    /// while the viewers panel kept a 24 from before any of that, which is his 2026-08-18 "story
    /// viewer sheet corners, please use apple rounded corners" with both top corners circled.
    ///
    /// Continuous, not circular, and that is the half the number does not say. Apple's own sheet
    /// corner is a squircle; the STORY CARD's is a circle, measured off his reference the same day —
    /// two different shapes for two different things, both deliberate.
    static let sheetCorner: CGFloat = 32
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
    /// and the chat wallpaper scroll UNDER it (the big messengers look) — the input reads as floating on top
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

/// One of our own icons inside a MENU row or a swipe button, sized to sit level with the system's
/// SF Symbols beside it.
///
/// ONE NUMBER, MEASURED AGAINST THREE REPORTS RATHER THAN REASONED FROM THE FONT:
///
///  · **64pt** — the artwork's natural size. Every SVG in the set declares `width="64"` over a
///    24-unit viewBox, so with no size applied at all that is what UIKit drew, and it towered.
///  · **17pt** — the body font's point size. Too small, reported on build 448: "you made all of
///    them too small. Use the same dimensions as the other icons". A symbol's point size is not
///    its image size; UIKit gives an SF Symbol an image box around a quarter taller than the text
///    it is measured from, and our artwork fills its box edge to edge where a symbol's glyph sits
///    inside its own with room around it.
///  · **22pt** — that image box. Ours drawn to the same box is the same size on screen, which is
///    what "the same dimensions as the other icons" asks for.
///
/// Kept in one place. Nine call sites each carrying a copy is how the first sweep fixed some and
/// missed others, and how a wrong number then had to be found nine times.
/// THE THIRD REPORT SAYS BOX SIZE IS NOT WHAT ANYONE SEES (owner, chat-list menu, 2026-08-03:
/// "mute and pin delete that icons… use same size like other icons coz now looks small", with Unread
/// and Archive circled as the right size).
///
/// Everything above was about the BOX. A drawing does not fill its box by the same amount as the
/// next drawing: an SF Symbol is designed with air around its glyph so it can sit beside text, and
/// his own pin is a slim shape inside a 24-unit square. Give those the same 22pt box and they still
/// come out visibly smaller than an envelope or an archive tray that reaches its edges.
///
/// So the number is applied to the INK — the actual marked pixels — and not to the canvas around it.
/// Each icon is measured once, trimmed to what it actually draws, and scaled so its longest side is
/// `standard`. Icons then match each other by construction rather than by a number picked to suit
/// whichever one was reported last, which is what the three previous rounds each did.
struct MenuIcon: View {
    let name: String
    var size: CGFloat = MenuIcon.standard
    /// An Apple symbol rather than one of ours. Same treatment: symbols carry the most air of all.
    var system = false
    /// ⚠️ A COLOUR BAKED INTO THE BITMAP, INSTEAD OF A TEMPLATE THAT TAKES THE TINT — and nil, which
    /// is every existing caller, is exactly the behaviour there has always been.
    ///
    /// It exists for the two LONG-PRESS MENUS (his 2026-08-16 report: "the context menu icons is
    /// blue"). A SwiftUI `.contextMenu` is handed to UIKit, which builds a real `UIMenu` and tints
    /// its images with the PRESENTING VIEW'S `tintColor` — somewhere the app's `.tint(.primary)`
    /// never reaches, because that is a SwiftUI environment value. So those menus came out with
    /// `label` lettering and system-blue glyphs. A non-template image has no tint to take.
    ///
    /// ⚠️ NOT SET ON SWIPE ACTIONS, and that is deliberate rather than an omission: a swipe button
    /// paints its own background (`.tint(.orange)`, `.tint(.red)`) and draws its glyph white on top,
    /// so baking the ink there would put black on orange in light mode.
    ///
    /// Resolved against the CURRENT SCHEME rather than handed a dynamic colour, because a bitmap
    /// cannot be dynamic — reading `colorScheme` is what makes SwiftUI redraw it when the phone
    /// changes appearance.
    var ink: UIColor? = nil
    @Environment(\.colorScheme) private var scheme

    /// The size of an SF Symbol's image box at body size. Menus and swipe buttons both use it, so
    /// our icons are the same size as each other as well as the same size as the system's.
    static let standard: CGFloat = 22

    /// ROUND FOUR, AND THE ANSWER IS THAT INK IS NOT WEIGHT (owner, on Archive, Add Story and Change
    /// Wallpaper: "make it small, not too much small. It should be slightly reduced in size").
    ///
    /// Round three normalised every icon to the same amount of INK, which is why they now measure
    /// the same. But our drawings are solid, closed shapes and an SF Symbol is a thin outline, and
    /// the same square of ink carries far more weight filled than stroked — so ours still read as
    /// bigger even though they are not. Two points off closes it without making them small.
    ///
    /// Applied to OUR artwork only. The system's symbols stay at `standard`, because the complaint
    /// has never once been that a symbol looked too big, and shrinking those is what started this.
    static let custom: CGFloat = 20

    /// Our own artwork. Defaults to `custom`, two points under a symbol's box — see the note there.
    init(_ name: String, size: CGFloat = MenuIcon.custom, ink: UIColor? = nil) {
        self.name = name
        self.size = size
        self.ink = ink
    }

    init(system name: String, size: CGFloat = MenuIcon.standard, ink: UIColor? = nil) {
        self.name = name
        self.size = size
        self.system = true
        self.ink = ink
    }

    // A PRE-RENDERED UIImage at the target point size, NOT a frame-modified Image. Menus and
    // swipe actions convert their SwiftUI labels into native UIKit elements, and that conversion
    // DROPS view modifiers — .resizable().frame(17) simply never applied, so every custom asset
    // rendered at its intrinsic size and towered over the SF Symbols beside it (owner's Unread /
    // Archive / Add Story / swipe-Pin screenshots, the second time this symptom came back).
    // Baking the size into the bitmap is the one thing the conversion cannot ignore.
    var body: some View {
        if let ink {
            let traits = UITraitCollection(userInterfaceStyle: scheme == .dark ? .dark : .light)
            Image(uiImage: Self.rendered(name, size, system)
                    .withTintColor(ink.resolvedColor(with: traits), renderingMode: .alwaysOriginal))
        } else {
            Image(uiImage: Self.rendered(name, size, system)).renderingMode(.template)
        }
    }

    private static var cache: [String: UIImage] = [:]
    private static func rendered(_ name: String, _ size: CGFloat, _ system: Bool) -> UIImage {
        let key = "\(system ? "sf:" : "")\(name)|\(size)"
        if let hit = cache[key] { return hit }
        // Symbols are asked for at a large point size for the same reason the SVGs are 64pt: the ink
        // is measured on something big, so the measurement does not turn on a few edge pixels.
        let source: UIImage? = system
            ? UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: 64))
            : UIImage(named: name)
        guard let src = source, src.size.width > 0, src.size.height > 0 else { return UIImage() }
        let ink = inkRect(src) ?? CGRect(origin: .zero, size: src.size)
        let scale = min(size / ink.width, size / ink.height)
        let target = CGSize(width: ink.width * scale, height: ink.height * scale)
        let img = UIGraphicsImageRenderer(size: target).image { _ in
            // Draw the WHOLE icon, shifted so the ink lands at the origin; what falls outside the
            // target is exactly the air being trimmed.
            src.draw(in: CGRect(x: -ink.minX * scale, y: -ink.minY * scale,
                                width: src.size.width * scale, height: src.size.height * scale))
        }.withRenderingMode(.alwaysTemplate)
        cache[key] = img
        return img
    }

    /// Where an icon actually marks, in its own point coordinates. Rasterised at a fixed 64pt so a
    /// vector asset measures the same as a bitmap one, then read once down the alpha channel. Cached
    /// with the rendered image above, so this runs once per icon per launch.
    private static func inkRect(_ src: UIImage) -> CGRect? {
        let side: CGFloat = 64
        let s = min(side / src.size.width, side / src.size.height)
        let box = CGSize(width: max(1, src.size.width * s), height: max(1, src.size.height * s))
        let fmt = UIGraphicsImageRendererFormat.default()
        fmt.scale = 1
        let raster = UIGraphicsImageRenderer(size: box, format: fmt).image { _ in
            src.draw(in: CGRect(origin: .zero, size: box))
        }
        guard let cg = raster.cgImage else { return nil }
        let w = cg.width, h = cg.height
        guard w > 0, h > 0 else { return nil }
        var alpha = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(data: &alpha, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            let row = y * w
            for x in 0..<w where alpha[row + x] > 8 {   // 8, not 0: antialiasing leaves a faint halo
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(x: CGFloat(minX) / s, y: CGFloat(minY) / s,
                      width: CGFloat(maxX - minX + 1) / s, height: CGFloat(maxY - minY + 1) / s)
    }
}

// `RowPressFill` and `ScrollTouchDelayOff` lived here and are gone on the owner's word (2026-08-19):
// "remove the highlight grey we added when you tap a chat list row, back the way it was before."
//
// ⚠️ READ THIS BEFORE BUILDING IT AGAIN. The grey was asked for on 2026-08-13, and it took three
// attempts to make it appear at all, because the signal it was built on (`configuration.isPressed`
// on a plain ButtonStyle) never fired for a list row. What finally made it visible was driving the
// row from a gesture instead of a Button, and that is where the cost landed:
//   · 612 shipped with chat rows that could not be opened at all — the gesture took the tap.
//   · a ringed avatar then opened the story AND the chat together, leaving the story frozen.
//   · turning off `delaysContentTouches` app-wide, to make the gesture feel as quick as the Button
//     had, broke the story viewer's corner morph. He bisected that one to the build himself.
// Every one of those is a bug this app did not have while the row was a plain `Button`.
//
// If it is ever wanted again, the honest routes are a `NavigationLink` row (which gets UIKit's own
// cell highlight for free, and costs a disclosure chevron he has already rejected) or a UIKit list.
// Not a gesture over a Button.

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
        if let cached = await DiskImageCache.shared.image(for: s) {
            image = cached
            ProfilePhotoIndex.noteLoad(s, ok: true)
            return
        }
        if let (data, _) = try? await MediaSession.shared.data(from: url), let ui = UIImage(data: data) {
            DiskImageCache.shared.store(ui, data: data, for: s)
            image = ui
            ProfilePhotoIndex.noteLoad(s, ok: true)
            return
        }
        // NOTHING BEHIND THE URL. Told to the index, because the profile header has to answer
        // "circle or big photo" before it draws and cannot wait for a download of its own. Avatars
        // are everywhere — the chat list, the calls list, the story row — so by the time a profile
        // can be tapped, one of them has usually already found this out. See ProfilePhotoIndex.
        ProfilePhotoIndex.noteLoad(s, ok: false)
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

/// The SwiftUI surface behind an incoming bubble. Draws whatever `Theme.receivedSurface` decided;
/// the bubble's own `clipShape` after it is what gives it the bubble's shape.
struct ReceivedBubbleSurface: View {
    let dark: Bool
    let onWallpaper: Bool
    let blur: WallpaperBlurState?

    var body: some View {
        switch Theme.receivedSurface(dark, onWallpaper: onWallpaper, blur: blur) {
        case .flat(let c): c
        case .slice(let s): WallpaperBlurSlice(state: s)
        case .material: Rectangle().fill(dark ? Material.ultraThin : Material.thin)
        }
    }
}
