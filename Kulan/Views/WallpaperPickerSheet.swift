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
    @State private var selectedColor: ChatColorSpec?   // live-preview bubble colour (not saved until Apply)
    @State private var committed = false          // Apply pressed → keep it; otherwise revert on close
    @State private var photoItem: PhotosPickerItem?
    @State private var showCustomColor = false    // "+" → Custom Color editor
    private var colorStore: ChatColorStore { .shared }
    // The wallpaper/colour in use when the sheet OPENED — must be @State: the live preview writes to the
    // observed store, which re-creates this struct, and a plain `let` re-captured the PREVIEWED value as
    // "original" (hasPendingChange went false → no Apply button, closes acted like auto-apply).
    @State private var original: ChatWallpaper
    @State private var originalColor: ChatColorSpec?

    init(cid: String) {
        self.cid = cid
        let cur = WallpaperStore.shared.wallpaper(for: cid)
        _selected = State(initialValue: cur)
        _original = State(initialValue: cur)
        let col = ChatColorStore.shared.color(for: cid)
        _selectedColor = State(initialValue: col)
        _originalColor = State(initialValue: col)
    }

    private var dark: Bool { scheme == .dark }
    // A pending change if EITHER the wallpaper or the bubble colour differs from what was in use on open.
    private var hasPendingChange: Bool {
        selected != original || selectedColor?.stored != originalColor?.stored
    }

    // Stable id per selection, for the auto-scroll on open.
    private func tileID(_ w: ChatWallpaper) -> String {
        switch w {
        case .none:            return "none"
        case .gradient(let g): return g
        case .photo:           return "photo"
        }
    }

    // The vivid colour of the current pick → the Apply button's Liquid Glass tint.
    // A photo has no representative colour, so it uses a fixed brand blue — Theme.accent is
    // white in dark mode, which made the Apply button a white capsule with invisible white text.
    private var applyTint: Color {
        switch selected {
        case .gradient(let id): return ChatWallpapers.gradient(id)?.tint ?? Color(hex: 0x3DA1FD)
        case .photo:            return Color(hex: 0x3DA1FD)
        case .none:             return selectedColor?.swatch ?? Color.secondary   // colour-only change → tint with it
        }
    }

    var body: some View {
        // Observe the store's version so picking a DIFFERENT photo re-renders the tile (the photo
        // caches are observation-ignored, and `selected` stays .photo, so without this the tile kept
        // showing the first photo). Keyed on the photo id below so the Image reloads too.
        let _ = store.version
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
                // Picking a photo appends its tile at the far right — scroll to whatever's selected
                // so the chosen photo (or gradient) always scrolls into view.
                .onChange(of: selected) { _, w in
                    withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(tileID(w), anchor: .center) }
                }
            }
            chatColorSection
            bottomBar
        }
        .padding(.top, 16).padding(.bottom, 10)
        .presentationDetents([.height(408)])
        .presentationDragIndicator(.visible)
        .sheet(isPresented: $showCustomColor) {
            CustomColorView(cid: cid) { spec in chooseColor(spec) }   // live preview, not saved until Apply
        }
        // Selecting a wallpaper OR a colour LIVE-PREVIEWS it on the chat behind, but nothing is SAVED
        // until Apply. Closing without Apply reverts both to the originals.
        .onDisappear {
            if !committed {
                store.set(original, for: cid)
                colorStore.set(originalColor, for: cid)
            }
        }
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

    // Something non-default is picked / in use → offer Reset.
    private var hasCustom: Bool { selected != .none || selectedColor != nil }

    private var header: some View {
        ZStack {
            Text("Chat Wallpaper").font(.headline)
            HStack {
                // 48pt Liquid Glass X, top-leading, vertically centred with the title.
                Button { dismiss() } label: {   // X = cancel (onDisappear reverts)
                    Image(systemName: "xmark").font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 48, height: 48)
                        .liquidGlass(Circle(), interactive: true)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                Spacer()
                // Reset back to the default (no wallpaper + default chat color) — only when a custom
                // wallpaper or chat color is set.
                if hasCustom {
                    Button { resetToDefault() } label: {
                        Text("Reset").font(.system(size: 15, weight: .semibold)).foregroundStyle(.primary)
                            .frame(height: 40).padding(.horizontal, 16)
                            .liquidGlass(Capsule(), interactive: true)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 16)
    }

    private func resetToDefault() {
        committed = true                       // persist the reset (don't let onDisappear revert it)
        store.set(.none, for: cid)
        colorStore.set(nil, for: cid)
        selected = .none; selectedColor = nil
        original = .none; originalColor = nil
        dismiss()
    }

    // Contextual bottom button: a pending wallpaper/colour change → "Apply Wallpaper" (commits both);
    // otherwise → "Choose Wallpaper from Photos".
    @ViewBuilder private var bottomBar: some View {
        Group {
            if hasPendingChange {
                Button {
                    committed = true                      // keep the live-previewed wallpaper + colour
                    store.set(selected, for: cid)
                    colorStore.set(selectedColor, for: cid)
                    dismiss()
                } label: {
                    Text("Apply Wallpaper").fontWeight(.semibold).font(.system(size: 17))
                        .foregroundStyle(selected == .none && selectedColor == nil ? Color.primary : Color.white)
                        .frame(maxWidth: .infinity).frame(height: 50)
                        .liquidGlass(Capsule(), interactive: true, tint: applyTint)
                        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: applyTint)
                }
                .transition(.opacity)
            } else {
                PhotosPicker(selection: $photoItem, matching: .images, photoLibrary: .shared()) {
                    HStack(spacing: 8) {
                        Image(systemName: "photo.on.rectangle.angled")
                        Text("Choose Wallpaper from Photos").fontWeight(.semibold)
                    }
                    .font(.system(size: 16)).foregroundStyle(.primary)
                    .frame(maxWidth: .infinity).frame(height: 50)
                    .liquidGlass(Capsule(), interactive: true)
                }
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
    }

    // Chat Color row: the app-default swatch + presets + a "+" to open the Custom Color editor. Picking
    // LIVE-PREVIEWS on the chat behind but is saved only on Apply (same as wallpaper).
    private var chatColorSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Chat Color").font(.subheadline.weight(.semibold)).padding(.horizontal, 20)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    defaultColorCircle
                    ForEach(ChatColors.presets) { colorCircle($0) }
                    addColorButton
                }
                .padding(.horizontal, 20).padding(.vertical, 2)
            }
        }
    }

    private var defaultColorCircle: some View {
        let isDefault = selectedColor == nil
        return Button { chooseColor(nil) } label: {
            // The default swatch shows the adaptive systemBlue (its light/dark value), white glyph.
            Circle().fill(Theme.defaultBubble(dark)).frame(width: 52, height: 52)
                .overlay(Image(systemName: "message.fill").font(.system(size: 18)).foregroundStyle(.white))
                .overlay(Circle().strokeBorder(isDefault ? Color.primary : .clear, lineWidth: 3))
        }.buttonStyle(.plain)
    }

    private func colorCircle(_ p: ChatColorSpec) -> some View {
        let isSel = selectedColor?.stored == p.stored
        return Button { chooseColor(p) } label: {
            Circle().fill(p.fill).frame(width: 52, height: 52)
                .overlay(Circle().strokeBorder(isSel ? Color.primary : .clear, lineWidth: 3))
        }.buttonStyle(.plain)
    }

    private var addColorButton: some View {
        Button { showCustomColor = true } label: {
            Image(systemName: "plus").font(.system(size: 20, weight: .medium)).foregroundStyle(.secondary)
                .frame(width: 52, height: 52).background(Color(.systemGray5), in: Circle())
        }.buttonStyle(.plain)
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

    // Select + LIVE-PREVIEW on the chat behind (store is observed). Not persisted until Apply — the
    // onDisappear revert restores the original if the user closes without applying.
    private func preview(_ w: ChatWallpaper) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { selected = w }
        store.set(w, for: cid)   // live preview only — Apply commits it, close reverts it
    }

    // Live-preview a bubble colour (or nil = default). Saved only on Apply.
    private func chooseColor(_ spec: ChatColorSpec?) {
        selectedColor = spec
        colorStore.set(spec, for: cid)
    }
}
