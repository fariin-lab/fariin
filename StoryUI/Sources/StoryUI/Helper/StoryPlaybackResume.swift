//
//  StoryPlaybackResume.swift
//  StoryUI
//
//  The last PICTURE each video story showed, for the length of ONE viewer session. Pictures only:
//  there is deliberately NO playback position in here any more.
//
//  His rule (2026-08-11), which is also Telegram's behaviour read from their source: leaving a
//  story item and coming back RESTARTS it from the beginning — the position is never restored.
//  Telegram tears the item's player down the moment the focused item changes
//  (`StoryItemSetContainerComponent` removes the `VisibleItem`) and a revisit builds a fresh player
//  whose `ownsContentNodeUpdated` seeks straight to zero; nothing in their story code stores a
//  per-item position. This store used to keep one and `setupPlayer` seeked to it, which is exactly
//  how a returned-to clip played from 0:14 under a progress bar that had just started at zero —
//  the two clocks disagreed because only one of them was told. The only continuation that exists
//  now is a LIVE player that was paused and never torn down, which needs no memory at all.
//
//  The frames stay. They are what the viewers-sheet carousel cards draw ("the last picture this
//  clip showed" — his 2026-08-08/09 reports), and — only when the frame is from the clip's START —
//  what the loading veil covers with, so the hand-over is a still of second zero to a clip at
//  second zero. A mid-clip frame is a fine CARD and a lying COVER, which is why the veil asks
//  `usableCoverFrame` and the cards ask `frame`/`cardFrame`.
//
//  Emptied when the viewer goes (`clearAll`, from the door's `closed` and the presenter's
//  dismissal belt): a story opened later starts from its beginning with its own poster.
//

import UIKit
import AVFoundation

/// A banked frame and WHERE IN THE CLIP it was taken. The seconds are what let the veil refuse a
/// mid-clip picture: playback always restarts at zero now, so only a near-zero frame is an honest
/// cover, while the carousel cards may draw any frame at all.
private final class BankedFrame {
    let image: UIImage
    var seconds: Double
    init(image: UIImage, seconds: Double) { self.image = image; self.seconds = seconds }
}

@MainActor
public enum StoryPlaybackResume {

    // MARK: - The frame it was showing

    /// ⚠️ AN `NSCache`, NOT A DICTIONARY, and the reason is that these are FULL-SIZE DECODED FRAMES.
    /// A 1080x1920 frame is about 8MB; a plain dictionary would hold one per video story visited and
    /// only let go at `clearAll`, so a long session through a dozen clips would carry ~100MB of
    /// placeholders. A cache is also exactly the right semantics for what this is: if the system
    /// wants the memory back it should have it, and losing a frame costs nothing but the poster
    /// showing instead — which is what happened before this existed.
    private static let frames: NSCache<NSString, BankedFrame> = {
        let c = NSCache<NSString, BankedFrame>()
        c.totalCostLimit = 48 * 1024 * 1024   // a handful of frames, counted in real bytes
        return c
    }()

