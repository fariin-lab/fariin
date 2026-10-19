import SwiftUI
import UIKit

// ⛔ TAP A FARIIN STICKER IN A CHAT — owner 2026-10-17, with the reference app's sheet: the sticker big,
// "<pack> · Fariin", Add to Favorites, View sticker pack.
//
// ⛔ A STICKER SOMEBODY MADE OPENS IT TOO — owner 2026-10-19: its own PNG big, no pack line, no
// pack button, two rows only: Add to / Remove from Favorites, and Edit Sticker (the Create Sticker
// Save page with this picture as the photo, so a new sticker can be made from it).

/// What a tapped sticker opens: the sticker, and the message it came in (a custom sticker's
/// picture and its Favorites copy both come from the message).
struct StickerSheetItem: Identifiable {
    let sticker: Sticker
    let message: Message
    var id: String { message.rowId }
}

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
    /// The message the sticker came in, and its chat (a custom sticker's picture lives there).
    let message: Message
    let cid: String
    /// Send a sticker from the pack into the chat this sheet was opened from.
    var onSend: (Sticker) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var showPack = false
    @State private var favorite = false
    @State private var minePicture: UIImage?    // a custom sticker's PNG, once it is read
    @State private var working = false          // a Favorites change or the Edit read is running

    private var pack: StickerPack? { StickerStore.shared.packs.first { $0.id == sticker.packId } }
    private var isMine: Bool { sticker.source == .mine }

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
                bigSticker
                    .frame(width: 200, height: 200)
                    .padding(.top, 4)
                if !isMine {
                    Text("\(pack?.title ?? "Stickers") · Fariin")
                        .font(.system(size: 15)).foregroundStyle(.secondary)
                        .padding(.top, 14)
                }
                VStack(spacing: 0) {
                    row(favorite ? "Remove from Favorites" : "Add to Favorites", favorite ? "star.slash" : "star") {
                        toggleFavorite()
                    }
                    // A custom sticker has the Favorites row only (owner 2026-10-19: Edit Sticker removed).
                    if !isMine, pack != nil {
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
        .task {
            guard isMine, minePicture == nil, let png = await StickerSend.minePNG(message, cid: cid) else { return }
            minePicture = UIImage(data: png)
        }
        .presentationDetents(showPack ? [.large] : [.height(isMine ? 390 : 470)])
        .presentationDragIndicator(.hidden)
    }

    /// A built-in sticker plays; a custom one is its still PNG, the same picture its chat row draws.
    @ViewBuilder private var bigSticker: some View {
        if isMine {
            if let minePicture {
                Image(uiImage: minePicture).resizable().scaledToFit()
            } else {
                ProgressView()
            }
        } else {
            StickerPlayerRep(sticker: sticker, side: 200)
        }
    }

    /// The chat menu's own Save/Remove (a custom sticker is kept as its PNG under its own id), and
    /// the label read back from the store afterwards, so it always says what is really there.
    private func toggleFavorite() {
        guard !working else { return }
        working = true
        Task { @MainActor in
            _ = await StickerSend.toggleFavorite(message, cid: cid)
            favorite = StickerStore.shared.isFavorite(sticker)
            working = false
            // Saved or removed, the sheet's job is done (owner 2026-10-19).
            dismiss()
        }
    }

    /// The sheet goes first, then the Save page comes up with this picture as its photo.
    private func editSticker() {
        guard !working else { return }
        working = true
        Task { @MainActor in
            var image = minePicture
            if image == nil, let png = await StickerSend.minePNG(message, cid: cid) { image = UIImage(data: png) }
            working = false
            guard let image else { return }
            dismiss()
            // After the sheet's own slide, so the page is raised from the chat, not from the sheet.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { StickerCreatorDoor.edit(image: image) }
        }
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
