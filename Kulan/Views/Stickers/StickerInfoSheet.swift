import SwiftUI
import UIKit

// ⛔ TAP A FARIIN STICKER IN A CHAT — owner 2026-10-17, with the reference app's sheet: the sticker big,
// "<pack> · Fariin", Add to Favorites, View sticker pack. Only for the app's own packs; a sticker
// somebody made keeps its long-press menu.

/// The animated sticker as a SwiftUI view (Core Animation underneath; never a SwiftUI repeat).
struct StickerPlayerRep: UIViewRepresentable {
    let sticker: Sticker
    var side: CGFloat
    func makeUIView(context: Context) -> StickerPlayerView { StickerPlayerView() }
    func updateUIView(_ v: StickerPlayerView, context: Context) {
        v.setSticker(url: StickerStore.shared.fileURL(for: sticker), pixelSize: Int(side * 2))
        v.play()
    }
}

struct StickerInfoSheet: View {
    let sticker: Sticker
    /// Send a sticker from the pack into the chat this sheet was opened from.
    var onSend: (Sticker) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var showPack = false
    @State private var favorite = false

    private var pack: StickerPack? { StickerStore.shared.packs.first { $0.id == sticker.packId } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                CloseXButton(diameter: 44) { dismiss() }
            }
            .padding(.horizontal, 16).padding(.top, 14)

            if showPack, let pack {
                packGrid(pack)
            } else {
                StickerPlayerRep(sticker: sticker, side: 200)
                    .frame(width: 200, height: 200)
                    .padding(.top, 4)
                Text("\(pack?.title ?? "Stickers") · Fariin")
                    .font(.system(size: 15)).foregroundStyle(.secondary)
                    .padding(.top, 14)
                VStack(spacing: 0) {
                    row(favorite ? "Remove from Favorites" : "Add to Favorites", favorite ? "star.slash" : "star") {
                        let store = StickerStore.shared
                        if favorite { store.removeFavorites([sticker.id]) } else { store.addFavorite(sticker) }
                        favorite.toggle()
                    }
                    if pack != nil {
                        Divider().padding(.leading, 56)
                        row("View sticker pack", "square.grid.2x2") { withAnimation(.easeInOut(duration: 0.25)) { showPack = true } }
                    }
                }
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .padding(.horizontal, 16).padding(.top, 18)
                Spacer(minLength: 12)
            }
        }
        .onAppear { favorite = StickerStore.shared.isFavorite(sticker) }
        .presentationDetents(showPack ? [.large] : [.height(470)])
        .presentationDragIndicator(.hidden)
    }

    private func row(_ title: String, _ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: icon).font(.system(size: 19)).frame(width: 24)
                Text(title).font(.system(size: 17))
                Spacer()
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 18).frame(height: 54)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func packGrid(_ pack: StickerPack) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(pack.title).font(.system(size: 20, weight: .semibold)).padding(.horizontal, 20)
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
                    ForEach(pack.stickers) { s in
                        Button { onSend(s); dismiss() } label: {
                            StickerPlayerRep(sticker: s, side: 80).aspectRatio(1, contentMode: .fit)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Send sticker \(s.emoji)")
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }
}
