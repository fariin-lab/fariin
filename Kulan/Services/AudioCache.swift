import Foundation

// Device-side store for decrypted voice notes — the audio twin of VideoCache (the standard attachment
// store model: download + decrypt ONCE, keep the plaintext on-device forever, replay from the local
// file). Files live in Application Support (never purged by iOS, unlike tmp/ or Caches), protected at
// rest, excluded from iCloud backup — so a voice note plays instantly on every relaunch with no
// re-download and no re-decrypt.
//
// Was: VoiceMessageView decrypted into tmp/ and DELETED it on scroll-away, so every launch (and every
// scroll) re-downloaded ciphertext + re-decrypted. File protection keeps the plaintext encrypted at
// rest while the device is locked, so persisting it is as safe as VideoCache.
enum AudioCache {
    private static var dir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let d = base.appendingPathComponent("chat-audio", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true,
                                                 attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        var mutable = d; try? mutable.setResourceValues(values)
        return d
    }()

    private static func fileURL(_ messageId: String) -> URL {
        // Message ids are Firestore doc ids (alphanumeric) — safe as file names.
        dir.appendingPathComponent("\(messageId).m4a")
    }

    /// The locally-stored decrypted voice note for this message, if this device has it.
    static func url(for messageId: String) -> URL? {
        let u = fileURL(messageId)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    /// Persist a decrypted voice note on this device (atomic + protected). Returns the local URL.
    @discardableResult
    static func store(_ data: Data, for messageId: String) -> URL {
        let u = fileURL(messageId)
        try? data.write(to: u, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return u
    }

    static func remove(_ messageId: String) {
        try? FileManager.default.removeItem(at: fileURL(messageId))
    }

    /// Sign-out/delete: these files are DECRYPTED voice notes — wipe with the account.
    static func removeAll() {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for f in items { try? fm.removeItem(at: f) }
    }

    /// Total bytes on disk (Settings "storage used").
    static func diskBytes() -> Int {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return items.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
    }

    static func clear() {
        let fm = FileManager.default
        if let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for u in items { try? fm.removeItem(at: u) }
        }
    }
}
