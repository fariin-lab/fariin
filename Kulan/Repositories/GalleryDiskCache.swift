import Foundation

/// THE ALL MEDIA PAGE, ON DISK, so opening it after a relaunch paints the last known grid on the
/// first frame instead of a skeleton (owner, 2026-10-17: "white page with a spinner while it loads").
///
/// The in-memory `GalleryCache` already made a SECOND open instant; this is the same answer for the
/// first open after the app was killed. The network still refreshes behind it, silently.
///
/// ⚠️ WHAT IS STORED: the gallery's message metadata as decrypted `Message` values (urls, enc
/// metadata, file names, captions, and the text of messages that carry a link). Never image bytes:
/// thumbnails come from the existing image caches. This follows the precedent `ThreadMessageCache`
/// set on 2026-08-16 (decrypted messages on disk, owner's decision) with the SAME protection: folder
/// out of backup, `completeUntilFirstUserAuthentication`, wiped synchronously on sign-out. Do not
/// weaken any of the three here without taking that decision again.
final class GalleryDiskCache {
    static let shared = GalleryDiskCache()
    private init() {}

    /// Same as the gallery's fetch window: anything more is history the page never shows.
    private let cap = 400
    private static let protection = FileProtectionType.completeUntilFirstUserAuthentication
    private let io = DispatchQueue(label: "fariin.gallery.disk", qos: .utility)
    /// Bumped by `removeAll`, so a write queued before a sign-out cannot land after it.
    private var generation = 0
    /// Last thing written per chat, so an unchanged refresh writes nothing.
    private var lastPersisted: [String: [Message]] = [:]

    /// Application Support, not Caches: Caches can be evicted, and this is the first-frame path.
    /// Version in the folder name: a format change is simply "no cache", never a bad parse.
    private static let directory: URL = {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("gallery-v1", isDirectory: true)
    }()

    /// Every creation goes through here, so a folder re-made after a sign-out wipe is never bare
    /// (the hole `ThreadMessageCache.makeDirectory` closed on 2026-10-06).
    private static func makeDirectory() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.protectionKey: protection])
        var flagged = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? flagged.setResourceValues(values)
    }

    /// The cid is the name (not `hashValue`, which is seeded per process and would never be read back).
    private static func fileURL(_ cid: String) -> URL {
        let safe = cid.map { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" ? $0 : "-" }
        return directory.appendingPathComponent("\(String(safe)).json")
    }

    /// SYNCHRONOUS ON PURPOSE: called while the page is being built, so its first frame has items.
    /// Only on a memory miss (the page then seeds `GalleryCache`), so once per chat per launch.
    /// Any failure is nil = no cache, and the page shows the skeleton as before.
    func load(_ cid: String) -> [Message]? {
        guard !cid.isEmpty, let data = try? Data(contentsOf: Self.fileURL(cid)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode([Message].self, from: data)
    }

    /// Called with only the messages the gallery can show (the caller filters), newest first.
    func store(_ cid: String, _ messages: [Message]) {
        guard !cid.isEmpty else { return }
        let slice = Array(messages.prefix(cap))
        guard lastPersisted[cid] != slice else { return }
        lastPersisted[cid] = slice
        let gen = generation
        io.async { [weak self] in
            guard let self, self.generation == gen else { return }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .secondsSince1970
            guard let data = try? encoder.encode(slice) else { return }
            if !FileManager.default.fileExists(atPath: Self.directory.path) { Self.makeDirectory() }
            let url = Self.fileURL(cid)
            try? data.write(to: url, options: [.atomic])
            try? FileManager.default.setAttributes([.protectionKey: Self.protection], ofItemAtPath: url.path)
        }
    }

    /// Sign-out/delete. Synchronous like `ThreadMessageCache.removeAll`: drain `io` first so a write
    /// already in flight lands before the delete, never after it.
    func removeAll() {
        generation += 1
        lastPersisted = [:]
        io.sync {}
        try? FileManager.default.removeItem(at: Self.directory)
    }
}