    static func rememberFrame(_ url: URL, image: UIImage?, at seconds: Double) {
        guard let image else { return }
        let key = url.absoluteString as NSString
        // ⚠️ THE SAME PICTURE IS NOT A NEW PICTURE, and saying so is what stops the card copies being
        // thrown away twice a second.
        //
        // `currentVideoFrame` falls back to THIS cache when the player has no fresh buffer to give
        // (a paused item hands its buffer over exactly once), so a re-bank while a story is frozen
        // usually arrives holding the very object already stored here. Every such call used to reach
        // the replacement below and drop every card-sized copy of it — and the viewers sheet
        // re-asserts its pause twice a second for as long as it is open, so the carousel was
        // re-running `fitted` for every card twice a second for a frame that had not changed.
        //
        // An identity check, not an equality one: this is only ever about the fallback handing back
        // the object it was given, and comparing pixels would cost more than the work it saves.
        if let existing = frames.object(forKey: key), existing.image === image {
            existing.seconds = seconds
            return
        }
        let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
        frames.setObject(BankedFrame(image: image, seconds: seconds), forKey: key, cost: cost)
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
    static func frame(_ url: URL) -> UIImage? { frames.object(forKey: url.absoluteString as NSString)?.image }

    /// ⚠️ SECOND ZERO LIVES IN ITS OWN SLOT, AND THAT SEPARATION IS THE WHOLE POINT.
    ///
    /// This store answers two different questions with two different pictures. A CARD asks "where
    /// was this clip when I last saw it"; a COVER asks "what is about to play". Since the position
    /// store went (a story returned to always restarts at zero), those two answers stopped being the
    /// same picture — 0:20 for the card, 0:00 for the cover — and for one build they were fought
    /// over in a single slot. Build 533's regression is exactly that fight: `coverFromFirstFrame`
    /// asked "is there a usable cover?", a 0:20 card picture answered no, and the decode then wrote
    /// second zero straight over it. His report is the carousel card falling back to the upload
    /// poster the moment it leaves the centre, which is what a bank holding second zero looks like.
    ///
    /// Two slots cannot overwrite each other, so neither question can cost the other its answer.
    private static let covers: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.totalCostLimit = 24 * 1024 * 1024
        return c
    }()

    /// The clip's opening frame, for the veil. Deliberately NOT `rememberFrame`: this picture is
    /// second zero by construction and must never become what a card draws.
    static func rememberCover(_ url: URL, image: UIImage?) {
        guard let image else { return }
        let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
        covers.setObject(image, forKey: url.absoluteString as NSString, cost: cost)
    }

    /// The picture playback will actually hand over to, or nil.
    ///
    /// Playback always starts at second zero now (see the header), so an honest loading cover is a
    /// frame from the clip's start: the decode above, or a card frame that happens to have been
    /// banked inside the first second. A frame from 0:20 over a clip about to play 0:00 is the
    /// "picture and position disagree" family of bug in reverse, and the veil must not draw it.
    static func usableCoverFrame(_ url: URL) -> UIImage? {
        let key = url.absoluteString as NSString
        if let decoded = covers.object(forKey: key) { return decoded }
        guard let banked = frames.object(forKey: key) else { return nil }
        return banked.seconds <= 1 ? banked.image : nil
    }

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
    public static func clearAll() { frames.removeAllObjects(); covers.removeAllObjects(); cardFrames = [:] }
}

/// WHICH STORY A PLAYER'S CLOCK BELONGS TO — the seam that lets the progress bar read the player.
///
/// The bar used to count wall time against the declared duration and never once asked the player.
/// Telegram does the opposite (`StoryItemContentComponent.updateVideoPlaybackProgress`: the bar's
/// fraction is the player's own reported timestamp over its duration, sixty times a second), which
/// is why their bar physically cannot disagree with the picture — a stall, a seek, a pause or a
/// slow start stops the clock and the bar stops with it.
///
/// To read the player safely the bar must know WHOSE clip is attached: across the
/// `startVideo` → `setupPlayer` gap the player still holds the PREVIOUS story's item, and a bar
/// that read it would draw the old clip's seconds under the new story's segment. So the player view
/// declares the attachment at the item swap and withdraws it the moment a new story claims the
/// view; a bar that finds no declaration holds still rather than guesses.
///
/// Weak keys, so a player that dies with its page takes its entry along — nothing to clear, nothing
/// to leak, and a recycled memory address can never inherit a stale answer.
@MainActor
enum StoryPlaybackClock {
    private static let attached = NSMapTable<AVPlayer, NSURL>.weakToStrongObjects()

    static func attach(_ story: URL, to player: AVPlayer) {
        attached.setObject(story as NSURL, forKey: player)
    }

    static func detach(_ player: AVPlayer?) {
        guard let player else { return }
        attached.removeObject(forKey: player)
    }

    static func story(for player: AVPlayer) -> URL? {
        attached.object(forKey: player) as URL?
    }
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
