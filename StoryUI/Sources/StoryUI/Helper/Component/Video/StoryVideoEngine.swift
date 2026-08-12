//
//  StoryVideoEngine.swift
//  StoryUI
//
//  THE FOUR SMALL PIECES THE ITEM-OWNED PLAYER IS BUILT ON.
//
//  ⚠️ READ THIS BEFORE CHANGING ANYTHING IN THIS FOLDER.
//
//  Until 2026-08-12 one `AVPlayer` served a whole person's bucket: `StoryDetailView` held it as
//  `@State`, one reused `PlayerView` borrowed it WEAKLY, and every new item re-pointed that one view
//  and that one player at a different clip. Everything that has gone wrong with story video for two
//  months is a consequence of that single decision, and the file this replaces had 45 commits on it,
//  nearly all of them guards for windows the sharing opened:
//
//    * across the load gap the player still holds the PREVIOUS clip, so the reveal, the progress bar
//      and the frame bank all had to ask "is this still my clip" — `awaitedItem`,
//      `itemSwapSettling`, `StoryPlaybackClock`, and six `self.url == validatedUrl` guards;
//    * a carousel card could not BE a paused player, because there was only one and it had already
//      moved on — so five shipped attempts photographed a frame instead, and all five failed;
//    * leaving an item destroyed its playback state, so returning to it needed a freeze gate, a
//      library-wide freeze flag and an item-adoption path;
//    * nothing could be addressed to a page, so eleven notifications were broadcast to every mounted
//      page and correlated by url after the fact.
//
//  The reference app has none of that machinery because it never shares a player: every story item
//  owns its own, built only when that item is the one playing, released only when the item's media
//  changes. This file and `StoryItemVideoView` are that architecture. What follows is the small
//  amount of shared state it still needs.
//

import UIKit
import AVFoundation

// MARK: - The mode an item is in

/// WHAT A STORY ITEM IS DOING, decided by the one thing that knows — the viewer — and handed DOWN.
///
/// This replaces the `pauseStory` / `resumeStory` / `stopVideo` / `restartVideo` /
/// `stopAndRestartVideo` / `replaceCurrentItem` broadcast family. Those were posted with
/// `object: nil`, so each one reached every mounted page and every page had to work out whether it
/// was meant. A mode travels to exactly one item view and cannot be misdelivered.
///
/// The reference app's equivalent is a three-case enum; its third case keeps the clip playing but
/// looping while a context menu is open over it, which is a state this viewer does not have. Two
/// cases are the whole of what we can honestly use.
public enum StoryProgressMode: Equatable {
    case play
    case pause
}

// MARK: - The video item this page currently has

/// ⚠️ ONE OBJECT PER STORY PAGE: THE MODE GOING DOWN, THE NUMBERS COMING BACK.
///
/// It replaces two separate mechanisms that were both fragile for the same reason — neither could
/// address a particular item.
///
/// DOWNWARD, it replaces the `pauseStory` / `resumeStory` / `stopVideo` / `restartVideo` /
/// `stopAndRestartVideo` / `replaceCurrentItem` broadcast family. Those were posted with
/// `object: nil`, so every one of them reached every mounted page and each page had to work out
/// whether it was meant. One of them (`replaceCurrentItem`) nil'd the player in EVERY page, which is
/// why the old representable had to re-assert a weak player on every update just to survive it.
///
/// UPWARD, it replaces three notifications that carried a url in `userInfo` for the receiver to
/// compare against the story it believed was current — three chances to compare the wrong pair, and
/// at least two shipped bugs from exactly that (a neighbour page's stall freezing the bar of the
/// story on screen; a stale clip's end completing somebody else's segment).
///
/// ⚠️ THE MODE LIVES HERE AND NOWHERE ELSE, and that is deliberate. It cannot be a SwiftUI value
/// passed through the representable, because the pause that matters most arrives on a gesture's
/// `.began` and a `@State` flip there re-renders the hosted view mid-gesture — the reason
/// `hostPause` is a reference box in the first place. One stored mode, applied on every bind and on
/// every set, means an imperative pause and a re-render can never disagree about what this item
/// should be doing.
///
/// Plain, unisolated, and held in `@State` like `HostPauseBox` beside it: it is only ever touched on
/// the main thread, and a view's stored property is not a place to construct actor-isolated state.
final class StoryVideoSession {

