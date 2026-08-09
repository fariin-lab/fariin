//
//  StoryStorage.swift
//  StoryUI
//

import Foundation

/// WHERE STORY MEDIA LIVES ON THE PHONE, and why it is not `Caches`.
///
/// His report, 2026-08-07: "when i update the app story chache i loss… need internet". He is right,
/// and it was not only app updates. Both story caches were under `Library/Caches`, which iOS is free
/// to reclaim whenever the device is short of space and which is not carried across an app update.
/// So every story he had already downloaded went back to needing the network, repeatedly, for no
/// reason he could see.
///
/// Every other cache in this app was moved off `Caches` long ago for exactly this reason — see
/// `DiskImageCache`, whose comment says it in the same words — and the two story caches were simply
/// never brought along. `Application Support` is permanent storage the OS does not reclaim, which is
/// where the secure messengers keep media, and it is what he is asking for: "story is most be my
/// storage".
///
/// The other half of his instruction is the part that makes that safe: "after Expired delete". A
/// permanent directory with no lifetime rule is a leak. A story is dead 24 hours after it is posted,
/// so anything in here older than that can never be shown again and is deleted on sight. That bound
/// is what buys the right to leave `Caches` at all.
public enum StoryStorage {

    /// TWO DAYS, WHICH IS TELEGRAM'S OWN NUMBER FOR STORIES — read from their source on his
    /// instruction ("pls read telegram do what tg doit"). `CacheStorageSettings` gives stories a
    /// storage category of their own, separate from everything else, and its default timeout is
    /// `2 * 24 * 60 * 60`. For contrast, in the same table: private chats never expire, groups are
    /// 31 days, channels are 7. Stories are the shortest-lived media they keep, and they delete by
    /// AGE rather than by size — their size ceiling defaults to unlimited.
    ///
    /// Ours could be tighter: a story is dead 24 hours after posting, so 26 would do for the tray.
    /// Two days is the safer number and it is theirs. The margin covers a clock that disagrees, a
    /// story fetched moments before it lapsed, the fact that a file's date is when WE wrote it and
    /// not when it was posted, and the ARCHIVE — his own stories outlive the 24-hour tray, and
    /// deleting their bytes at 26 hours would make his own archive re-download itself, which is the
    /// exact complaint this whole change exists to answer.
    public static let lifetime: TimeInterval = 2 * 24 * 60 * 60

    /// One directory per kind, both under Application Support, both migrated once from the old
    /// `Caches` location so nothing he has already downloaded is lost on the first launch after this.
    /// ⚠️ ANSWERED FROM MEMORY AFTER THE FIRST TIME, and the reason is where this is called from.
    ///
    /// Every one of the calls below does real filesystem work: `createDirectory`, an xattr WRITE for
    /// the backup exclusion, and the migration's `fileExists`. That was fine when this was called
    /// once per download. It is now also called synchronously from `startVideo` — on the main
    /// thread, inside SwiftUI's update pass — to ask whether a clip is already on disk, so every
    /// single tap onto a video story paid for it. Directories do not move while the app is running,
    /// so the work is worth doing exactly once per name.
    ///
    /// The lock is not ceremony: `CacheManager` asks from a background download queue while the
    /// viewer asks from the main thread, and two threads racing a dictionary is a crash rather than
    /// a slow answer.
    private static let dirLock = NSLock()
    private static var dirCache: [String: URL] = [:]

    public static func directory(_ name: String) -> URL {
        dirLock.lock()
        let known = dirCache[name]
        dirLock.unlock()
        if let known { return known }
        let made = buildDirectory(name)
        dirLock.lock()
        dirCache[name] = made
        dirLock.unlock()
        return made
    }

    private static func buildDirectory(_ name: String) -> URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var dir = base.appendingPathComponent(name, isDirectory: true)
        // `completeUntilFirstUserAuthentication`, the same protection the app's other media cache
        // uses: readable by background work after the first unlock, encrypted at rest before it.
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        // Not his iCloud backup's problem. This is re-downloadable media with a 24-hour life; putting
        // it in a backup would inflate it for no benefit, and Apple rejects apps that do it.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
        migrateFromCaches(name: name, into: dir)
        return dir
    }

    /// ONE TIME, AND IT MUST NOT COST A LAUNCH. Moving files is cheap, but it is still file I/O on
    /// whatever thread first asked for the directory, so it happens off the main queue. A file that
    /// already exists at the destination is left alone rather than overwritten: same key, same bytes.
    private static func migrateFromCaches(name: String, into dir: URL) {
        let fm = FileManager.default
        guard let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        let old = caches.appendingPathComponent(name, isDirectory: true)
        guard fm.fileExists(atPath: old.path) else { return }
        DispatchQueue.global(qos: .utility).async {
            if let items = try? fm.contentsOfDirectory(at: old, includingPropertiesForKeys: nil) {
                for u in items {
                    let dest = dir.appendingPathComponent(u.lastPathComponent)
                    if !fm.fileExists(atPath: dest.path) { try? fm.moveItem(at: u, to: dest) }
                }
            }
            try? fm.removeItem(at: old)
        }
    }

    /// Delete everything past its life. Safe to call as often as you like — it walks two directories
    /// and stats their contents, nothing more — and it is deliberately not clever: no size ceiling,
    /// no LRU, no accounting. A story cannot outlive 24 hours, so age alone is a complete rule, and
    /// a complete rule with one input is one that cannot drift out of agreement with the server.
    ///
    /// Runs on a utility queue and never touches the main thread.
    public static func purgeExpired() {
        let names = ["StoryImageCache", "VideoCache"]
        DispatchQueue.global(qos: .utility).async {
            let fm = FileManager.default
            let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            let cutoff = Date().addingTimeInterval(-lifetime)
            for name in names {
                let dir = base.appendingPathComponent(name, isDirectory: true)
                guard let items = try? fm.contentsOfDirectory(
                    at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])
                else { continue }
                for u in items {
                    // The write date, not the access date: access dates are unreliable on iOS and a
                    // story that is re-opened is not a story that is younger.
                    guard let date = (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                    else { continue }
                    if date < cutoff { try? fm.removeItem(at: u) }
                }
            }
        }
    }
}
