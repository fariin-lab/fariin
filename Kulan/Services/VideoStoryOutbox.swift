import Foundation
import UIKit
import CoreGraphics

/// ⛔ A VIDEO STORY THAT WAS BEING POSTED WHEN THE APP DIED IS STILL BEING POSTED (owner, 2026-10-12:
/// "if Kulan is force-closed or killed, the upload must recover and continue when it is reopened").
///
/// `StoryOutbox` covers photos and deliberately left video out: a video post is a source file in the
/// temporary directory (which iOS may delete between launches) plus a burn-in carrying rendered
/// `UIImage`s, and a resume that dropped the text drawn on the clip would be worse than none. This
/// keeps ALL of it, so nothing is dropped:
///
/// - the source clip, copied into Application Support (never purged by the system);
/// - the burn-in's two pictures as PNG files, and every number that goes with them;
/// - trim, mute, caption, stickers, audience, repost credit;
/// - one story id per part of the clip, fixed before the first byte moves, and which parts have
///   already landed.
///
/// On the next sign-in a post still here goes back through `postVideoStoryBackground` with those ids:
/// a part that already landed is skipped, a part that was half written is deleted and written again
/// under the same id (the author may delete their own story), so a resume never duplicates a story.
/// Same day-long lifetime and same owner rule as the photo outbox.
enum VideoStoryOutbox {
    struct Ticket: Codable {
        var id: String
        var ownerUid: String
        var startedAt: Double
        var muted: Bool
        var trimLower: Double?
        var trimUpper: Double?
        var caption: String
        var stickers: [StoryTapTarget]
        var excluded: [String]
        var included: [String]
        var everyone: Bool
        var allowsReplies: Bool
        var tagLabel: String
        var tagName: String
        var tagListIds: [String]
        var captureProtected: Bool
        var repostOf: StoryRepost?
        /// One id per part of the clip, in order; `done` holds the ones that have landed.
        var storyIds: [String]
        var done: [String]
        // The burn-in, minus its two pictures (stored beside the ticket as PNG).
        var hasBurn: Bool
        var cropRect: CGRect?
        var canvasAspect: CGFloat?
        var contentScale: CGFloat
        var holeCorner: CGFloat
        var brightness: Double
    }

    /// How many parts a clip can be split into, at most (`Limits.storyVideoPickSeconds` over
    /// `Limits.storyVideoSeconds`, rounded up, with room to spare).
    static let maxParts = 12
    private static let lifetime: TimeInterval = 24 * 3600
    private static let lock = NSLock()
    private static var liveIds = Set<String>()
    private static var resumedUids = Set<String>()