    // MARK: Down

    /// What the item is meant to be doing. Starts paused: a page that has not been told to play is
    /// not playing.
    private(set) var mode: StoryProgressMode = .pause

    /// The item view mounted in this page, if it has one. Weak — the view belongs to the hierarchy.
    private weak var view: StoryItemVideoView?

    func setMode(_ newMode: StoryProgressMode) {
        mode = newMode
        view?.apply(mode: newMode)
    }

    /// Restart what is playing, in place. One caller: tapping back past the first story.
    func restart() { view?.restart() }

    /// The view announcing itself. Takes the claim, applies the mode it should already be in, and
    /// publishes what is already true — which matters when a view comes back out of the store with
    /// a player part-way through a clip.
    func bind(_ v: StoryItemVideoView) {
        view = v
        claim(v.storyKey)
        v.apply(mode: mode)
    }

    /// A view leaving. Guarded on it still being ours: a view dismounted AFTER its successor has
    /// already bound must not clear the successor.
    func unbind(_ v: StoryItemVideoView) {
        guard view === v else { return }
        view = nil
        release(v.storyKey)
    }

    // MARK: Up

    /// The clip these numbers describe. Empty means no video item is mounted.
    private(set) var claim: String = ""

    /// Where the player is, and how long the clip is. `duration` prefers the item's real duration
    /// over the host's declared one once it is known — the reference app's `effectiveDuration`.
    private(set) var timestamp: Double = 0
    private(set) var duration: Double = 0

    /// Genuinely moving. The bar may only extrapolate between ticks while this is true.
    private(set) var isPlaying = false

    /// Waiting on bytes MID-CLIP. Initial buffering is deliberately not this — see
    /// `StoryItemVideoView.noteTimeControl`, and the reference app's `.buffering(false, true, _, _)`
    /// pattern, which counts only a stall that interrupts playback that had already begun.
    private(set) var isBuffering = false

    /// The bytes are on disk. The reference app keys its loading shimmer on exactly this and never
    /// on player readiness, which is why a cached story there never shows a loading state.
    private(set) var contentLoaded = false

    /// This clip can never play. The bar falls back to the wall clock so a broken story still hands
    /// the screen on instead of freezing the viewer.
    private(set) var failed = false

    /// ⚠️ A ONE-SHOT LATCH, AND IT HAS TO BE. The reference app's `requestedNext` does the same job:
    /// progress reaching 1.0 can never advance a story there, only the player's own completion can,
    /// and it may only do it once. Ours is consumed by the reader, so a second read of the same end
    /// finds nothing.
    private var finishedPending = false

    private func claim(_ url: String) {
        guard claim != url else { return }
        claim = url
        timestamp = 0
        duration = 0
        isPlaying = false
        isBuffering = false
        contentLoaded = false
        failed = false
        finishedPending = false
    }

    private func release(_ url: String) {
        guard claim == url else { return }
        claim = ""
        timestamp = 0
        duration = 0
        isPlaying = false
        isBuffering = false
        contentLoaded = false
        failed = false
        finishedPending = false
    }

    func update(_ url: String, timestamp: Double? = nil, duration: Double? = nil,
                isPlaying: Bool? = nil, isBuffering: Bool? = nil,
                contentLoaded: Bool? = nil, failed: Bool? = nil) {
        guard claim == url else { return }
        if let timestamp, timestamp.isFinite, timestamp >= 0 { self.timestamp = timestamp }
        if let duration, duration.isFinite, duration > 0 { self.duration = duration }
        if let isPlaying { self.isPlaying = isPlaying }
        if let isBuffering { self.isBuffering = isBuffering }
        if let contentLoaded { self.contentLoaded = contentLoaded }
        if let failed { self.failed = failed }
    }

