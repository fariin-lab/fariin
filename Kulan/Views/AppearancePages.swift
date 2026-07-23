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
                PhotosPicker(selection: $photoItem, matching: .images) {
                    HStack(spacing: 12) {
                        Text("Choose from Photos").foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "chevron.right").font(.footnote.weight(.bold)).foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 14)
                    .background(Color(.secondarySystemGroupedBackground),
                                in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Text("Presets").font(.title3.weight(.bold)).padding(.horizontal, 4)
                LazyVGrid(columns: cols, spacing: 10) {
                    presetTile(.none) {
                        Theme.bg(dark)
                    }
                    ForEach(ChatWallpapers.all) { g in
                        presetTile(.gradient(g.id)) {
                            LinearGradient(colors: g.colors(dark), startPoint: .top, endPoint: .bottom)
                        }
                    }
                    ForEach(store.libraryIds, id: \.self) { pid in
                        presetTile(.photo(pid)) {
                            Group {
                                if let img = store.libraryImage(pid) {
                                    Image(uiImage: img).resizable().scaledToFill()
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

// MARK: - Full-screen wallpaper preview (Blurred + Apply For All Chats)

struct WallpaperPreviewScreen: View {
    let wallpaper: ChatWallpaper
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var blurred = false
    private var store: WallpaperStore { .shared }
    private var dark: Bool { scheme == .dark }

    private var isPhoto: Bool { if case .photo = wallpaper { return true }; return false }

    var body: some View {
        ZStack {
            background.ignoresSafeArea()

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

                Spacer()

                // Mock bubbles riding low, like the reference.
                VStack(spacing: 8) {
                    HStack { mockBubble("This is how the wallpaper looks", mine: false); Spacer(minLength: 40) }
                    HStack { Spacer(minLength: 40); mockBubble("Nice, applying it", mine: true) }
                }
                .padding(.horizontal, 14)

                if isPhoto {
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
                    .padding(.top, 12)
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
                    .overlay { Image(uiImage: img).resizable().scaledToFill().blur(radius: blurred ? 22 : 0) }
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
        // Blurred photo: bake the blur into a real library image so every chat renders it
        // for free (no live blur cost), and the pick stays a normal library wallpaper.
        if blurred, case .photo(let id) = wallpaper, let img = store.libraryImage(id),
           let baked = Self.gaussianBlur(img, radius: 22),
           let bakedId = store.addToLibrary(baked) {
            final = .photo(bakedId)
        }
        store.applyToAllChats(final)
        dismiss()
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

    // nil = the primary chrome-on-black icon from the asset catalog.
    private let icons: [(name: String?, label: String)] = [
        (nil, "Midnight"), ("icon-ivory", "Ivory"), ("icon-ocean", "Ocean"), ("icon-forest", "Forest"),
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
