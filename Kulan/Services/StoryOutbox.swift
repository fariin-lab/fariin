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
    }

    /// Beside the story media cache rather than in `Caches`: the OS empties `Caches` under pressure,
    /// and a queue that the system can delete is not a queue.
    private static var dir: URL { StoryStorage.directory("outbox") }
    private static func meta(_ id: String) -> URL { dir.appendingPathComponent("\(id).json") }
    private static func bytes(_ id: String) -> URL { dir.appendingPathComponent("\(id).jpg") }

    /// A day. A story posted later than that would be most of the way to expired before anybody saw
    /// it, so it is dropped rather than sent late.
    private static let lifetime: TimeInterval = 24 * 3600

    /// Write the record. Called before the first byte moves; returns the id to hand back to `forget`.
    ///
    /// Best effort in both halves: a post must never fail because its safety net could not be
    /// written. A missing record only costs the retry it would have bought.
    static func remember(image: Data, caption: String, stickers: [StoryTapTarget],
                         excluded: Set<String>, included: Set<String>, everyone: Bool,
                         allowsReplies: Bool, tag: StoryAudienceTag, captureProtected: Bool) -> String {
        let id = UUID().uuidString
        let t = Ticket(id: id, caption: caption, stickers: stickers,
                       excluded: Array(excluded), included: Array(included),
                       everyone: everyone, allowsReplies: allowsReplies,
                       tagLabel: tag.label, tagName: tag.name,
                       captureProtected: captureProtected,
                       startedAt: Date().timeIntervalSince1970)
        try? image.write(to: bytes(id), options: .atomic)
        if let d = try? JSONEncoder().encode(t) { try? d.write(to: meta(id), options: .atomic) }
        return id
    }

    /// The post landed, or the person cancelled it. Either way there is nothing left to resume.
    static func forget(_ id: String) {
        guard !id.isEmpty else { return }
        try? FileManager.default.removeItem(at: meta(id))
        try? FileManager.default.removeItem(at: bytes(id))
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
    @MainActor static func resume() {
        for (t, img) in pending() {
            forget(t.id)
            StoriesService.shared.postStoryBackground(
                image: img, caption: t.caption, stickers: t.stickers,
                excluded: Set(t.excluded), included: Set(t.included),
                everyone: t.everyone, allowsReplies: t.allowsReplies,
                tag: StoryAudienceTag(label: t.tagLabel, name: t.tagName),
                captureProtected: t.captureProtected)
        }
    }
}