    func noteFinished(_ url: String) {
        guard claim == url else { return }
        finishedPending = true
    }

    /// TRUE exactly once per end-of-clip. See the latch note above.
    func consumeFinished() -> Bool {
        guard finishedPending else { return false }
        finishedPending = false
        return true
    }
}

// MARK: - Which item views stay alive

/// ⚠️ WHAT SURVIVES A DISMOUNT, AND IT IS THE WHOLE OF THE RESTART-AT-ZERO RULE.
///
/// The owner's rule, in his words: "If I leave a Story video and later return to that same Story,
/// always restart the video from the beginning." The reference app does the same thing, and it does
/// it without storing anything — at full screen it drops every item view that is not the central
/// one, so a revisit BUILDS A NEW PLAYER, and a new player starts at zero by construction.
///
/// It also does the opposite thing in the other state, and that is the half we were missing. While
/// the viewers sheet is collapsed over the story, its cards are still item views: every one of them
/// stays alive and the non-central ones are merely paused. So the item you came from keeps its
/// player, its position and its last decoded frame — for free, with nothing saved and nothing
/// restored. That is why swiping the sheet's cards away and back does not rewind the clip there and
/// did here.
///
/// So retention is not a cache and not an optimisation. It IS the difference between the two
/// behaviours the owner asked for, and it is switched by exactly one thing: whether the sheet is up.
///
/// ⚠️ DO NOT MAKE THIS RETAIN BY DEFAULT. Retaining during ordinary navigation would make a
/// revisited story resume where it left off, which is the behaviour he wrote a rule against.
@MainActor
enum StoryItemViewStore {

    /// Whether a dismounted item view is kept. Set TRUE only while the viewers sheet is engaged.
    static var retainDismounted = false {
        didSet {
            guard !retainDismounted, oldValue else { return }
            releaseAll()
        }
    }

    /// ⚠️ CAPPED, BECAUSE iOS CAPS SIMULTANEOUS VIDEO DECODERS AND GOING OVER FAILS SILENTLY —
    /// the player simply never produces a frame, which reads as a black card on the weakest phones
    /// rather than as an error anybody can catch. The sheet shows a handful of cards, only clips
    /// actually watched in this collapsed session hold a player at all (a card that was never played
    /// never built one — see `StoryItemVideoView.initializeVideoIfReady`), and three is the number
    /// the previous attempt in this area settled on for the same reason.
    private static let capacity = 3

    /// Least-recently-stored first.
    private static var kept: [(key: String, view: StoryItemVideoView)] = []

    /// ⚠️ EVERY LIVE ITEM VIEW, MOUNTED OR STORED, AND IT HAS TO BE BOTH.
    ///
    /// The card picture asks this registry where a clip's player is paused. If it only knew about
    /// STORED views it would answer nil for the story the sheet came up over — which is the one the
    /// carousel draws its own card for the moment a swipe begins (`carouselOwnsSlot` hides the live
    /// card and uncovers the row's). That card would fall back to the poster, which is second zero,
    /// which is the exact report this whole area has been failing on.
    ///
    /// Weak, so a view that is torn down takes its entry with it. Nothing to clear and nothing to
    /// leak.
    private static let live = NSHashTable<StoryItemVideoView>.weakObjects()

    static func register(_ view: StoryItemVideoView) { live.add(view) }

    /// The stored view for this clip, handed back and removed from the store.
    static func take(_ key: String) -> StoryItemVideoView? {
        guard let i = kept.firstIndex(where: { $0.key == key }) else { return nil }
        return kept.remove(at: i).view
    }

