import Foundation

// Device-side store for chat videos (the "mailman" model): our storage only
// carries the encrypted video until it's delivered — each phone keeps its OWN decrypted
// copy here, permanently. Sender saves at send time; recipient saves on first download,
// then deletes the server object. Files live in Application Support (not Caches, so iOS
// never purges them behind our back), protected at rest, excluded from iCloud backup.
enum VideoCache {
    private static var dir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let d = base.appendingPathComponent("chat-videos", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true,
                                                 attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        var mutable = d; try? mutable.setResourceValues(values)
        return d
    }()

    private static func fileURL(_ messageId: String) -> URL {
        // Message ids are Firestore doc ids (alphanumeric) — safe as file names.
        dir.appendingPathComponent("\(messageId).mp4")
    }

    /// The locally-stored decrypted video for this message, if this device has it.
    static func url(for messageId: String) -> URL? {
        let u = fileURL(messageId)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    static func data(for messageId: String) -> Data? {
        url(for: messageId).flatMap { try? Data(contentsOf: $0) }
    }

    /// Persist a decrypted video on this device (atomic + protected). Returns whether the file is
    /// really there afterwards: the write swallows a full disk, and under the mailman model the
    /// sender's copy is the only one left once the recipient picks the server object up, so the
    /// send paths must not carry on when this is false.
    @discardableResult
    static func store(_ data: Data, for messageId: String) -> Bool {
        let u = fileURL(messageId)
        try? data.write(to: u, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return url(for: messageId) != nil
    }

    /// Thrown by a send whose own copy could not be kept on this phone.
    struct NoRoomError: LocalizedError {
        var errorDescription: String? {
            "There isn't enough storage on this phone to keep a copy of this video. Free up some space and try again."
        }
    }

    static func remove(_ messageId: String) {
        try? FileManager.default.removeItem(at: fileURL(messageId))
    }

    /// Total bytes on disk (Settings "storage used").
    static func diskBytes() -> Int {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return items.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
    }

    /// Sign-out/delete: these files are DECRYPTED chat videos — wipe with the account.
    static func removeAll() {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for f in items { try? fm.removeItem(at: f) }
    }
}
