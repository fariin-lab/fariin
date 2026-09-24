import Foundation
import UIKit
import StoryUI

/// ⛔ A STORY THAT WAS BEING POSTED WHEN THE APP DIED IS STILL BEING POSTED.
///
/// The upload queue lived entirely in memory: one `Task`, one array of placeholders. Swipe the app
/// away, run out of battery, or be killed by iOS while backgrounded, and the post was gone — no
/// record, no retry, and nothing on screen the next launch to say it had ever happened. For the one
/// operation in this feature that takes a long time on a bad connection, that is the wrong failure.
///
/// This is a durable record of what a post WAS, written before the first byte moves and removed the
/// moment the story lands. Anything still here at the next sign-in is a post that never finished,
/// and it goes back through the same door it came in.
///
/// ⚠️ PHOTOS ONLY, AND THE OMISSION IS DELIBERATE RATHER THAN UNFINISHED. A photo post is entirely
/// describable: some JPEG bytes and a handful of values. A VIDEO post is not — it is a source file
/// in the system's temporary directory, which iOS is free to delete between launches, plus a burn-in
/// carrying two rendered `UIImage`s and a crop in the editor's own coordinates. Remembering one
/// honestly means copying the clip into permanent storage and serialising the overlays, and half of
/// that is worse than none: a resumed video post that silently drops the text he wrote on it is a
/// bug wearing the costume of a feature. Video keeps the in-memory queue it has today.
///
/// ⚠️ A RESUMED POST CAN LEAVE ONE ORPHAN, AND IT IS INVISIBLE. If the app died between the document
/// being created and the media landing, that document has an empty `mediaUrl` — `parse` skips those,
/// so nobody ever sees it, and `cleanupStories` collects it at expiry. The resumed post writes a new
/// story rather than trying to adopt the old one, because adopting it would mean trusting a document
/// we cannot prove is ours to finish.
enum StoryOutbox {

    /// What a photo post was, in the words `postStoryBackground` speaks.
    struct Ticket: Codable {
        var id: String
        var caption: String
        var stickers: [StoryTapTarget]
        var excluded: [String]
        var included: [String]
        var everyone: Bool
        var allowsReplies: Bool
        var tagLabel: String
        var tagName: String
        var captureProtected: Bool
        /// When it was first attempted. A post is not resumed for ever — see `pending`.
        var startedAt: Double
        /// ⚠️ WHOSE POST THIS IS, AND THE WHOLE REASON IT IS HERE. A ticket carried no owner, the
        /// folder is shared by every account that signs in on this phone, and sign-out did not clear
        /// it — so a post that failed for one person was resumed by the NEXT person to sign in, and
        /// published under their name to their contacts, photo and caption and all. `resume` now
        /// refuses anything that is not the signed-in account's.
        ///
        /// Optional, not defaulted: Swift's synthesized decoder does not apply property defaults, so
        /// this is what lets a ticket written by an older build still decode. Such a ticket has no
        /// owner to check, so `resume` discards it rather than guessing — a day's worth of unfinished
        /// posts at the very worst, against publishing somebody's picture as somebody else.
        var ownerUid: String?
        /// 2026-09-24 audit: a repost's credit (whose story, which one). Without it a repost the app
        /// was killed in the middle of came back on the next launch as the person's OWN story, the
        /// "Reposted" line and the original author gone. Optional for the reason `ownerUid` is: an
        /// older ticket has no such key and must still decode, as an ordinary post, which it was.
        var repostOf: StoryRepost?
    }

    /// Beside the story media cache rather than in `Caches`: the OS empties `Caches` under pressure,
    /// and a queue that the system can delete is not a queue.
    private static var dir: URL { StoryStorage.directory("outbox") }
    private static func meta(_ id: String) -> URL { dir.appendingPathComponent("\(id).json") }
    private static func bytes(_ id: String) -> URL { dir.appendingPathComponent("\(id).jpg") }

    /// A day. A story posted later than that would be most of the way to expired before anybody saw
    /// it, so it is dropped rather than sent late.
    private static let lifetime: TimeInterval = 24 * 3600

    /// ⚠️ A TICKET WHOSE POST IS RUNNING RIGHT NOW IS NOT UNFINISHED. Audit 2026-09-24: `resume`
    /// read every ticket on disk, including the one a post started THIS session had just written
    /// (post from the chats camera before the row's first `load`), tore it up and posted the same
    /// picture again, so the story went up twice. And `load` can pass its "first time for this
    /// account" test twice when two callers race it at launch, which ran `resume` twice and
    /// doubled every resumed post. Both sets live under one lock because `remember` runs off the
    /// main actor.
    private static let lock = NSLock()
    private static var liveIds = Set<String>()
    private static var resumedUids = Set<String>()

    /// Write the record. Called before the first byte moves; returns the id to hand back to `forget`.
    ///
    /// Best effort in both halves: a post must never fail because its safety net could not be
    /// written. A missing record only costs the retry it would have bought.
    static func remember(image: Data, caption: String, stickers: [StoryTapTarget],
                         excluded: Set<String>, included: Set<String>, everyone: Bool,
                         allowsReplies: Bool, tag: StoryAudienceTag, captureProtected: Bool,
                         ownerUid: String, repostOf: StoryRepost? = nil) -> String {
        let id = UUID().uuidString
        lock.lock(); liveIds.insert(id); lock.unlock()
        let t = Ticket(id: id, caption: caption, stickers: stickers,
                       excluded: Array(excluded), included: Array(included),
                       everyone: everyone, allowsReplies: allowsReplies,
                       tagLabel: tag.label, tagName: tag.name,
                       captureProtected: captureProtected,
                       startedAt: Date().timeIntervalSince1970,
                       ownerUid: ownerUid,
                       repostOf: repostOf)
        try? image.write(to: bytes(id), options: .atomic)
        if let d = try? JSONEncoder().encode(t) { try? d.write(to: meta(id), options: .atomic) }
        return id
    }

