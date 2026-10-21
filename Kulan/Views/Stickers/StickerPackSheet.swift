import SwiftUI
import UIKit

// ⛔ THE PACK SHEET — owner 2026-10-21, with two screenshots of the reference app. Opened from the
// sticker panel's "+N" tile on a pack that is not added yet. X on the left, the pack's title in the
// middle, every sticker of the pack in four columns (a tap sends it and closes the sheet), and one
// wide button at the foot: "Add to my stickers", or "Remove from my stickers" once it is added.
// Adding closes the sheet and the panel scrolls to the pack, now shown in full.

struct StickerPackSheet: View {
    let pack: StickerPack
    var onSend: (Sticker) -> Void
    var onClose: () -> Void
    var onAdd: () -> Void
    var onRemove: () -> Void

    /// The live pack (the admin panel may change it while the sheet is up), else the one we were given.
    private var shown: StickerPack { StickerStore.shared.packs.first { $0.id == pack.id } ?? pack }
    private var added: Bool { StickerStore.shared.isAdded(pack.id) }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Text(shown.title)
                    .font(.system(size: 17, weight: .semibold))
                    .lineLimit(1)
                    .padding(.horizontal, 64)
                HStack {
                    CloseXButton(diameter: 44) { onClose() }
                    Spacer()
                }
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 8)

            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
                    ForEach(shown.stickers) { s in
                        Button { onSend(s) } label: {
                            StickerPlayerRep(sticker: s, side: 80).aspectRatio(1, contentMode: .fit)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Send sticker \(s.emoji)")
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
            }

            footer
                .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 12)
        }
    }

    @ViewBuilder private var footer: some View {
        if added {
            Button { onRemove() } label: {
                Text("Remove from my stickers")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity).frame(height: 50)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            Button { onAdd() } label: {
                Text("Add to my stickers")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity).frame(height: 50)
                    .background(Capsule().fill(Color(hex: 0x2392FE)))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        }
    }
}

/// Puts the pack sheet up over whatever is on top (the sticker panel is an inputView, so it has no
/// view controller of its own to present from).
enum StickerPackSheetDoor {
    private final class Box { weak var vc: UIViewController? }

    /// `onSend` is the panel's own send path. `onAdded` runs once the sheet is gone after an add.
    @MainActor static func present(_ pack: StickerPack,
                                   onSend: @escaping (Sticker) -> Void,
                                   onAdded: @escaping (String) -> Void) {
        guard let top = WebLink.topViewController() else { return }
        let box = Box()
        let sheet = StickerPackSheet(
            pack: pack,
            onSend: { s in
                onSend(s)
                box.vc?.dismiss(animated: true)
            },
            onClose: { box.vc?.dismiss(animated: true) },
            onAdd: {
                StickerStore.shared.setAdded(pack.id, true)
                if let vc = box.vc {
                    vc.dismiss(animated: true) { onAdded(pack.id) }
                } else {
                    onAdded(pack.id)
                }
            },
            onRemove: {
                StickerStore.shared.setAdded(pack.id, false)
                box.vc?.dismiss(animated: true)
            })
        let host = UIHostingController(rootView: sheet)
        box.vc = host
        host.modalPresentationStyle = .pageSheet
        if let sp = host.sheetPresentationController {
            sp.detents = [.medium(), .large()]
            sp.prefersGrabberVisible = false
        }
        top.present(host, animated: true)
    }
}