    private static var root: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let d = base.appendingPathComponent("VideoStoryOutbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    private static func folder(_ id: String) -> URL { root.appendingPathComponent(id, isDirectory: true) }
    private static func meta(_ id: String) -> URL { folder(id).appendingPathComponent("ticket.json") }
    private static func clip(_ id: String) -> URL { folder(id).appendingPathComponent("source.mp4") }
    private static func thumb(_ id: String) -> URL { folder(id).appendingPathComponent("thumb.jpg") }
    private static func overlayFile(_ id: String) -> URL { folder(id).appendingPathComponent("overlay.png") }
    private static func backdropFile(_ id: String) -> URL { folder(id).appendingPathComponent("backdrop.png") }

    /// Write the record before the first byte moves. Returns the ticket id and the story ids the
    /// post must use. Best effort: a post never fails because its safety net could not be written,
    /// in which case the ids are still fresh and simply not remembered.
    static func remember(videoURL: URL, thumbnail: Data, muted: Bool, burn: StoryBurnIn?,
                         trim: ClosedRange<Double>?, caption: String, stickers: [StoryTapTarget],
                         excluded: Set<String>, included: Set<String>, everyone: Bool,
                         allowsReplies: Bool, tag: StoryAudienceTag, captureProtected: Bool,
                         repostOf: StoryRepost?, ownerUid: String) -> (ticket: String, storyIds: [String]) {
        let id = UUID().uuidString
        let ids = (0..<maxParts).map { _ in StoriesService.newStoryId() }
        lock.lock(); liveIds.insert(id); lock.unlock()
        let fm = FileManager.default
        try? fm.createDirectory(at: folder(id), withIntermediateDirectories: true)
        do {
            try fm.copyItem(at: videoURL, to: clip(id))
        } catch {
            // No copy of the clip, nothing that could be resumed: keep no half record.
            try? fm.removeItem(at: folder(id))
            return (id, ids)
        }
        try? thumbnail.write(to: thumb(id), options: .atomic)
        if let o = burn?.overlay?.pngData() { try? o.write(to: overlayFile(id), options: .atomic) }
        if let b = burn?.backdrop?.pngData() { try? b.write(to: backdropFile(id), options: .atomic) }
        let t = Ticket(id: id, ownerUid: ownerUid, startedAt: Date().timeIntervalSince1970,
                       muted: muted, trimLower: trim?.lowerBound, trimUpper: trim?.upperBound,
                       caption: caption, stickers: stickers,
                       excluded: Array(excluded), included: Array(included),
                       everyone: everyone, allowsReplies: allowsReplies,
                       tagLabel: tag.label, tagName: tag.name, tagListIds: tag.listIds,
                       captureProtected: captureProtected, repostOf: repostOf,
                       storyIds: ids, done: [],
                       hasBurn: burn != nil, cropRect: burn?.cropRect, canvasAspect: burn?.canvasAspect,
                       contentScale: burn?.contentScale ?? 1, holeCorner: burn?.holeCorner ?? 0,
                       brightness: burn?.brightness ?? 0)
        write(t)
        return (id, ids)
    }

    /// One part landed: never post it again.
    static func markDone(_ ticket: String, storyId: String) {
        guard var t = read(ticket) else { return }
        if !t.done.contains(storyId) { t.done.append(storyId) }
        write(t)
    }

    /// The post landed, or was cancelled, or failed for good.
    static func forget(_ id: String) {
        guard !id.isEmpty else { return }
        lock.lock(); liveIds.remove(id); lock.unlock()
        try? FileManager.default.removeItem(at: folder(id))
    }

    /// A failure worth retrying later: the record stays, the running claim is let go.
    static func release(_ id: String) {
        lock.lock(); liveIds.remove(id); lock.unlock()
    }

    /// Sign-out: nobody inherits somebody else's clips.
    static func removeAll() {
        try? FileManager.default.removeItem(at: root)
    }

    /// Unfinished video posts of `uid`, replayed once per account per process.
    @MainActor static func resume(for uid: String) {
        guard !uid.isEmpty else { return }
        lock.lock()
        let first = resumedUids.insert(uid).inserted
        let running = liveIds
        lock.unlock()
        guard first else { return }
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        let cutoff = Date().timeIntervalSince1970 - lifetime
        for f in folders {
            let id = f.lastPathComponent
            guard !running.contains(id) else { continue }
            guard let t = read(id), t.ownerUid == uid, t.startedAt > cutoff,
                  fm.fileExists(atPath: clip(id).path) else {
                // Someone else's, too old, unreadable, or its clip is gone: nothing to resume.
                if let t = read(id), t.ownerUid != uid { continue }   // another account's: leave it
                forget(id)
                continue
            }
            var burn: StoryBurnIn?
            if t.hasBurn {
                var b = StoryBurnIn()
                b.overlay = (try? Data(contentsOf: overlayFile(id))).flatMap(UIImage.init(data:))
                b.backdrop = (try? Data(contentsOf: backdropFile(id))).flatMap(UIImage.init(data:))
                b.cropRect = t.cropRect
                b.canvasAspect = t.canvasAspect
                b.contentScale = t.contentScale
                b.holeCorner = t.holeCorner
                b.brightness = t.brightness
                burn = b
            }
            let trim: ClosedRange<Double>? = if let lo = t.trimLower, let hi = t.trimUpper, hi > lo { lo...hi } else { nil }
            StoriesService.shared.postVideoStoryBackground(
                videoURL: clip(id),
                thumbnail: (try? Data(contentsOf: thumb(id))) ?? Data(),
                muted: t.muted, burn: burn, trim: trim, caption: t.caption, stickers: t.stickers,
                excluded: Set(t.excluded), included: Set(t.included), everyone: t.everyone,
                allowsReplies: t.allowsReplies,
                tag: StoryAudienceTag(label: t.tagLabel, name: t.tagName, listIds: t.tagListIds),
                captureProtected: t.captureProtected, repostOf: t.repostOf,
                resumeTicket: id, storyIds: t.storyIds, done: Set(t.done))
        }
    }

    /// Claim a ticket for the post that is replaying it.
    static func claim(_ id: String) {
        lock.lock(); liveIds.insert(id); lock.unlock()
    }

    private static func read(_ id: String) -> Ticket? {
        guard let d = try? Data(contentsOf: meta(id)) else { return nil }
        return try? JSONDecoder().decode(Ticket.self, from: d)
    }
    private static func write(_ t: Ticket) {
        if let d = try? JSONEncoder().encode(t) { try? d.write(to: meta(t.id), options: .atomic) }
    }
}
