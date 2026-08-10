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
        // A new frame for this clip makes every card-sized copy of the old one wrong. Dropping them
        // here is what lets `cardFrame` be called from a view body: the expensive part happens once
        // per (clip, width) and a re-bank is the only thing that can make it happen again.
        cardFrames = cardFrames.filter { !$0.key.hasPrefix(url.absoluteString + "|") }
    }

    /// Card-sized copies of the banked frames, keyed `<url>|<width>`.
    ///
    /// ⚠️ THIS MEMO IS WHAT MAKES THE DRAW-TIME READ AFFORDABLE, and without it the read is a bug.
    /// `fitted` runs a `UIGraphicsImageRenderer` pass; the carousel asks for every card's picture on
    /// every body evaluation, and a body evaluation happens on every frame of a scroll. That is N
    /// bitmap re-renders per frame, which is the kind of thing that reads as "the row is laggy".
    ///
    /// Small enough not to need an `NSCache`: these are already downscaled to the card's width
    /// (~120pt), so a whole session's worth is on the order of a megabyte, and `clearAll` empties it
    /// with everything else when the viewer goes.
    private static var cardFrames: [String: UIImage] = [:]
    static func frame(_ url: URL) -> UIImage? { frames.object(forKey: url.absoluteString as NSString) }

    /// ⚠️ THE SAME PICTURE, FOR THE APP, BY STORY — and it needs no capture and no timing.
    ///
    /// The viewers carousel draws its side cards from `previewUrl`, which for a video is the poster
    /// generated at post time: second zero. It papered over that by PHOTOGRAPHING the live card at
    /// the instant a swipe begins, which means one global pointer at one player view and one instant
    /// to get right — and his 2026-08-09 report, twice, is that the picture is still second zero the
    /// moment he leaves a card.
    ///
    /// This slot already holds the answer for EVERY clip that has rendered anything, keyed by the
    /// clip's own url and written whenever a story pauses — which is exactly what the sheet does to
    /// the story it comes up over. So the card can be asked for by story instead of caught in
    /// flight. A window is the wrong thing to narrow; this removes the window.
    ///
    /// Copied down to the width it will be drawn at, because what is kept here is the clip's full
    /// resolution and the carousel draws it about a third that wide.
    public static func cardFrame(_ url: URL, width targetW: CGFloat) -> UIImage? {
        let key = "\(url.absoluteString)|\(Int(targetW.rounded()))"
        if let memo = cardFrames[key] { return memo }
        guard let f = frame(url) else { return nil }
        let out = fitted(f, width: targetW)
        cardFrames[key] = out
        return out
    }

    /// A copy no bigger than it needs to be. Returns the original when it is already small enough,
    /// so this is free in the common case.
    public static func fitted(_ image: UIImage, width targetW: CGFloat) -> UIImage {
        guard targetW > 1, image.size.width > targetW else { return image }
        let h = image.size.height * (targetW / image.size.width)
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = UIScreen.main.scale
        fmt.opaque = true
        let size = CGSize(width: targetW, height: h)
        return UIGraphicsImageRenderer(size: size, format: fmt).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    /// The viewer is gone: a story opened later must start at its beginning.
    public static func clearAll() { positions = [:]; frames.removeAllObjects(); cardFrames = [:] }
}

/// A WAY FOR STORYUI TO ASK THE APP FOR A POSTER IT HAS ALREADY DECODED.
///
/// Telegram's story video is hidden until its first frame exists, and what you look at until then is
/// the thumbnail — which they always have, because it travels inside the message. We have no such
/// guarantee: `PlayerView.setPoster` asks `URLCache.shared` and `StoryDiskCache`, both of which are
/// StoryUI's own caches, while the app draws the stories row and the carousel through its OWN
/// `DiskImageCache` and warms that one. For a story just posted, or one whose cover came down for the
/// ROW rather than for the viewer, both of StoryUI's caches miss, the poster becomes a network fetch,
/// and there is nothing to hold the frame — which is the black.
///
/// So this is the seam that gives the hide-until-ready rule something to hide BEHIND. One synchronous
/// memory-only closure, installed by the app. Nil is a normal answer and falls straight through to
/// the two caches and the network exactly as before, so this can never make a poster arrive later
/// than it used to; it can only make one arrive sooner.
/// A MENTION IS A PERSON, AND ONLY THE APP KNOWS PEOPLE.
///
/// Caption mentions are drawn by the library as links carrying this scheme, and the HOST resolves
/// the username and opens that profile. Keeping the resolution outside means the library never
/// learns what a username is, which is the same line every other host callback here draws.
/// ⚠️ IT REUSES THE APP'S OWN DEEP LINK RATHER THAN INVENTING A SCHEME. `kulan://u/<handle>` is
/// already the app's "open this person" route — the same one a shared profile link and a chat
/// @username use, resolved by `KulanApp.route(from:)`. So a caption mention needs NO new host code
/// and cannot drift from what a mention means everywhere else in the app: one route, one meaning.
public enum StoryMention {
    public static func url(for username: String) -> URL? {
        URL(string: "kulan://u/\(username)")
    }
}

public enum StoryPosterSource {
    /// Must be synchronous and memory-only — it is called on the main thread on the frame a story
    /// opens, which is the whole point of it.
    public static var provider: ((String) -> UIImage?)?
}
