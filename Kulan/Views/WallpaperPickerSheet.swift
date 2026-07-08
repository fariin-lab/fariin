import SwiftUI
import PhotosUI

// Telegram-style "Select Theme" sheet, our own look: a floating Liquid Glass card with a row of
// gradient wallpaper swatches + "No wallpaper" + a "Choose Wallpaper from Photos" button. Tapping
// a swatch applies it LIVE to the chat behind (the store is @Observable), so you preview instantly.
// Local per-chat only — nothing is uploaded or shared.
struct WallpaperPickerSheet: View {
    let cid: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    private var store: WallpaperStore { .shared }

    @State private var selected: ChatWallpaper
    @State private var photoItem: PhotosPickerItem?

    init(cid: String) {
        self.cid = cid
        _selected = State(initialValue: WallpaperStore.shared.wallpaper(for: cid))
    }

    var body: some View {
        VStack(spacing: 18) {
            header
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    noneTile
                    ForEach(ChatWallpapers.all) { g in gradientTile(g) }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 2)
            }
            photosButton
        }
        .padding(.vertical, 22)
        .frame(maxWidth: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 34, style: .continuous)
                .fill(Color.clear)
                .liquidGlass(RoundedRectangle(cornerRadius: 34, style: .continuous))
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        .frame(maxHeight: .infinity, alignment: .bottom)
        .presentationBackground(.clear)   // the glass card floats; the chat shows above it
        .presentationDetents([.height(320)])
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let img = UIImage(data: data) {
                    await MainActor.run {
                        store.savePhoto(img, for: cid)
                        apply(.photo)
                    }
                }
            }
        }
    }

    private var header: some View {
        ZStack {
            Text("Chat Wallpaper").font(.headline)
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.primary)
                        .frame(width: 34, height: 34)
                        .liquidGlass(Circle(), interactive: true)
                }
                Spacer()
            }
        }
        .padding(.horizontal, 20)
    }

    // "No wallpaper" swatch — clears back to the default app background.
    private var noneTile: some View {
        tile(isSelected: selected == .none) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Theme.bg(scheme == .dark))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(.secondary.opacity(0.3), lineWidth: 1))
                .overlay {
                    VStack(spacing: 6) {
                        Image(systemName: "slash.circle").font(.system(size: 22, weight: .regular))
                        Text("None").font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(.secondary)
                }
        } action: { apply(.none) }
    }

    private func gradientTile(_ g: WallpaperGradient) -> some View {
        tile(isSelected: selected == .gradient(g.id)) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(LinearGradient(colors: g.colors(scheme == .dark),
                                     startPoint: .top, endPoint: .bottom))
        } action: { apply(.gradient(g.id)) }
    }

    private var photosButton: some View {
        PhotosPicker(selection: $photoItem, matching: .images, photoLibrary: .shared()) {
            HStack(spacing: 8) {
                Image(systemName: "photo.on.rectangle.angled")
                Text("Choose Wallpaper from Photos").fontWeight(.semibold)
            }
            .font(.system(size: 16))
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .liquidGlass(Capsule(), interactive: true)
        }
        .padding(.horizontal, 20)
    }

    // Common swatch frame + selection ring.
    private func tile<Content: View>(isSelected: Bool,
                                     @ViewBuilder _ content: () -> Content,
                                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            content()
                .frame(width: 76, height: 108)
                .overlay {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Theme.accent(scheme == .dark), lineWidth: 3)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 20))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Theme.accent(scheme == .dark))
                            .padding(6)
                    }
                }
        }
        .buttonStyle(.plain)
    }

    private func apply(_ w: ChatWallpaper) {
        withAnimation(.easeOut(duration: 0.15)) { selected = w }
        store.set(w, for: cid)   // live-updates the chat behind (observed store)
    }
}
