import SwiftUI
import PhotosUI
import CoreImage
import CoreImage.CIFilterBuiltins

// The Appearance system (user's reference set, 2026-07-24): a root page with a live
// preview, quick theme cards and four doors — Chat Wallpaper, Chat Color, App Icon,
// Night Mode — each its own page. Wallpaper/color picks here apply to ALL chats
// (a chat's own pick still wins); a full-screen preview with Blurred + "Apply For
// All Chats" sits between choosing and committing a wallpaper.

// MARK: - Night Mode (the old mode cards, now their own page)

struct NightModePage: View {
    @AppStorage("appearance") private var appearanceRaw = AppAppearance.system.rawValue

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                HStack(spacing: 14) {
                    ForEach(AppAppearance.allCases) { modeCard($0) }
                }
                Text("System follows your device setting.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .padding(20)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle("Night Mode")
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(AppAppearance(rawValue: appearanceRaw)?.colorScheme ?? nil)
    }

    private func modeCard(_ mode: AppAppearance) -> some View {
        let isSel = mode.rawValue == appearanceRaw
        return Button {
            withAnimation(.easeInOut(duration: 0.25)) { appearanceRaw = mode.rawValue }
        } label: {
            VStack(spacing: 8) {
                thumb(mode)
                    .frame(height: 74)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(isSel ? Color.accentColor : Color.primary.opacity(0.08),
                                          lineWidth: isSel ? 2 : 1)
                    )
                Text(mode.label)
                    .font(.footnote.weight(isSel ? .semibold : .regular))
                    .foregroundStyle(isSel ? Color.accentColor : Color.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private func thumb(_ mode: AppAppearance) -> some View {
        switch mode {
        case .light: miniChat(dark: false)
        case .dark:  miniChat(dark: true)
        case .system:
            ZStack {
                miniChat(dark: false)
                miniChat(dark: true).clipShape(AppearanceDiagonalHalf())
            }
        }
    }

    private func miniChat(dark: Bool) -> some View {
        VStack(spacing: 7) {
            Capsule().fill(dark ? Color(white: 0.24) : Color.white)
                .frame(width: 52, height: 13)
                .frame(maxWidth: .infinity, alignment: .leading)
            Capsule().fill(Theme.defaultBubble(dark))
                .frame(width: 52, height: 13)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(dark ? Color(white: 0.09) : Color(white: 0.93))
    }
}

struct AppearanceDiagonalHalf: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.width * 0.62, y: 0))
        p.addLine(to: CGPoint(x: rect.width, y: 0))
        p.addLine(to: CGPoint(x: rect.width, y: rect.height))
        p.addLine(to: CGPoint(x: rect.width * 0.38, y: rect.height))
        p.closeSubpath()
        return p
    }
}

// MARK: - Set Wallpaper (page: Choose from Photos + Presets grid)

struct ChatWallpaperPage: View {
    @Environment(\.colorScheme) private var scheme
    private var store: WallpaperStore { .shared }
    @State private var photoItem: PhotosPickerItem?
    @State private var previewing: ChatWallpaper?   // full-screen preview before applying

