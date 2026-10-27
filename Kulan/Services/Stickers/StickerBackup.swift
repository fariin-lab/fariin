import Foundation
import FirebaseStorage

// ⛔ STICKERS I MADE BELONG TO THE ACCOUNT, NOT THE PHONE — owner 2026-10-27: "I made custom stickers,
// signed out, signed in again and all of them were gone. Never lose them; the only way to lose one is
// to delete it." They lived only on this phone, and sign-out wipes that copy on purpose (the next
// person on the phone must not see them). So every change is now mirrored to the account's own folder
// in Storage, `userStickers/{uid}/`: one PNG per sticker I made and `index.json`, the Favorites list
// (made and saved stickers, newest first). Signing in restores what this phone does not have.
// storage.rules: only the owner reads or writes that folder.
//
// Best effort: a failed upload leaves the sticker on this phone and is retried by the next change
// (the index is written whole every time).

enum StickerBackup {
    private static func folder(_ uid: String) -> StorageReference {
        Storage.storage().reference().child("userStickers").child(uid)
    }

    /// A sticker I made, uploaded under its own id.
    static func uploadMine(_ png: Data, id: String, uid: String) {
        let meta = StorageMetadata()
        meta.contentType = "image/png"
        folder(uid).child("\(id).png").putData(png, metadata: meta) { _, _ in }
    }

    static func deleteMine(id: String, uid: String) {
        folder(uid).child("\(id).png").delete { _ in }
    }

    /// The whole Favorites list, replacing the last one.
    static func writeIndex(_ favorites: [Sticker], uid: String) {
        guard let data = try? JSONEncoder().encode(favorites) else { return }
        let meta = StorageMetadata()
        meta.contentType = "application/json"
        folder(uid).child("index.json").putData(data, metadata: meta) { _, _ in }
    }

    /// The account's Favorites and the PNGs of the made ones this phone is missing (`have` says
    /// which it already holds). Empty when the account has no backup yet; nil when it cannot be read.
    static func restore(uid: String, have: @escaping (Sticker) -> Bool) async -> (list: [Sticker], pngs: [String: Data])? {
        let data: Data
        do {
            data = try await folder(uid).child("index.json").data(maxSize: 2 * 1024 * 1024)
        } catch {
            // No backup yet is an EMPTY one (the phone's list may start it). Any other failure (no
            // network) is unknown, and nothing may be written over a copy we could not read.
            if (error as NSError).code == StorageErrorCode.objectNotFound.rawValue { return ([], [:]) }
            return nil
        }
        guard let list = try? JSONDecoder().decode([Sticker].self, from: data) else { return nil }
        var pngs: [String: Data] = [:]
        for s in list where s.source == .mine && !have(s) {
            if let png = try? await folder(uid).child("\(s.stickerId).png").data(maxSize: 2 * 1024 * 1024) {
                pngs[s.stickerId] = png
            }
        }
        return (list, pngs)
    }
}
