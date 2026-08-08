//
//  StoryPlaybackResume.swift
//  StoryUI
//
//  Where a video story's playback was, in seconds, for the length of ONE viewer session.
//
//  His report (2026-08-08): a 50s video playing at 20s, scroll up into the viewers sheet, swipe the
//  carousel to another item and back — and the video is at 0. The viewer draws one story at a time,
//  so leaving an item tears its player down and coming back builds a fresh one; without a memory,
//  fresh means the beginning. "Preserve the exact current video/player state… do not recreate or
//  reset the player" — the view IS recreated (that is the viewer's architecture and not this fix's
//  to change), so what is preserved is the state: the clip's position rides here across the gap.
//
//  Two readers, and they must agree: `PlayerView` seeks the player (`take`, one-shot — a consumed
//  position must not resurrect on the next rebuild), and `StoryDetailView` tops up the progress
//  bar's fraction (`peek`, because it reads BEFORE the player has taken). The bar counts its own
//  clock against the story's declared duration, so a resumed player under a zeroed bar would run
//  the segment ~30s past the clip's end — the two restores are one fix, not two.
//
//  Emptied when the viewer goes (`clearAll`, from the door's `closed` and the presenter's
//  dismissal belt): stories start from the beginning on a fresh open, the way every story app
//  works. Within the session, swiping away and back — the sheet's carousel or a person swipe —
//  resumes, which is his expected behaviour in as many words.
//

import UIKit

@MainActor
public enum StoryPlaybackResume {
    private static var positions: [URL: Double] = [:]

    static func remember(_ url: URL, seconds: Double) { positions[url] = seconds }
    static func peek(_ url: URL) -> Double? { positions[url] }
    static func take(_ url: URL) -> Double? { positions.removeValue(forKey: url) }

    // MARK: - The frame it was showing

    /// THE POSITION CAME BACK AND THE PICTURE DID NOT, which is his 2026-08-08 report: a 30s clip
    /// watched to 10s, swipe to the next story, swipe back — "the video resets its cover back to
    /// the first frame".
    ///
    /// He was right and the resume above was only half the job. Leaving an item tears its player
    /// down; coming back builds a fresh one, and a fresh one has no pixels until it has loaded,
    /// seeked and decoded. What covered that gap was `posterImage` — the story's `thumbUrl`, which
    /// is generated at POST time from the start of the clip. So the position resumed to 10s
    /// underneath a picture of second zero, and the picture is the part you can see.
    ///
    /// So the last frame it actually rendered rides across the gap with the position. Telegram gets
    /// this for free by not tearing adjacent items down; ours is rebuilt (that is the viewer's
    /// architecture and not this fix's to change), so what is preserved is the frame itself.
    ///
    /// ⚠️ NOT `take`-ONCE, unlike the position. A position must be consumed or a later rebuild would
    /// seek backwards to a stale one, but the frame is only ever a placeholder for the moments
    /// before the player has pixels — and it stays correct for as long as the clip has not moved,
    /// which is exactly the case where a rebuild happens. Consuming it would mean the FIRST return
    /// is right and every one after it is back to second zero.
    /// ⚠️ AN `NSCache`, NOT A DICTIONARY, and the reason is that these are FULL-SIZE DECODED FRAMES.
    /// A 1080x1920 frame is about 8MB; a plain dictionary would hold one per video story visited and
    /// only let go at `clearAll`, so a long session through a dozen clips would carry ~100MB of
    /// placeholders. A cache is also exactly the right semantics for what this is: if the system
    /// wants the memory back it should have it, and losing a frame costs nothing but the poster
    /// showing instead — which is what happened before this existed.
    private static let frames: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.totalCostLimit = 48 * 1024 * 1024   // a handful of frames, counted in real bytes
        return c
    }()

    static func rememberFrame(_ url: URL, image: UIImage?) {
        guard let image else { return }
        let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
        frames.setObject(image, forKey: url.absoluteString as NSString, cost: cost)
    }
    static func frame(_ url: URL) -> UIImage? { frames.object(forKey: url.absoluteString as NSString) }

    /// The viewer is gone: a story opened later must start at its beginning.
    public static func clearAll() { positions = [:]; frames.removeAllObjects() }
}