    /// Keep this view for a return visit, or tear it down if we are not retaining.
    static func keep(_ view: StoryItemVideoView) {
        guard retainDismounted else { view.teardown(); return }
        let key = view.storyKey
        if let i = kept.firstIndex(where: { $0.key == key }) {
            kept[i].view.teardown()
            kept.remove(at: i)
        }
        // Stored means paused. A view nobody is looking at must not be decoding or making sound.
        view.apply(mode: .pause)
        view.removeFromSuperview()
        kept.append((key, view))
        while kept.count > capacity {
            kept.removeFirst().view.teardown()
        }
    }

    /// Where this clip's live view is, or nil when it has no live view. The one question the card
    /// picture needs answered, and the object that answers it is the same one holding the frame —
    /// so there is no instant to catch and no subject to get wrong.
    static func pausedSecond(of key: String) -> Double? {
        for view in live.allObjects where view.storyKey == key {
            let t = view.currentSecond
            return t > 0 ? t : nil
        }
        return nil
    }

    static func releaseAll() {
        let all = kept
        kept.removeAll()
        all.forEach { $0.view.teardown() }
    }
}

// MARK: - The one picture question

/// ⚠️ ONE QUESTION, ONE DETERMINISTIC ANSWER, AND FIVE MECHANISMS DELETED.
///
/// "What picture does this card show" used to have four sources of truth: a frame bank written from
/// an `AVPlayerItemVideoOutput`, a separate cover slot written by a first-frame decode, a memo of
/// card-sized copies, and the poster. They were kept apart because the bank and the cover had
/// started answering two different questions with one slot, and a shipped regression came from one
/// overwriting the other.
///
/// The output was never a dependable source in the first place. A PAUSED item hands its buffer over
/// exactly once, so the second reader of the same instant gets nil and falls back to the poster —
/// which is second zero, which is precisely the complaint. Four fixes moved WHICH player was asked,
/// WHICH slot it landed in and WHICH instant it was caught at, and none of them could work, because
/// the source itself refuses.
///
/// `AVAssetImageGenerator` on the clip's own local file does not refuse. It is given the second the
/// live node is actually paused on, both tolerances are zero so it cannot snap to a keyframe seconds
/// away, and `appliesPreferredTrackTransform` turns the frame the way the clip is meant to be seen
/// (which is why there is no orientation bookkeeping here any more — the pixel buffer path needed
/// it, this does not).
///
/// The file is always there: a clip only has a live node because it played, and it only played
/// because its bytes were on disk.
@MainActor
public enum StoryVideoFrames {

