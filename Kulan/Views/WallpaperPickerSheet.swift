import SwiftUI
import PhotosUI

// Telegram-style "Select Theme" sheet, our own look. A native sheet (standard sheet material — no
// custom floating card, which double-stacked with the sheet chrome). A row of gradient swatches +
// None + a Photos tile; picking a swatch LIVE-previews it on the chat behind. The bottom button is
// "Apply Wallpaper", tinted with the selected wallpaper's own colour. Closing (X / swipe) without
// applying reverts to what it was. Local per-chat only.
struct WallpaperPickerSheet: View {
    let cid: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    private var store: WallpaperStore { .shared }

    @State private var selected: ChatWallpaper
    @State private var committed = false          // Apply pressed → don't revert on disappear
    @State private var photoItem: PhotosPickerItem?
    private let original: ChatWallpaper            // restore this if the user cancels

    init(cid: String) {
        self.cid = cid
        let cur = WallpaperStore.shared.wallpaper(for: cid)
        _selected = State(initialValue: cur)
        original = cur
    }

    private var dark: Bool { scheme == .dark }

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
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    noneTile
                    ForEach(ChatWallpapers.all) { g in gradientTile(g) }
                    photosTile
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 4)
            }
            applyButton
        }
        .padding(.vertical, 18)
        .presentationDetents([.height(300)])
        .presentationDragIndicator(.visible)
        // Cancel path (X or swipe-down without Apply) restores the wallpaper that was there on open.
        .onDisappear { if !committed { store.set(original, for: cid) } }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let img = UIImage(data: data) {
                    await MainActor.run {
                        store.savePhoto(img, for: cid)
                        preview(.photo)
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

    // Photos tile — opens the picker; once picked it shows the chosen photo and stays selectable.
    private var photosTile: some View {
        PhotosPicker(selection: $photoItem, matching: .images, photoLibrary: .shared()) {
            let isSel = selected == .photo
            tileFrame(isSelected: isSel) {
                Group {
                    if isSel, let img = store.photo(for: cid) {
                        Image(uiImage: img).resizable().scaledToFill()
                    } else {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color.secondary.opacity(0.12))
                            .overlay {
                                VStack(spacing: 6) {
                                    Image(systemName: "photo.on.rectangle.angled").font(.system(size: 21))
                                    Text("Photos").font(.system(size: 12, weight: .medium))
                                }
                                .foregroundStyle(.secondary)
                            }
                    }
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var applyButton: some View {
        Button {
            committed = true
            store.set(selected, for: cid)
            dismiss()
        } label: {
            Text("Apply Wallpaper").fontWeight(.semibold)
                .font(.system(size: 17))
                .foregroundStyle(selected == .none ? Color.primary : Color.white)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                // Liquid Glass tinted with the chosen wallpaper's colour (physics: the tint springs
                // when you switch swatches).
                .liquidGlass(Capsule(), interactive: true, tint: applyTint)
                .animation(.spring(response: 0.35, dampingFraction: 0.8), value: applyTint)
        }
        .padding(.horizontal, 20)
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

    // Live-preview a pick on the chat behind (store is observed) with a smooth spring.
    private func preview(_ w: ChatWallpaper) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { selected = w }
        store.set(w, for: cid)
    }
}
