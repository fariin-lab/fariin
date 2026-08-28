import Foundation
import UIKit

// Last-decrypted messages per chat: in memory, AND on disk since 2026-08-16.
//
// This is what lets a reopened chat render its conversation SYNCHRONOUSLY at ThreadRepository.init
// — fully painted and frozen BEFORE the push transition — instead of fading in a beat late while
// the E2EE decrypt runs off the main thread. It's Fariin's local decrypted render-state / local DB:
// the messages are already unlocked and ready, so the screen isn't empty when the push starts.
//
// ⚠️ THIS HEADER USED TO SAY "kept in memory ONLY (wiped when the app is killed)", and that
// sentence was the whole bug. It was true, it was written down, and it meant a chat opened after
// the app was killed painted a wallpaper, a header and a composer with no messages in them — which
// is precisely what the owner caught by slowing a screen recording down. A stale comment describing
// a real limit is not a warning if nobody acts on it; the limit is gone now and so is the sentence.
//
// Main-actor only (written from ThreadRepository on the main thread); the disk writes hop off it.
final class ThreadMessageCache {
    static let shared = ThreadMessageCache()
    private init() {
        // Background shrink (cache-evacuation idea, softened): keep the cache so reopening a
        // chat after backgrounding is still instant, but trim each chat to ~2 screens of messages so a
        // backgrounded app isn't holding thousands of decrypted Message structs under memory/thermal
        // pressure (the SwiftUI-layout watchdog kill happened exactly there).
        // ⛔ `queue: nil`, NOT `.main`, AND IT IS THE ONE LINE IN A WATCHDOG KILL'S STACK.
        //
        // Crash report 2026-08-21, build 631: `0x8BADF00D`, scene-update, ten seconds exhausted in
        // the BACKGROUND — with the app on 0.02s of CPU, 0%, so nothing of ours was computing. The
        // main thread was parked in `-[NSOperation waitUntilFinished]`, inside `_CFXNotificationPost`,
        // inside `-[UIApplication _applicationDidEnterBackground]`. This observer is that operation.
        //
        // Passing a queue makes NotificationCenter wrap the block in an `NSOperation`, enqueue it and
        // WAIT. But `didEnterBackground` is posted on the main thread, so the run loop that would run
        // that operation is the very one blocked waiting for it. On a healthy phone it turns over
        // fast enough not to matter; on a thermally throttled one (this report: state "serious") the
        // wait is what runs out the ten-second allowance.
        //
        // `nil` runs the block synchronously on the POSTING thread, which for this notification is
        // always main anyway — so it lands on the same thread at the same moment, with no operation
        // and nothing to wait on. The work is a dictionary trim; inline is where it belongs.
        //
        // ⚠️ The other `queue: .main` observers in the app are deliberately left alone. They hang off
        // foreground, become-active, memory-warning and player notifications, none of which run
        // against a hard suspend deadline. This one does, which is the whole reason it is different.
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                               object: nil, queue: nil) { [weak self] _ in
            guard let self else { return }
            for (cid, msgs) in self.byCid where msgs.count > self.backgroundCap {
                self.byCid[cid] = Array(msgs.suffix(self.backgroundCap))
            }
        }
    }

    private var byCid: [String: [Message]] = [:]
    private let cap = 200            // bound memory — the recent window is all the first screen needs
    private let backgroundCap = 60   // ~2 screens; enough for an instant reopen after backgrounding

    func store(_ cid: String, _ messages: [Message]) {
        byCid[cid] = messages.suffix(cap).map { $0 }
        persist(cid, byCid[cid] ?? [])
    }

    /// Memory first, then DISK — and the disk half is why opening a chat after the app was killed no
    /// longer paints an empty wallpaper.
    ///
    /// The owner slowed a screen recording down frame by frame: the header, the wallpaper and the
    /// composer were all drawn, and the bubbles were the only thing missing. That is exactly what a
    /// memory-only cache looks like from a cold start — this class said so itself, in its own header.
    ///
    /// Reading here rather than at a new call site is deliberate: `ThreadRepository.init` already
    /// asks this question and already renders synchronously from the answer, so the whole cold-open
    /// path is fixed by making the answer better rather than by adding another one.
    func messages(for cid: String) -> [Message]? {
        if let warm = byCid[cid] { return warm }
        guard let cold = loadFromDisk(cid), !cold.isEmpty else { return nil }
        byCid[cid] = cold   // one read per chat per launch; every reopen after is the warm path
        return cold
    }

    // UNSENT MESSAGES, kept across leaving and re-entering a chat.
    //
    // ThreadRepository is created per-cid and deallocated when you leave the conversation, and its
    // `pending` array — the optimistic messages that have not been echoed back by the server yet — died
    // with it. Send while offline, go back to the chat list, reopen: the message was simply gone, even
    // though the send was still owed. It looked like the message was lost, and there was nothing left on
    // screen to retry from.
    //
    // This cache outlives the repository, so pending messages ride along with the decrypted window that
    // is already kept here. Bounded like everything else; unsent counts are tiny in practice.
    //
    // ⚠️ STILL MEMORY ONLY, and now by choice rather than by obstacle. This note used to say a
    // durable outbox "needs Message to be Codable and a disk store" — both of which now exist, three
    // feet below. It is deliberately not used here: a message written to disk as still-sending would
    // come back after a relaunch as a bubble waiting on an upload that no longer has any bytes,
    // because the bytes it was carrying are exactly what the disk format leaves out. A durable
    // outbox has to persist the CONTENT and re-drive the send, which is a real piece of work and not
    // a side effect of this cache.
    private var pendingByCid: [String: [Message]] = [:]
    func storePending(_ cid: String, _ messages: [Message]) {
        if messages.isEmpty { pendingByCid[cid] = nil } else { pendingByCid[cid] = messages }
    }
    func pending(for cid: String) -> [Message] { pendingByCid[cid] ?? [] }

    /// Sign-out/delete: these are DECRYPTED messages — never let them survive into
    /// another account's session on this device.
    func removeAll() {
        byCid = [:]; pendingByCid = [:]; lastPersisted = [:]
        // ⚠️ AND THE DISK COPY. This used to be memory only, so signing out was enough on its own;
        // it is not any more, and a folder of decrypted conversations left behind would be the worst
        // thing in this file.
        // ⛔ SYNCHRONOUS, LIKE EVERY OTHER DECRYPTED STORE'S WIPE. `AudioCache.removeAll()` and
        // `VideoCache.removeAll()` delete on the calling thread; this one queued the delete at
        // utility priority, so terminating between sign-out and the block running — the user closing
        // the app on the sign-out screen, or iOS reclaiming it — left the folder behind. Nothing
        // re-runs the wipe and nothing reconciles it at launch, so it simply stayed. One
        // `removeItem` on a directory is not worth the window it was leaving open.
        try? FileManager.default.removeItem(at: Self.directory)
    }

    // MARK: - The disk half

    /// ⚠️ THESE ARE DECRYPTED MESSAGES ON DISK, and that is a real decision, taken by the owner on
    /// 2026-08-16 after being told plainly. It is what every messenger does — a chat you can only
    /// read while online is not a chat app — but it means the protection below is load-bearing, not
    /// decoration.
    ///
    /// `completeUntilFirstUserAuthentication`: unreadable until the phone has been unlocked once
    /// after a reboot. Not `.complete`, which would also block WRITES while the screen is locked, and
    /// messages arrive then — the cache would quietly stop updating exactly when it is filling up.
    private static let protection = FileProtectionType.completeUntilFirstUserAuthentication

    /// Application Support, not Caches: the system may evict Caches under disk pressure, and this is
    /// on the path that decides whether a chat opens full or empty.
    private static let directory: URL = {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        var dir = base.appendingPathComponent("threads-v1", isDirectory: true)
        // ⛔ NEVER INTO A BACKUP. This folder holds the last sixty FULLY DECRYPTED messages of every
        // conversation, and it was the one decrypted store in the app without this line — the audio
        // cache, the video cache, the image cache and the gif cache all set it.
        //
        // That made it the single path by which chat plaintext leaves the phone. The identity key is
        // written `…ThisDeviceOnly`, so it never enters a backup and cannot be restored elsewhere;
        // the text it had already decrypted went anyway, and an unencrypted local backup is readable
        // by anyone holding it.
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.protectionKey: protection])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
        return dir
    }()

    /// Two screens, not the 200 held in memory. The first frame needs what the first frame shows;
    /// the listener has the rest of the history a moment later, and writing 200 decrypted messages
    /// per chat on every snapshot would be real work for content nobody is looking at.
    private let diskCap = 60
    private let io = DispatchQueue(label: "fariin.threadcache.disk", qos: .utility)

    /// ⚠️ NOT `cid.hashValue`. Swift's hash is seeded PER PROCESS, so the same chat would get a
    /// different filename on every launch — the cache would write forever and never once be read,
    /// and it would look like it simply did not work. The cid itself is the name, with anything a
    /// path could argue about replaced.
    private static func fileURL(_ cid: String) -> URL {
        let safe = cid.map { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" ? $0 : "-" }
        return directory.appendingPathComponent("\(String(safe)).json")
    }

    /// The last thing written for each chat, so a rebuild that changed nothing writes nothing.
    /// `ThreadRepository.rebuild()` calls `store` on every snapshot — typing flags and read receipts
    /// included — and encoding a screen of messages for a change the screen cannot see is work for
    /// no one.
    private var lastPersisted: [String: String] = [:]

    private func loadFromDisk(_ cid: String) -> [Message]? {
        guard let data = try? Data(contentsOf: Self.fileURL(cid)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        // Any failure means "no cache", never a crash and never a half-built conversation: a format
        // this build no longer understands is simply a cold open, exactly as before this existed.
        return try? decoder.decode([Message].self, from: data)
    }

    private func persist(_ cid: String, _ messages: [Message]) {
        let slice = messages.suffix(diskCap).map { $0 }
        // Cheap identity for "is this the same screen as last time": how many, and which one is last.
        // Edits and deletions both change the last id or the count in practice, and anything this
        // misses is corrected by the next real change — a cache one snapshot behind is not a cost.
        let stamp = "\(slice.count)|\(slice.last?.id ?? "")|\(slice.last?.text.count ?? 0)"
        guard lastPersisted[cid] != stamp else { return }
        lastPersisted[cid] = stamp
        io.async {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .secondsSince1970
            guard let data = try? encoder.encode(slice) else { return }
            try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
            let url = Self.fileURL(cid)
            try? data.write(to: url, options: [.atomic])
            try? FileManager.default.setAttributes([.protectionKey: Self.protection],
                                                   ofItemAtPath: url.path)
        }
    }
}
