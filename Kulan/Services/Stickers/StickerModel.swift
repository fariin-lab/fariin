import Foundation

// ⛔ THE CHAT STICKER KEYBOARD — owner 2026-10-17 ("go build"). Shared types between the keyboard
// (StickerStore, StickerKeyboardView, StickerPlayer) and the message side (sending, the sticker row,
// StickerCreator). Art: Google Noto Animated Emoji, CC BY 4.0 (credit in Settings > About).

/// One sticker. A bundled one is drawn by every phone from its own copy of the pack, so a message
/// carries only `packId` + `stickerId`; a sticker I made is a transparent PNG that travels through
/// the encrypted media path like a photo.
struct Sticker: Codable, Hashable, Identifiable {
    enum Source: String, Codable { case bundled, mine }

    let source: Source
    let packId: String          // bundled pack id, or "mine"
    let stickerId: String       // file stem inside the pack, or a UUID for mine
    let emoji: String           // the emoji it stands for (search, reply label, push text)
    let animated: Bool

    var id: String { "\(packId)/\(stickerId)" }
}

/// A pack as the keyboard lists it.
struct StickerPack: Identifiable, Hashable {
    let id: String
    let title: String
    let stickers: [Sticker]
}

/// Recently used, as both references keep it: newest first, no duplicates, capped.
enum StickerLimits {
    static let recents = 20
}
