import SwiftUI
import PhotosUI
import UIKit

// "Select Theme" sheet, our own look. A native sheet with a row of gradient swatches
// + None (+ a Photos tile when a custom photo is the pick). Picking a swatch LIVE-previews it on the
// chat behind. The bottom button is contextual: "Choose Wallpaper from Photos" when nothing new is
// selected (settled), and morphs to "Apply Wallpaper" — tinted with the pick's own colour — the
// moment you choose a DIFFERENT wallpaper. On open it auto-scrolls to the wallpaper you're using so
// you can see it selected. Local per-chat only. Closing without applying reverts.
struct WallpaperPickerSheet: View {
    let cid: String
    // Settings > Appearance entry: cid is the DEFAULT slot itself and the one primary button
    // is "Apply For All Chats" (sets the default + clears every per-chat pick). From a chat,
    // the primary Apply stays per-chat and a smaller all-chats button rides under it.
    var globalOnly: Bool = false
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

    /// Did this chat have its OWN wallpaper when the sheet opened, or was it inheriting the
    /// all-chats default? `wallpaper(for:)` answers with the resolved value either way, so cancelling
    /// used to write that resolved value back as a per-chat pick — pinning today's default onto a
    /// chat that had no override, and losing the difference between "none set" and "set to this"
    /// (audit). Recorded here so the cancel path can restore the real state.
    private let hadOwnWallpaper: Bool
    init(cid: String, globalOnly: Bool = false) {
        self.cid = cid
        self.globalOnly = globalOnly
        self.hadOwnWallpaper = WallpaperStore.shared.hasOverride(for: cid)
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
        case .photo(let id):   return "p-\(id)"
        case .color(let hex):  return "c-\(hex)"
        case .preset(let id):  return "b-\(id)"
        }
    }

    // The vivid colour of the current pick → the Apply button's Liquid Glass tint.
    // A photo has no representative colour, so it uses a fixed brand blue — Theme.accent is
    // white in dark mode, which made the Apply button a white capsule with invisible white text.
    private var applyTint: Color {
        switch selected {
        case .gradient(let id): return ChatWallpapers.gradient(id)?.tint ?? Color(hex: 0x3DA1FD)
        case .photo, .preset:   return Color(hex: 0x3DA1FD)
        case .color(let hex):   return Color(hex: hex)
        case .none:             return selectedColor?.swatch ?? Color.secondary   // colour-only change → tint with it
        }
    }

    var body: some View {
        // Observe the store's version so picking a DIFFERENT photo re-renders the tile (the photo
        // caches are observation-ignored, and `selected` stays .photo, so without this the tile kept
        // showing the first photo). Keyed on the photo id below so the Image reloads too.
        let _ = store.version
        VStack(spacing: 16) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        noneTile.id("none")
                        ForEach(ChatWallpapers.all) { g in gradientTile(g).id(g.id) }   // built-ins: never deletable
                        // The user's WALLPAPER LIBRARY: every gallery photo ever imported, newest first,
                        // always shown (full history, not just the current one). Long-press → Delete.
                        ForEach(store.libraryIds, id: \.self) { pid in
                            libraryTile(pid).id("p-\(pid)")
                        }
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
        }
        .frame(maxHeight: .infinity, alignment: .top)
        // ⛔ THE HEADER IS A TOP BAR FOR THE SAME REASON THE BUTTONS ARE A BOTTOM ONE — owner,
        // 2026-09-02, ringing the ✕ and Reset and sending the rule a fourth time: content inside the
        // safe area is APP CONTENT; edge-attached chrome is a SYSTEM BAR. The ✕ and Reset are chrome
        // — they act on the sheet, not on anything in it — and they were the first row of a VStack,
        // which is app content wearing a system control's clothes.
        //
        // ⚠️ AND IT IS WHY THE GRABBER GAP STOPS BEING A NUMBER. The 8 that was here was clearing the
        // system's own drag indicator by hand. `safeAreaBar` places the bar under it.
        .safeAreaBar(edge: .top) { header }
        // ⛔ THE BUTTON IS SYSTEM CHROME, SO IT SITS WHERE SYSTEM CHROME SITS — owner,
        // 2026-08-24, third time he has sent the same rule: "use system chrome / edge-attached UI,
        // system-positioned", with the space under Apply Wallpaper circled.
        //
        // ⚠️ AND HIS "29" WAS NEVER AN ARBITRARY NUMBER — I read it as one and got it wrong twice on
        // the attach bar. This app already states the rule, in the composer: a system-positioned
        // control rests at the safe-area line LESS a small dip INTO the indicator band, which is how
        // the system's own bars sit. That dip is `composerRestDip`, 5. On his phone the band is 34,
        // so the resting gap is 29 — his number, derived rather than picked, and device-correct
        // everywhere instead of on one handset.
        //
        // What was here was 12 ON TOP OF the full band, about 46, which is the "still too big" he
        // reported. The old note was right that the indicator must be accounted for and wrong about
        // clearing all of it and then some.
        //
        // ⛔ AND THE ONLY WAY TO SIT WHERE SYSTEM CHROME SITS IS TO BE SYSTEM CHROME — owner,
        // 2026-09-02, sending the rule itself this time: content inside the safe area is APP
        // CONTENT; an edge-attached control is a SYSTEM BAR, system-positioned. Hand-padding the
        // bottom of a VStack is the first thing, however carefully the number is derived, and a
        // derived number was still a number this file was choosing.
        //
        // `safeAreaBar` is the second thing. It hands the buttons to the system as an edge-attached
        // bar: the system decides the rest above the indicator, and the rest of the sheet is inset
        // to clear it. That is the same treatment the tab bar and the composer get, so the gap under
        // Apply Wallpaper now matches them by construction instead of by arithmetic.
        //
        // ⚠️ THE DETENT STILL MEASURES FROM THE BOTTOM OF THE SCREEN and still has to cover the bar,
        // which is why the band term stays in the height below even though nothing pads by it now.
        .safeAreaBar(edge: .bottom) { bottomBar }
        // ⛔ THE HEIGHT CAME DOWN 48 — owner, 2026-09-02, ringing the dead band above Apply
        // Wallpaper. Moving both bars out of the VStack did not shrink the sheet with them: a fixed
        // detent is a number, it does not follow its content, so the space the two rows used to
        // occupy inside the stack stayed reserved and showed up as the gap he circled.
        //
        // Recomputed rather than nudged. The old 372 was 8 (grabber pad) + 48 (header) + three 16pt
        // gaps + 54 (button) + 29 (hand-padded bottom) + 185 of strip and colour rows. What is left
        // in the stack is those 185 plus their one 16pt gap; the header and the button are now bars
        // the system measures, and the indicator band comes back as the sheet's own safe area rather
        // than as `bottomChromeGap`, which is why this term is the FULL inset and not the dipped one.
        //
        // ⚠️ 44 apart, not 48: the secondary "Apply For All Chats" row is 34 and its gap is 6, plus
        // the 4 the taller button block adds. Both bases move by the same amount so that stays true.
        // ⚠️ +26 ON BOTH, for the header's new 14 above and 12 below. A fixed detent does not follow
        // its content, so padding the bar without paying for it here would just take the room out of
        // the wallpaper strip — which is the half of his report about the tiles being cut off.
        .presentationDetents([.height((hasPendingChange && !globalOnly ? 389 : 345) + Self.bottomInset)])
        .presentationDragIndicator(.visible)
        .sheet(isPresented: $showCustomColor) {
            CustomColorView(cid: cid) { spec in
                colorStore.addCustom(spec)   // save into the reusable custom library (deduped)
                chooseColor(spec)            // live preview, ACTIVE colour not saved until Apply
            }
        }
        // Selecting a wallpaper OR a colour LIVE-PREVIEWS it on the chat behind, but nothing is SAVED
        // until Apply. Closing without Apply reverts both to the originals.
        .onDisappear {
            if !committed {
                // Restore the REAL previous state: a chat that was inheriting the default goes back
                // to inheriting it, instead of gaining a per-chat copy of it (see hadOwnWallpaper).
                if hadOwnWallpaper { store.set(original, for: cid) }
                else { store.clearOverride(for: cid) }
                colorStore.set(originalColor, for: cid)
            }
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let img = UIImage(data: data) {
                    await MainActor.run {
                        // Import into the persistent LIBRARY (dedup by content) and select the tile.
                        // The new id differs from `original`, so hasPendingChange is true and the
                        // Apply button ALWAYS appears — including when replacing an active photo
                        // wallpaper with another photo (the old identity-less .photo compared equal
                        // to itself, which is exactly why Apply used to vanish).
                        if let id = store.addToLibrary(img) { preview(.photo(id)) }
                        photoItem = nil   // reset so re-picking (even the same item) fires again
                    }
                }
            }
        }
    }

    // A user-library photo tile: tap to live-preview + select; long-press → native Delete menu.
    // Only library photos are deletable — built-in gradients have no menu at all.
    private func libraryTile(_ pid: String) -> some View {
        tile(isSelected: selected == .photo(pid)) {
            Group {
                if let img = store.libraryImage(pid) {
                    Image(uiImage: img).resizable().scaledToFill()
                } else {
                    RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.secondary.opacity(0.12))
                }
            }
        } action: { preview(.photo(pid)) }
        .contextMenu {
            Button(role: .destructive) { deleteLibraryPhoto(pid) } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    // Remove a photo from the library. Only the library entry is deleted — if it was the live
    // selection (or the active wallpaper), fall back cleanly so no chat points at a missing file.
    private func deleteLibraryPhoto(_ pid: String) {
        if original == .photo(pid) {
            original = .none
            store.set(.none, for: cid)     // active wallpaper used this photo → reset the ACTIVE only
        }
        if selected == .photo(pid) {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { selected = original }
            store.set(original, for: cid)  // drop the live preview of the deleted photo
        }
        store.deleteFromLibrary(pid)       // history entry + file removed; other photos untouched
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
                            .frame(height: 48).padding(.horizontal, 18)   // 48pt — matches the X (user spec)
                            .liquidGlass(Capsule(), interactive: true)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 16)
        // ⛔ THE BAR NEEDS ITS OWN ROOM — owner, 2026-09-02: "the chat wallpaper sheet header looks
        // broken, the buttons are touching the top edge and the wallpapers below".
        //
        // ⚠️ I ASSUMED `safeAreaBar` WOULD CLEAR THE GRABBER AND IT DOES NOT. Its own note said so
        // in as many words ("the grabber gap stops being a number, safeAreaBar places the bar under
        // it") and that was a guess about a modifier I could not run. The bar is placed at the
        // sheet's edge and its content is exactly its content, so a 48pt button drawn there sits on
        // the sheet's top corner with the drag indicator over it, and its bottom edge is the
        // wallpaper strip's top edge.
        //
        // 14 above clears the indicator; 12 below is the gap the strip should have had all along.
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    private func resetToDefault() {
        committed = true                       // persist the reset (don't let onDisappear revert it)
        if globalOnly {
            // Global reset: plain app look everywhere (default cleared + all per-chat picks).
            store.applyToAllChats(.none)
            colorStore.applyToAllChats(nil)
        } else {
            // Per-chat reset: this chat goes back to the PLAIN default look. Clearing the override
            // instead made Reset do nothing whenever an "Apply For All Chats" wallpaper was set —
            // the chat simply re-inherited it. An explicit per-chat "none" wins over the default.
            store.set(.none, for: cid)
            colorStore.resetToAppDefault(for: cid)
        }
        selected = .none; selectedColor = nil
        original = .none; originalColor = nil
        dismiss()
    }

    private func applyForAllChats() {
        committed = true
        store.applyToAllChats(selected)
        colorStore.applyToAllChats(selectedColor)
        dismiss()
    }

    // Contextual bottom button: a pending wallpaper/colour change → "Apply Wallpaper" (commits both);
    // otherwise → "Choose Wallpaper from Photos".
    /// The home indicator's strip, read from the window. A sheet's own safe area does not reach a
    /// fixed-height detent's arithmetic, which is what has to know about it here.
    /// ⛔ NOTHING USES THIS ANY MORE and it is kept only as the record of a wrong turn. It computed
    /// where a system-positioned control should rest — the indicator's band less the 5pt dip the
    /// system's own bars take into it — so this file could pad by that number itself. The whole
    /// point of `safeAreaBar` is that the number is not ours to compute; the system rests its own
    /// bar and the sheet's safe area accounts for the band. Reviving this would be re-introducing
    /// the hand-padding it took three of his reports to remove.
    static var bottomChromeGap: CGFloat { max(0, bottomInset - 5) }

    /// The indicator band, read from the window. A sheet's own safe area does not reach a
    /// fixed-height detent's arithmetic, which is what still has to know about it.
    static var bottomInset: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow?.safeAreaInsets.bottom }
            .first ?? 0
    }

    @ViewBuilder private var bottomBar: some View {
        Group {
            if hasPendingChange {
                VStack(spacing: 6) {
                    Button {
                        if globalOnly { applyForAllChats(); return }
                        committed = true                  // keep the live-previewed wallpaper + colour
                        store.set(selected, for: cid)
                        colorStore.set(selectedColor, for: cid)
                        dismiss()
                    } label: {
                        Text(globalOnly ? "Apply For All Chats" : "Apply Wallpaper")
                            .fontWeight(.semibold).font(.system(size: 17))
                            .foregroundStyle(selected == .none && selectedColor == nil ? Color.primary : Color.white)
                            .frame(maxWidth: .infinity).frame(height: 50)
                            .liquidGlass(Capsule(), interactive: true, tint: applyTint)
                            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: applyTint)
                    }
                    if !globalOnly {
                        Button { applyForAllChats() } label: {
                            Text("Apply For All Chats").font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity).frame(height: 34)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
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
                    // The user's CUSTOM color library: every colour ever built in the Custom Color
                    // editor, saved permanently and reusable. Long-press → Delete (presets never are).
                    ForEach(colorStore.customColors) { spec in
                        colorCircle(spec)
                            .contextMenu {
                                Button(role: .destructive) {
                                    if selectedColor?.stored == spec.stored { chooseColor(nil) }
                                    colorStore.removeCustom(spec)
                                } label: { Label("Delete", systemImage: "trash") }
                            }
                    }
                    addColorButton
                }
                .padding(.horizontal, 20).padding(.vertical, 2)
            }
        }
    }

    private var defaultColorCircle: some View {
        let isDefault = selectedColor == nil
        // "Default" = follow the all-chats colour when one is set, else the app blue —
        // the swatch shows what following the default actually LOOKS like.
        let globalSpec = ChatColorSpec(stored: UserDefaults.standard.string(forKey: ChatColorStore.defaultKey))
        return Button { chooseColor(nil) } label: {
            Circle().fill(globalSpec.map { AnyShapeStyle($0.fill) } ?? AnyShapeStyle(Theme.defaultBubble(dark)))
                .frame(width: 52, height: 52)
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
            // Shows the theme's real image (falls back to its gradient), clipped to the tile.
            GradientWallpaperView(g: g, dark: dark)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        } action: { preview(.gradient(g.id)) }
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