    /// The post landed, or the person cancelled it. Either way there is nothing left to resume.
    static func forget(_ id: String) {
        guard !id.isEmpty else { return }
        lock.lock(); liveIds.remove(id); lock.unlock()
        try? FileManager.default.removeItem(at: meta(id))
        try? FileManager.default.removeItem(at: bytes(id))
    }

    /// Sign-out. Every unfinished post goes with the account that made it — the next person to sign
    /// in on this phone inherits an empty queue, not somebody else's photographs. `resume` refuses a
    /// foreign ticket anyway; this is the other half, so the bytes do not sit on disk either.
    /// ⚠️ THE CONTENTS, NOT THE FOLDER. `StoryStorage.directory` caches the URL it built and does not
    /// rebuild it, so deleting the directory itself would leave every later `remember` writing into a
    /// path that no longer exists — best-effort writes, so the outbox would simply stop working for
    /// the rest of the process without saying so.
    static func removeAll() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for f in files { try? fm.removeItem(at: f) }
    }

    /// Everything still waiting, oldest first, with anything past its day already cleaned up.
    static func pending() -> [(Ticket, Data)] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        let cutoff = Date().timeIntervalSince1970 - lifetime
        var out: [(Ticket, Data)] = []
        for f in files where f.pathExtension == "json" {
            guard let d = try? Data(contentsOf: f),
                  let t = try? JSONDecoder().decode(Ticket.self, from: d) else {
                try? fm.removeItem(at: f)   // unreadable is not recoverable
                continue
            }
            guard t.startedAt > cutoff, let img = try? Data(contentsOf: bytes(t.id)) else {
                forget(t.id)
                continue
            }
            out.append((t, img))
        }
        return out.sorted { $0.0.startedAt < $1.0.startedAt }
    }

    /// Put every unfinished post back through the ordinary door.
    ///
    /// ⚠️ THE RECORD IS TORN UP BEFORE THE RETRY, not after. `postStoryBackground` writes a record of
    /// its own, so leaving this one in place would mean two records for one post and a second copy of
    /// the story on the launch after that.
    /// ⚠️ `uid` IS NOT OPTIONAL AND IS NOT TRUSTED FROM THE TICKET. Every ticket that does not name
    /// this exact account is torn up rather than posted: a stranger's unfinished post is not ours to
    /// finish, and a ticket from before this field existed cannot prove whose it is.
    @MainActor static func resume(for uid: String) {
        guard !uid.isEmpty else { return }
        // Once per account per process, and never a ticket a running post owns. See `liveIds`.
        lock.lock()
        let first = resumedUids.insert(uid).inserted
        lock.unlock()
        guard first else { return }
        observeReconnect()
        replay(for: uid)
    }

    /// 2026-09-24 decision D18: a failed post is retried again when the connection comes back, and
    /// from the alert's "Try Again", not only at the next launch. Same door as `resume`, without its
    /// once-per-process gate; a running post's ticket is still skipped (see `liveIds`).
    @MainActor static func retry(for uid: String) {
        guard !uid.isEmpty else { return }
        replay(for: uid)
    }

    /// 2026-09-24 decision D18: is there a failed post of this account's waiting for a retry? The
    /// alert offers "Try Again" only when there is.
    static func hasWaiting(for uid: String) -> Bool {
        lock.lock(); let running = liveIds; lock.unlock()
        return pending().contains { $0.0.ownerUid == uid && !running.contains($0.0.id) }
    }

    /// 2026-09-24 decision D18: the post failed but its ticket is kept for a retry. It is no longer
    /// running, so it leaves `liveIds` (the files stay), or `retry` would skip it as a live post.
    static func release(_ id: String) {
        guard !id.isEmpty else { return }
        lock.lock(); liveIds.remove(id); lock.unlock()
    }

    /// 2026-09-24 decision D18: the reconnect trigger, installed once with the first `resume`.
    /// `NetworkState` announces `.networkCameBack` on the main queue.
    @MainActor private static var reconnectObserver: NSObjectProtocol?
    @MainActor private static func observeReconnect() {
        guard reconnectObserver == nil else { return }
        _ = NetworkState.shared   // its path monitor is what posts the notification
        reconnectObserver = NotificationCenter.default.addObserver(
            forName: .networkCameBack, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                if let uid = AuthService.shared.uid { retry(for: uid) }
            }
        }
    }

    @MainActor private static func replay(for uid: String) {
        lock.lock()
        let running = liveIds
        lock.unlock()
        for (t, img) in pending() where !running.contains(t.id) {
            guard t.ownerUid == uid else {
                forget(t.id)
                continue
            }
            forget(t.id)
            StoriesService.shared.postStoryBackground(
                image: img, caption: t.caption, stickers: t.stickers,
                excluded: Set(t.excluded), included: Set(t.included),
                everyone: t.everyone, allowsReplies: t.allowsReplies,
                tag: StoryAudienceTag(label: t.tagLabel, name: t.tagName),
                captureProtected: t.captureProtected,
                repostOf: t.repostOf)   // 2026-09-24 audit: a repost resumes as a repost
        }
    }
}
