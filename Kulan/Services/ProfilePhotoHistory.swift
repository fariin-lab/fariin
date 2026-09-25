import UIKit

/// The profile photos this account has used, newest first, kept on this phone only.
///
/// ⛔ RECENTS ON THE EDIT PHOTO PAGE MEANS "PHOTOS YOU USED BEFORE" — owner, 2026-09-25, with the
/// section ringed: it was showing the newest pictures in the camera roll (screenshots, mostly),
/// which is not what the word means on that page. It means the pictures you have had as your
/// profile photo, so you can go back to one.
///
/// Local, not on the server: the past photos are only ever offered back to the same person on the
/// same phone, so there is no reason to keep old pictures of somebody in the cloud after they
/// replaced them. One folder per account, and `SessionWipe` removes all of it on sign-out, so the
/// next person to sign in on this phone never sees the last one's pictures.
enum ProfilePhotoHistory {
    /// Ten, the count the section has held since 2026-09-11 ("make it only 10").
    static let limit = 10

    private static var root: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("ProfilePhotoHistory", isDirectory: true)
    }

    private static func folder(_ uid: String) -> URL? {
        root?.appendingPathComponent(uid, isDirectory: true)
    }

    /// Records a photo that has just become the profile photo. Called after the save has landed, so
    /// a failed upload never enters the history.
    static func record(_ image: UIImage, uid: String) {
        guard let dir = folder(uid),
              let data = ProfileStore.squareJPEG(image, maxSide: 1280, quality: 0.85) else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = String(format: "%.0f.jpg", Date().timeIntervalSince1970 * 1000)
        try? data.write(to: dir.appendingPathComponent(name), options: [.atomic, .completeFileProtection])
        // Oldest past the limit go.
        for old in files(dir).dropFirst(limit) { try? fm.removeItem(at: old) }
    }

    /// One past photo: a small thumbnail for the grid, and where the full picture lives. The full
    /// one is only read when it is tapped, so ten of them never sit in memory at 1280px.
    struct Entry: Identifiable {
        let file: URL
        let thumb: UIImage
        var id: URL { file }
        var fullImage: UIImage? { UIImage(contentsOfFile: file.path) }
    }

    /// Newest first.
    static func entries(uid: String) -> [Entry] {
        guard let dir = folder(uid) else { return [] }
        return files(dir).prefix(limit).compactMap { url in
            guard let img = UIImage(contentsOfFile: url.path),
                  let thumb = img.preparingThumbnail(of: CGSize(width: 240, height: 240)) else { return nil }
            return Entry(file: url, thumb: thumb)
        }
    }

    /// Everything, every account. Sign-out calls this.
    static func wipe() {
        guard let root else { return }
        try? FileManager.default.removeItem(at: root)
    }

    /// Newest first, by the millisecond timestamp in the name.
    private static func files(_ dir: URL) -> [URL] {
        let all = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return all.filter { $0.pathExtension == "jpg" }
            .sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending }
    }
}
