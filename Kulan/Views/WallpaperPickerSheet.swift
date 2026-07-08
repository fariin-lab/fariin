import SwiftUI
import PhotosUI

// Telegram-style "Select Theme" sheet, our own look. A native sheet with a row of gradient swatches
// + None (+ a Photos tile when a custom photo is the pick). Picking a swatch LIVE-previews it on the
// chat behind. The bottom button is contextual: "Choose Wallpaper from Photos" when nothing new is
// selected (settled), and morphs to "Apply Wallpaper" — tinted with the pick's own colour — the
// moment you choose a DIFFERENT wallpaper. On open it auto-scrolls to the wallpaper you're using so
// you can see it selected. Local per-chat only. Closing without applying reverts.
struct WallpaperPickerSheet: View {
    let cid: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    private var store: WallpaperStore { .shared }

    @State private var selected: ChatWallpaper
    @State private var photoItem: PhotosPickerItem?
    private let original: ChatWallpaper            // the wallpaper in use when the sheet opened

    init(cid: String) {
        self.cid = cid
        let cur = WallpaperStore.shared.wallpaper(for: cid)
        _selected = State(initialValue: cur)
        original = cur
    }

    private var dark: Bool { scheme == .dark }
    private var hasPendingChange: Bool { selected != original }

    // Stable id per selection, for the auto-scroll on open.
    private func tileID(_ w: ChatWallpaper) -> String {
        switch w {
        case .none:            return "none"
        case .gradient(let g): return g
        case .photo:           return "photo"
        }
    }

    // The vivid colour of the current pick → the Apply button's Liquid Glass tint.
    private var applyTint: Color {
        switch selected {
        case .gradient(let id): return ChatWallpapers.gradient(id)?.tint ?? Theme.accent(dark)
        case .photo:            return Theme.accent(dark)
        case .none:             return Color.secondary
        }
    }

    var body: some View {
        VStack(spacing: 16) {
            header
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        noneTile.id("none")
                        ForEach(ChatWallpapers.all) { g in gradientTile(g).id(g.id) }
                        if case .photo = selected { photosTile.id("photo") }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 4)
                }
                // Open scrolled to the wallpaper currently in use, so it's visible + clearly selected.
                .onAppear {
                    DispatchQueue.main.async {
                        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(tileID(selected), anchor: .center) }
                    }
                }
            }
            bottomBar
        }
        .padding(.vertical, 18)
        .presentationDetents([.height(300)])
        .presentationDragIndicator(.visible)
        // No live-apply and no revert: selecting only SELECTS (previews in the picker). The chat's
        // wallpaper is written to the store ONLY when Apply is pressed (user: "apply means save; when
        // chosen but not applied, don't put that wallpaper — only when apply").
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let img = UIImage(data: data) {
                    await MainActor.run {
                        store.savePhoto(img, for: cid)   // save the file so the tile can show it
                        preview(.photo)                  // select (highlight) — NOT applied yet
                    }
                }
            }
        }
    }

    private var header: some View {
        ZStack {
            Text("Chat Wallpaper").font(.headline)
            HStack {
                Button { dismiss() } label: {   // X = cancel (onDisappear reverts)
                    Image(systemName: "xmark").font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 48, height: 48)   // 48pt, real Liquid Glass
                        .liquidGlass(Circle(), interactive: true)
                }
                Spacer()
            }
        }
        .padding(.horizontal, 20)
    }

    // Contextual bottom button: settled → "Choose Wallpaper from Photos"; pending change → "Apply".
    @ViewBuilder private var bottomBar: some View {
        if hasPendingChange {
            Button {
                store.set(selected, for: cid)   // Apply = actually write the wallpaper now
                dismiss()
            } label: {
                Text("Apply Wallpaper").fontWeight(.semibold).font(.system(size: 17))
                    .foregroundStyle(selected == .none ? Color.primary : Color.white)
                    .frame(maxWidth: .infinity).frame(height: 52)
                    .liquidGlass(Capsule(), interactive: true, tint: applyTint)
                    .animation(.spring(response: 0.35, dampingFraction: 0.8), value: applyTint)
            }
            .padding(.horizontal, 20)
            .transition(.opacity)
        } else {
            PhotosPicker(selection: $photoItem, matching: .images, photoLibrary: .shared()) {
                HStack(spacing: 8) {
                    Image(systemName: "photo.on.rectangle.angled")
                    Text("Choose Wallpaper from Photos").fontWeight(.semibold)
                }
                .font(.system(size: 16)).foregroundStyle(.primary)
                .frame(maxWidth: .infinity).frame(height: 52)
                .liquidGlass(Capsule(), interactive: true)
            }
            .padding(.horizontal, 20)
            .transition(.opacity)
        }
    }

    // "None" swatch — clears back to the default app background.
    private var noneTile: some View {
        tile(isSelected: selected == .none) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Theme.bg(dark))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(.secondary.opacity(0.3), lineWidth: 1))
                .overlay {
                    VStack(spacing: 6) {
                        Image(systemName: "slash.circle").font(.system(size: 22, weight: .regular))
                        Text("None").font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(.secondary)
                }
        } action: { preview(.none) }
    }

    private func gradientTile(_ g: WallpaperGradient) -> some View {
        tile(isSelected: selected == .gradient(g.id)) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(LinearGradient(colors: g.colors(dark), startPoint: .top, endPoint: .bottom))
        } action: { preview(.gradient(g.id)) }
    }

    // Shown only when a custom photo is the current pick — displays it, selected; tap re-picks.
    private var photosTile: some View {
        PhotosPicker(selection: $photoItem, matching: .images, photoLibrary: .shared()) {
            tileFrame(isSelected: true) {
                Group {
                    if let img = store.photo(for: cid) {
                        Image(uiImage: img).resizable().scaledToFill()
                    } else {
                        RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.secondary.opacity(0.12))
                    }
                }
            }
        }
        .buttonStyle(.plain)
    }

    // Common swatch frame + selection ring + spring pop.
    private func tile<Content: View>(isSelected: Bool,
                                     @ViewBuilder _ content: () -> Content,
                                     action: @escaping () -> Void) -> some View {
        Button(action: action) { tileFrame(isSelected: isSelected, content) }
            .buttonStyle(.plain)
    }

    private func tileFrame<Content: View>(isSelected: Bool,
                                          @ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(width: 76, height: 108)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Theme.accent(dark), lineWidth: 3)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 20))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Theme.accent(dark))
                        .padding(6)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .scaleEffect(isSelected ? 1.04 : 1.0)   // gentle pop on the selected swatch
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isSelected)
    }

    // Select (highlight in the picker) only — does NOT touch the chat's wallpaper; Apply does that.
    private func preview(_ w: ChatWallpaper) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { selected = w }
    }
}