    /// Full-size generated frames, keyed `<url>|<second, to a tenth>`.
    ///
    /// An `NSCache`, not a dictionary, for the reason the bank it replaces was one: these are
    /// decoded frames of about 8MB each, and the system should be allowed to take them back. Losing
    /// one costs a poster where a frame would have been, and nothing else.
    private static let full: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.totalCostLimit = 32 * 1024 * 1024
        return c
    }()

    /// Card-sized copies, keyed `<url>|<second>|<width>`. Small (a card is ~120pt wide), and the
    /// reason a card may read this from inside a view body at all: `fitted` runs a renderer pass,
    /// and the carousel asks for every card's picture on every frame of a scroll.
    private static var cards: [String: UIImage] = [:]

    /// In-flight generations, so a card asking on every frame of a scroll starts one decode.
    private static var running = Set<String>()

    private static func key(_ url: URL, _ second: Double) -> String {
        "\(url.absoluteString)|\(Int((second * 10).rounded()))"
    }

    /// THE PICTURE FOR A CARD OF THIS CLIP, or nil.
    ///
    /// Nil is a normal answer and always was: a photo has no frame, and neither does a video nobody
    /// has watched in this session. Both fall through to the poster at the call site, exactly as
    /// before.
    ///
    /// The second comes from the clip's own live node (`StoryItemViewStore.pausedSecond`), so this
    /// cannot be handed the wrong story's time. With no live node there is nothing to draw that the
    /// poster does not already say, and this answers nil without generating anything.
    public static func card(_ url: URL, width: CGFloat) -> UIImage? {
        guard let second = StoryItemViewStore.pausedSecond(of: url.absoluteString), second > 0.2 else { return nil }
        let base = key(url, second)
        let sized = "\(base)|\(Int(width.rounded()))"
        if let memo = cards[sized] { return memo }
        if let f = full.object(forKey: base as NSString) {
            let out = fitted(f, width: width)
            cards[sized] = out
            return out
        }
        generate(url, at: second, key: base)
        return nil
    }

    /// THE COVER THE CLIP IS ABOUT TO HAND OVER TO — second zero, because playback always begins
    /// there. Used behind the video while it loads, for a clip whose poster is missing (the window
    /// between a story doc being written and its `thumb.jpg` upload finishing, and anything posted
    /// before covers existed).
    ///
    /// Deliberately a separate entry point rather than a second meaning for `card`: an opening frame
    /// and a mid-clip frame are two different pictures answering two different questions, and the
    /// last time they shared a slot one overwrote the other on his screen.
    public static func opening(_ url: URL) -> UIImage? {
        let k = key(url, 0)
        if let hit = full.object(forKey: k as NSString) { return hit }
        generate(url, at: 0, key: k)
        return nil
    }

    private static func generate(_ url: URL, at second: Double, key k: String) {
        guard !running.contains(k), let file = CacheManager.cachedFileIfUsable(for: url) else { return }
        running.insert(k)
        let time = CMTime(seconds: second, preferredTimescale: 600)
        DispatchQueue.global(qos: .userInitiated).async {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: file))
            // TURNED THE WAY THE CLIP IS MEANT TO BE SEEN. A phone does not rotate the pixels it
            // records: a portrait capture is a landscape buffer plus a 90° transform, and only some
            // of our exports bake it. The layer applies it for playback, so without this the card
            // would lie on its side for exactly the clips the player draws upright.
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 1080, height: 1920)
            // ⚠️ BOTH TOLERANCES ZERO. The default lets the generator snap to the nearest keyframe,
            // which on a story clip can be seconds away — a picture of a different moment, which is
            // the original complaint with extra steps.
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            let cg = try? generator.copyCGImage(at: time, actualTime: nil)
            DispatchQueue.main.async {
                running.remove(k)
                guard let cg else { return }
                let image = UIImage(cgImage: cg)
                let cost = Int(image.size.width * image.size.height * 4)
                full.setObject(image, forKey: k as NSString, cost: cost)
                // The card that asked for this drew a poster; tell the row it may ask again.
                StoryFrameTick.shared.bump()
            }
        }
    }

    /// A copy no bigger than it needs to be. Returns the original when it is already small enough.
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

    /// The viewer is gone.
    public static func clearAll() {
        full.removeAllObjects()
        cards = [:]
        running.removeAll()
    }
}

/// A REDRAW NUDGE, AND NOTHING ELSE.
///
/// A frame is generated off the main thread, so the card that asked for it has already drawn its
/// poster by the time it lands. SwiftUI has no way to know a static store changed, so without this
/// the better picture would sit in the cache until something else happened to redraw the row.
///
/// One counter, bumped once per generated frame. It carries no data on purpose: whoever observes it
/// re-asks `StoryVideoFrames.card`, which is the only thing that knows the answer.
///
/// Deliberately NOT `@MainActor`: it is observed from a plain SwiftUI view's stored property, and the
/// only writer is already on the main thread (the generator's landing hop).
public final class StoryFrameTick: ObservableObject {
    public static let shared = StoryFrameTick()
    @Published public private(set) var n = 0
    private init() {}
    func bump() { n &+= 1 }
}