    private var dark: Bool { scheme == .dark }
    private let cols = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)

    var body: some View {
        let _ = store.version
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(spacing: 0) {
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        row("Choose from Photos")
                    }
                    .buttonStyle(.plain)
                    Divider().padding(.leading, 16)
                    // A dedicated Wallpaper COLOR page (solid background colour) — distinct from
                    // the bubble Chat Color (user request).
                    NavigationLink { WallpaperColorPage() } label: { row("Wallpaper Color") }
                        .buttonStyle(.plain)
                }
                .background(Color(.secondarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: 22, style: .continuous))

                Text("Presets").font(.title3.weight(.bold)).padding(.horizontal, 4)
                LazyVGrid(columns: cols, spacing: 10) {
                    presetTile(.none) {
                        Theme.bg(dark)
                    }
                    // Your own imported photos come FIRST (user request), newest first.
                    ForEach(store.libraryIds, id: \.self) { pid in
                        presetTile(.photo(pid)) {
                            Group {
                                if let img = store.libraryImage(pid) {
                                    // Color.clear takes the tile frame; the image fills it and
                                    // is clipped, so any aspect ratio crops uniformly (no bleed).
                                    Color.clear.overlay { Image(uiImage: img).resizable().scaledToFill() }.clipped()
                                } else {
                                    Color.secondary.opacity(0.15)
                                }
                            }
                        }
                        .contextMenu {
                            Button(role: .destructive) { store.deleteFromLibrary(pid) } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                    // Built-in PHOTO wallpapers.
                    ForEach(WallpaperPresets.all) { p in
                        presetTile(.preset(p.id)) {
                            Group {
                                if let img = p.image() {
                                    Color.clear.overlay { Image(uiImage: img).resizable().scaledToFill() }.clipped()
                                } else { Color.secondary.opacity(0.15) }
                            }
                        }
                    }
                    // Gradient wallpapers.
                    ForEach(ChatWallpapers.all) { g in
                        presetTile(.gradient(g.id)) {
                            LinearGradient(colors: g.colors(dark), startPoint: .top, endPoint: .bottom)
                        }
                    }
                }
                .padding(14)
                .background(Color(.secondarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle("Set Wallpaper")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let img = UIImage(data: data),
                   let id = await MainActor.run(body: { store.addToLibrary(img) }) {
                    await MainActor.run { previewing = .photo(id); photoItem = nil }
                }
            }
        }
        .fullScreenCover(item: $previewing) { w in
            WallpaperPreviewScreen(wallpaper: w)
        }
    }

    private var current: ChatWallpaper {
        ChatWallpaper(stored: UserDefaults.standard.string(forKey: WallpaperStore.defaultKey))
    }

    private func row(_ title: String) -> some View {
        HStack(spacing: 12) {
            Text(title).foregroundStyle(.primary)
            Spacer()
            Image(systemName: "chevron.right").font(.footnote.weight(.bold)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .contentShape(Rectangle())
    }

    private func presetTile<C: View>(_ w: ChatWallpaper, @ViewBuilder content: () -> C) -> some View {
        Button { previewing = w } label: {
            content()
                .frame(height: 150)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay {
                    if current == w {
                        Image(systemName: "checkmark")
                            .font(.system(size: 26, weight: .semibold))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.5), radius: 3)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// ChatWallpaper needs Identifiable for fullScreenCover(item:).
extension ChatWallpaper: Identifiable {
    var id: String { stored }
}

// MARK: - Wallpaper Color page (a solid-colour background, distinct from bubble colour)

struct WallpaperColorPage: View {
    @State private var previewing: ChatWallpaper?
    private var store: WallpaperStore { .shared }
    // Same grid as the Set Wallpaper page (user spec): colours are wallpapers, so they preview as
    // full tiles rather than little circles — you see the actual background you're choosing.
    private let cols = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)

    private var current: ChatWallpaper {
        ChatWallpaper(stored: UserDefaults.standard.string(forKey: WallpaperStore.defaultKey))
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: cols, spacing: 10) {
                ForEach(WallpaperColors.all, id: \.self) { hex in
                    Button { previewing = .color(hex) } label: {
                        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
                        Color(hex: hex)
                            .frame(height: 150)
                            .frame(maxWidth: .infinity)
                            .clipShape(shape)
                            .overlay(shape.strokeBorder(.primary.opacity(0.10), lineWidth: 1))
                            .overlay {
                                if current == .color(hex) {
                                    Image(systemName: "checkmark").font(.system(size: 26, weight: .semibold))
                                        .foregroundStyle(hexIsDark(hex) ? .white : .black)
                                        .shadow(color: .black.opacity(hexIsDark(hex) ? 0.5 : 0), radius: 3)
                                }
                            }
                            .contentShape(shape)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(14)
            .background(Color(.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .padding(16)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle("Wallpaper Color")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: $previewing) { WallpaperPreviewScreen(wallpaper: $0) }
    }

    private func hexIsDark(_ hex: UInt) -> Bool {
        let r = Double((hex >> 16) & 0xFF), g = Double((hex >> 8) & 0xFF), b = Double(hex & 0xFF)
        return (0.299*r + 0.587*g + 0.114*b) < 140
    }
}

// MARK: - Full-screen wallpaper preview (Blurred + Apply For All Chats)

struct WallpaperPreviewScreen: View {
    let wallpaper: ChatWallpaper
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @Environment(\.displayScale) private var displayScale
    @State private var blurred = false
    // Pinch-to-zoom / pan on a chosen photo, baked into the saved wallpaper on Apply.
    @State private var zoom: CGFloat = 1
    @State private var baseZoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var basePan: CGSize = .zero
    @State private var canvas: CGSize = .zero   // full-screen size = what gets baked
    private var store: WallpaperStore { .shared }
    private var dark: Bool { scheme == .dark }

    private var isPhoto: Bool { if case .photo = wallpaper { return true }; return false }
    private var photoImg: UIImage? {
        if case .photo(let id) = wallpaper { return store.libraryImage(id) }
        return nil
    }
    private var transformed: Bool { zoom != 1 || pan != .zero }

    // Keep the photo covering the whole screen while panning: clamp so no blank edge shows.
    private func clampedPan(_ proposed: CGSize, zoom z: CGFloat) -> CGSize {
        guard let img = photoImg, canvas.width > 0, img.size.width > 0, img.size.height > 0 else { return proposed }
        let fill = max(canvas.width / img.size.width, canvas.height / img.size.height)
        let s = fill * z
        let maxX = max(0, (img.size.width * s - canvas.width) / 2)
        let maxY = max(0, (img.size.height * s - canvas.height) / 2)
        return CGSize(width: min(maxX, max(-maxX, proposed.width)),
                      height: min(maxY, max(-maxY, proposed.height)))
    }

    var body: some View {
        ZStack {
            background.ignoresSafeArea()
                .background(
                    GeometryReader { proxy in
                        Color.clear
                            .onAppear { canvas = proxy.size }
                            .onChange(of: proxy.size) { _, s in canvas = s }
                    }
                    .ignoresSafeArea()
                )

            VStack {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.primary)
                            .frame(width: 44, height: 44)
                            .background(.regularMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)   // clear the top edge (status bar hidden below)

                Spacer()

                // Mock bubbles riding low, like the reference.
                VStack(spacing: 8) {
                    HStack { mockBubble("This is how the wallpaper looks", mine: false); Spacer(minLength: 40) }
                    HStack { Spacer(minLength: 40); mockBubble("Nice, applying it", mine: true) }
                }
                .padding(.horizontal, 14)

                if isPhoto {
                    Text("Pinch to zoom · drag to reposition")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.top, 12)

                    Button { withAnimation(.easeInOut(duration: 0.25)) { blurred.toggle() } } label: {
                        HStack(spacing: 8) {
                            Image(systemName: blurred ? "checkmark.circle.fill" : "circle")
                            Text("Blurred")
                        }
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 16).padding(.vertical, 9)
                        .background(.regularMaterial, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 10)
                }

                Button { apply() } label: {
                    Text("Apply For All Chats")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity).frame(height: 52)
                        .background(.regularMaterial, in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 20)
                .padding(.top, 10)
                .padding(.bottom, 12)
            }
        }
        .statusBarHidden()   // full-screen preview: no clock overlapping the X (user report)
    }

    @ViewBuilder private var background: some View {
        switch wallpaper {
        case .none:
            Theme.bg(dark)
        case .gradient(let id):
            if let g = ChatWallpapers.gradient(id) {
                LinearGradient(colors: g.colors(dark), startPoint: .top, endPoint: .bottom)
            } else { Theme.bg(dark) }
        case .photo(let id):
            if let img = store.libraryImage(id) {
                Color.clear
                    .overlay {
                        Image(uiImage: img).resizable().scaledToFill()
                            .scaleEffect(zoom)          // pinch (anchored at center, matches baking math)
                            .offset(pan)                // drag to reposition
                            .blur(radius: blurred ? 10 : 0)
                    }
                    .clipped()
                    .overlay(dark ? Color.black.opacity(0.28) : Color.white.opacity(0.14))
                    .contentShape(Rectangle())
                    .gesture(
                        SimultaneousGesture(
                            MagnifyGesture()
                                .onChanged { v in zoom = min(5, max(1, baseZoom * v.magnification)) }
                                .onEnded { _ in baseZoom = zoom; pan = clampedPan(pan, zoom: zoom); basePan = pan },
                            DragGesture()
                                .onChanged { v in
                                    pan = clampedPan(CGSize(width: basePan.width + v.translation.width,
                                                            height: basePan.height + v.translation.height), zoom: zoom)
                                }
                                .onEnded { _ in basePan = pan }
                        )
                    )
            } else { Theme.bg(dark) }
        case .color(let hex):
            Color(hex: hex)
        case .preset(let id):
            if let img = WallpaperPreset(id: id).image() {
                Color.clear
                    .overlay { Image(uiImage: img).resizable().scaledToFill().blur(radius: blurred ? 10 : 0) }
                    .clipped()
                    .overlay(dark ? Color.black.opacity(0.28) : Color.white.opacity(0.14))
            } else { Theme.bg(dark) }
        }
    }

    private func mockBubble(_ text: String, mine: Bool) -> some View {
        Text(text)
            .font(.system(size: 15))
            .foregroundStyle(mine ? .white : .primary)
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(mine ? AnyShapeStyle(Theme.defaultBubble(dark)) : AnyShapeStyle(.regularMaterial),
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func apply() {
        var final = wallpaper
        // Photo: bake the current framing (pinch-zoom + pan) AND the optional blur into one real
        // library image, so every chat renders it for free and there's exactly ONE tile.
        if case .photo(let id) = wallpaper, let img = store.libraryImage(id), (transformed || blurred) {
            // Start from the visible crop (or the whole image if no zoom/pan), then blur if chosen.
            let cropped = transformed
                ? (Self.renderCrop(img, canvas: canvas, scale: displayScale, zoom: zoom, pan: pan) ?? img)
                : img
            let finalImg = blurred ? (Self.gaussianBlur(cropped, radius: 10) ?? cropped) : cropped
            if let bakedId = store.addToLibrary(finalImg) {
                if bakedId != id { store.deleteFromLibrary(id) }   // no duplicate tile
                final = .photo(bakedId)
            }
        }
        store.applyToAllChats(final)
        dismiss()
    }

    // Render exactly what the user sees full-screen: scaledToFill base, then their pinch-zoom and
    // pan, drawn into a screen-sized (and -aspect) image so it applies 1:1 with no re-cropping.
    static func renderCrop(_ img: UIImage, canvas: CGSize, scale: CGFloat, zoom: CGFloat, pan: CGSize) -> UIImage? {
        let iw = img.size.width, ih = img.size.height
        guard iw > 0, ih > 0, canvas.width > 0, canvas.height > 0 else { return nil }
        let fill = max(canvas.width / iw, canvas.height / ih)
        let s = fill * zoom
        let drawW = iw * s, drawH = ih * s
        let x = (canvas.width - drawW) / 2 + pan.width
        let y = (canvas.height - drawH) / 2 + pan.height
        let fmt = UIGraphicsImageRendererFormat.default()
        fmt.scale = max(1, scale)
        fmt.opaque = true
        return UIGraphicsImageRenderer(size: canvas, format: fmt).image { _ in
            img.draw(in: CGRect(x: x, y: y, width: drawW, height: drawH))
        }
    }

    static func gaussianBlur(_ image: UIImage, radius: CGFloat) -> UIImage? {
        guard let input = CIImage(image: image) else { return nil }
        let filter = CIFilter.gaussianBlur()
        filter.inputImage = input.clampedToExtent()
        filter.radius = Float(radius)
        guard let out = filter.outputImage?.cropped(to: input.extent),
              let cg = CIContext().createCGImage(out, from: input.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

// MARK: - Chat Color (page: preview + circle grid, applies to all chats)

struct ChatColorPage: View {
    @Environment(\.colorScheme) private var scheme
    private var colorStore: ChatColorStore { .shared }
    @State private var showCustom = false
    private var dark: Bool { scheme == .dark }
    private let cols = Array(repeating: GridItem(.flexible(), spacing: 16), count: 5)

    private var selected: ChatColorSpec? {
        ChatColorSpec(stored: UserDefaults.standard.string(forKey: ChatColorStore.defaultKey))
    }

    var body: some View {
        let _ = colorStore.version
        ScrollView {
            VStack(spacing: 18) {
                // Live preview on the current all-chats wallpaper.
                VStack(spacing: 8) {
                    HStack { previewBubble("Here's a preview of the chat color.", mine: false); Spacer(minLength: 36) }
                    HStack { Spacer(minLength: 36); previewBubble("The color is visible to only you.", mine: true) }
                }
                .padding(16)
                .frame(maxWidth: .infinity)
                .background(previewBackground)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))

                LazyVGrid(columns: cols, spacing: 16) {
                    // "auto" = the app default blue.
                    circleButton(nil) {
                        Circle().fill(Theme.defaultBubble(dark))
                            .overlay(Text("auto").font(.system(size: 13, weight: .medium)).foregroundStyle(.white))
                    }
                    ForEach(ChatColors.presets) { p in
                        circleButton(p) { Circle().fill(p.fill) }
                    }
                    ForEach(colorStore.customColors) { p in
                        circleButton(p) { Circle().fill(p.fill) }
                            .contextMenu {
                                Button(role: .destructive) { colorStore.removeCustom(p) } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                    }
                    Button { showCustom = true } label: {
                        Circle().fill(Color(.systemGray5))
                            .overlay(Image(systemName: "plus").font(.system(size: 20, weight: .medium)).foregroundStyle(.primary))
                    }
                    .buttonStyle(.plain)
                }
                .padding(18)
                .background(Color(.secondarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle("Chat Color")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showCustom) {
            CustomColorView(cid: "__default__") { spec in
                colorStore.addCustom(spec)
                colorStore.applyToAllChats(spec)
            }
        }
    }

    @ViewBuilder private var previewBackground: some View {
        let w = ChatWallpaper(stored: UserDefaults.standard.string(forKey: WallpaperStore.defaultKey))
        switch w {
        case .none:
            Color(.secondarySystemGroupedBackground)
        case .gradient(let id):
            if let g = ChatWallpapers.gradient(id) {
                LinearGradient(colors: g.colors(dark), startPoint: .top, endPoint: .bottom)
            } else { Color(.secondarySystemGroupedBackground) }
        case .photo(let id):
            if let img = WallpaperStore.shared.libraryImage(id) {
                Color.clear.overlay { Image(uiImage: img).resizable().scaledToFill() }.clipped()
            } else { Color(.secondarySystemGroupedBackground) }
        case .color(let hex):
            Color(hex: hex)
        case .preset(let id):
            if let img = WallpaperPreset(id: id).image() {
                Color.clear.overlay { Image(uiImage: img).resizable().scaledToFill() }.clipped()
            } else { Color(.secondarySystemGroupedBackground) }
        }
    }

    private func previewBubble(_ text: String, mine: Bool) -> some View {
        Text(text)
            .font(.system(size: 14))
            .foregroundStyle(mine ? .white : .primary)
            .padding(.horizontal, 13).padding(.vertical, 8)
            .background(mine ? (selected.map { AnyShapeStyle($0.fill) } ?? AnyShapeStyle(Theme.defaultBubble(dark)))
                             : AnyShapeStyle(Color(.systemGray5)),
                        in: RoundedRectangle(cornerRadius: 17, style: .continuous))
    }

    private func circleButton<C: View>(_ spec: ChatColorSpec?, @ViewBuilder content: () -> C) -> some View {
        let isSel = selected?.stored == spec?.stored
        return Button { colorStore.applyToAllChats(spec) } label: {
            content()
                .frame(width: 54, height: 54)
                .overlay(Circle().strokeBorder(isSel ? Color.primary : .clear, lineWidth: 3).padding(-5))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - App Icon (alternate icons made from the user's logo)

struct AppIconPage: View {
    @State private var current = UIApplication.shared.alternateIconName

    // nil = the primary Midnight (white-on-black) icon from the asset catalog.
    private let icons: [(name: String?, label: String)] = [
        (nil, "Midnight"), ("icon-blue", "Blue"), ("icon-ivory", "Ivory"), ("icon-chrome", "Chrome"),
    ]
    private let cols = Array(repeating: GridItem(.flexible(), spacing: 18), count: 4)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                LazyVGrid(columns: cols, spacing: 18) {
                    ForEach(icons, id: \.label) { icon in
                        Button { choose(icon.name) } label: {
                            VStack(spacing: 6) {
                                iconImage(icon.name)
                                    .frame(width: 64, height: 64)
                                    .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 15, style: .continuous)
                                            .strokeBorder(current == icon.name ? Color.accentColor : Color.primary.opacity(0.1),
                                                          lineWidth: current == icon.name ? 2.5 : 1)
                                    )
                                Text(icon.label).font(.caption)
                                    .foregroundStyle(current == icon.name ? Color.accentColor : .secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity)
                .background(Color(.secondarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: 24, style: .continuous))

                Text("The icon changes on your Home Screen, in notifications and in the App Library.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle("App Icon")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder private func iconImage(_ name: String?) -> some View {
        if let name, let ui = UIImage(named: name) {
            Image(uiImage: ui).resizable().scaledToFill()
        } else if let ui = UIImage(named: "icon-1024") ?? Bundle.main.icon {
            Image(uiImage: ui).resizable().scaledToFill()
        } else {
            RoundedRectangle(cornerRadius: 15).fill(Color.black)
        }
    }

    private func choose(_ name: String?) {
        guard name != current else { return }
        UIApplication.shared.setAlternateIconName(name) { err in
            if err == nil { DispatchQueue.main.async { current = name } }
        }
    }
}

private extension Bundle {
    // The primary icon straight from the bundle (for the picker's "Midnight" tile).
    var icon: UIImage? {
        guard let icons = infoDictionary?["CFBundleIcons"] as? [String: Any],
              let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
              let files = primary["CFBundleIconFiles"] as? [String],
              let last = files.last else { return nil }
        return UIImage(named: last)
    }
}
