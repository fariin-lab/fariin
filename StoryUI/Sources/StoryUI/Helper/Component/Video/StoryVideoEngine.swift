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
        takeClaim(v.storyKey)
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

    /// ⚠️ NOT NAMED `claim`, DELIBERATELY. There is a stored property called `claim` on this type, and
    /// a method sharing its base name is the kind of thing that reads fine and then costs a
    /// forty-minute build round trip to a resolution error. There is no local compiler here.
    private func takeClaim(_ url: String) {
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

    /// Put it back, because the advance it was spent on was refused. A clip reports its end exactly
    /// once; losing that report to a refusal is a story frozen on its last frame for good.
    func rearmFinished() { finishedPending = true }
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
            window = []
            releaseAll()
        }
    }

    /// THE STORIES INSIDE THE PREVIEW WINDOW RIGHT NOW — the reference app's `validIds`, and it is
    /// now literally that: the row's own layout pass publishes the set it just laid out. See
    /// `StoryVideoHost.previewWindow` for why a second, narrower window on this side was the bug.
    ///
    /// ⚠️ THIS IS THE HALF OF HIS 2026-08-12 ASK THAT IS THEIRS VERBATIM. He asked that a story stay
    /// alive while it is still one of the visible preview cards, and be reset only once it has
    /// actually left that range — *"rather than resetting a video simply because its view temporarily
    /// moves or gets detached during the carousel transition"*.
    ///
    /// That is exactly what `StoryItemSetContainerComponent` does, in two tiers:
    ///
    /// · `validIds` — everything laid out this pass. Anything NOT in it is removed on the spot, views
    ///   off the hierarchy (`:1982-1995`).
    /// · `trulyValidIds` — what is actually visible now. An item in `validIds` but no longer visible
    ///   is NOT removed when it goes; the removal is attached to the completion of its own position
    ///   animation and RE-TESTED there (`:1700-1712`):
    ///   ```
    ///   completion: { if !self.trulyValidIds.contains(itemId) { ...remove... } }
    ///   ```
    ///
    /// Ours maps cleanly because a detach is not a decision here either: `dismantleUIView` fires
    /// whenever SwiftUI stops rendering an item, including mid-transition, and treating that as "this
    /// story is finished" is precisely the mistake he described. So the detach only PARKS the view,
    /// and the release happens when the window itself moves — which is the transition having actually
    /// settled somewhere new.
    ///
    /// Empty means "no window is being tracked", which is ordinary full-screen viewing: nothing is
    /// retained then anyway (`retainDismounted`), so an empty set costs nothing.
    private static var window: Set<String> = []

    /// The host says which stories the preview row laid out. Idempotent — only a real change does any
    /// work, and this is called once per frame of a row scroll or a sheet page drag.
    static func setWindow(_ ids: Set<String>) {
        guard ids != window else { return }
        window = ids
        releaseOutsideWindow()
    }

    /// The deferred half: everything parked whose story has now genuinely left the range.
    private static func releaseOutsideWindow() {
        guard retainDismounted else { return }
        var i = 0
        while i < kept.count {
            if window.contains(kept[i].key) { i += 1 }
            else { kept.remove(at: i).view.teardown() }
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
    /// STORED views it would answer nil for the story the sheet came up over — the one whose player
    /// is mounted and paused rather than parked here — and that card would fall back to the poster,
    /// which is second zero, which is the exact report this whole area has been failing on.
    ///
    /// (It used to matter for a second reason as well: the row drew its own copy of the live card
    /// for the length of a swipe, so the copy had to be able to find that player. There is no copy
    /// any more — the live story slides with the row — but a mounted player still has to be findable
    /// by the cards on either side of it, which is what this is for.)
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
    ///
    /// ⚠️ ONLY A VIEW THAT HAS A PLAYER IS WORTH KEEPING, AND THAT IS WHAT MAKES THE CAP HARMLESS.
    ///
    /// Retention exists for exactly one thing: a playback position that would otherwise be lost.
    /// A view with no player has no position — while the sheet is collapsed every item is `.pause`,
    /// so a story you merely swipe PAST never builds one — and rebuilding it produces a view
    /// identical to the one thrown away, from the same poster.
    ///
    /// Keeping those was actively harmful. The cap is three, so swiping the carousel through four
    /// stories evicted the ONE view that mattered — the story the sheet came up over, the only one
    /// holding a player — and swiping back then found nothing, built a fresh player at zero, and the
    /// card fell back to its poster. That is the "reverts to the upload cover" report, reproduced by
    /// the store doing exactly what it was told. Now only players compete for the three places, and
    /// in practice there is one.
    /// WHERE A STORED ITEM VIEW LIVES: in the window, off to the side of it.
    ///
    /// The whole point is that a parked view has NOT left the window, so its `AVPlayerLayer` keeps
    /// its decoder and its decoded frame and can come back with the picture already on it. Sitting a
    /// full screen width to the left costs nothing to composite — there is no pixel of it inside the
    /// screen — and it does not touch the layout of anything real.
    ///
    /// ⚠️ NOT hidden, NOT alpha 0, and NOT zero-sized. Every one of those is a reason for the system
    /// to stop servicing the layer, which is the exact thing being avoided. And user interaction is
    /// off, so a parked story cannot answer a touch that was meant for the live one.
    private static weak var parkingLotView: UIView?
    private static func parkingLot() -> UIView {
        if let v = parkingLotView, v.window != nil { return v }
        let scr = UIScreen.main.bounds
        let v = UIView(frame: CGRect(x: -scr.width * 2, y: 0, width: scr.width, height: scr.height))
        v.isUserInteractionEnabled = false
        v.backgroundColor = .clear
        // Any window will do; it only has to BE in one. The key window is the one that exists.
        let window = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
        window?.addSubview(v)
        parkingLotView = v
        return v
    }

    static func keep(_ view: StoryItemVideoView) {
        guard retainDismounted, view.hasPlayer else { view.teardown(); return }
        let key = view.storyKey
        if let i = kept.firstIndex(where: { $0.key == key }) {
            kept[i].view.teardown()
            kept.remove(at: i)
        }
        // Stored means paused. A view nobody is looking at must not be decoding or making sound.
        view.apply(mode: .pause)
        // ⚠️ AND IT LEAVES THE RIGHT PICTURE BEHIND IT. The pause above warms exactly this still, and
        // the line below plants it under the player before the view goes off screen — because the
        // step after this one is what costs the layer its decoded frame. See
        // `freezeCoverToCurrentFrame` for why only the story the sheet was opened over ever showed it.
        view.freezeCoverToCurrentFrame()
        // ⚠️ PARKED IN THE WINDOW, NOT REMOVED FROM IT — and this is the second attempt at his flash.
        //
        // The first attempt made the picture UNDER the player correct, on the theory that the layer
        // goes empty for a frame and the cover shows through. He shipped it as build 550 and the
        // flash is still there, so the cover was not the whole story: an `AVPlayerLayer` whose view
        // has left the window does not merely stop drawing, it gives its decoder back, and coming
        // back needs a real re-attach and a re-decode before anything appears at all.
        //
        // Keeping the view in the window is the only thing that stops that happening, and it is what
        // he asked for in the first place ("keep its playback position and video state alive while it
        // remains in that range"). Off screen rather than hidden: `isHidden` and `alpha 0` are both
        // grounds for the system to stop servicing a layer, while a view that is simply somewhere
        // nobody is looking is fully live. Full size, so nothing about the layer's geometry changes
        // between parking and coming back — a resize is its own way to lose a frame.
        parkingLot().addSubview(view)
        view.frame = CGRect(origin: .zero, size: UIScreen.main.bounds.size)
        kept.append((key, view))
        // ⚠️ THE CAP EVICTS FROM OUTSIDE THE WINDOW FIRST, and that ordering is the whole point.
        //
        // A plain `removeFirst` is least-recently-stored, which knows nothing about what is on screen.
        // The version of this bug that already shipped: swiping the carousel through four stories
        // evicted the ONE view that mattered, and swiping back found nothing, built a fresh player at
        // zero and fell back to the poster — his "reverts to the upload cover". The `hasPlayer` guard
        // above fixed that instance by keeping player-less views out of the competition entirely.
        //
        // The window closes the rest of it: with a story range being tracked, the oldest entry that
        // has ALREADY left the range goes before any entry still in it. Only when everything held is
        // still inside does it fall back to oldest-first, which is the decoder ceiling talking and
        // cannot be argued with — see the note on `capacity`.
        while kept.count > capacity {
            let victim = kept.firstIndex { !window.contains($0.key) } ?? 0
            kept.remove(at: victim).view.teardown()
        }
    }

    /// Where this clip's live view is, or nil when it has no live view. The one question the card
    /// picture needs answered, and the object that answers it is the same one holding the frame —
    /// so there is no instant to catch and no subject to get wrong.
    /// ⚠️ AT MOST ONE ITEM VIEW MAY BE PLAYING, AND IT IS THE ONE ON SCREEN. Asserted, not assumed.
    ///
    /// Everything else that stops a clip goes through the session, which reaches exactly one view —
    /// the one currently bound to it. That is fine while the bind is current and useless the moment
    /// it is not, which is precisely the window his 2026-08-12 report lives in: tap back from a
    /// video to an image and the video's view has already let go of the session, so the mode has
    /// nobody left to tell and the clip keeps playing behind the picture. The only other thing that
    /// would have stopped it is SwiftUI calling `dismantleUIView`, and a story you can still hear is
    /// proof that did not happen in time.
    ///
    /// This asks nobody's permission and needs no reference: every live view whose clip is not the
    /// one on screen is paused, every time the item changes. Pausing rather than tearing down on
    /// purpose — a view that is mid-transition may still be visible for a frame, and silence is what
    /// was asked for, not a blank card.
    static func pauseAllExcept(_ key: String) {
        for view in live.allObjects where view.storyKey != key {
            view.apply(mode: .pause)
        }
    }

    static func pausedSecond(of key: String) -> Double? {
        // ⚠️ `continue`, NOT `return nil`, AND THAT ONE WORD IS A WHOLE CLASS OF THE OLD BUG.
        //
        // `live` is an unordered weak table and it can briefly hold TWO views for one clip: a
        // torn-down one that has not deallocated yet and the replacement that just mounted. The
        // torn-down one answers 0 because `teardownPlayer` nils its player. Returning on the first
        // match meant whichever the table happened to yield first decided the answer — and a nil
        // here sends the card back to its poster, which is second zero, which is the exact
        // complaint this mechanism exists to end.
        for view in live.allObjects where view.storyKey == key {
            let t = view.currentSecond
            if t > 0 {
                // Remembered on the way past, so the answer outlives the view that gave it.
                lastSecond[key] = t
                return t
            }
        }
        // ⚠️ AND WHEN NO VIEW IS LEFT, THE SECOND STILL IS. THIS IS HIS "AT 3 IT RESETS".
        //
        // `capacity` is 3. Swipe the row far enough and this clip's view is evicted or falls out of
        // the window, so the loop above finds nothing, the card gets nil, and it falls back to the
        // poster — which for a video is the upload cover at second zero. That is the reset he
        // photographed, and the number in his report is the number on that constant.
        //
        // The reference app never shows it because it has nothing to lose: a non-central item there
        // builds no video node and draws a static cover, the same picture at every distance. Ours
        // draws the frame at the second the clip was paused on, which he has had fixed twice and
        // will not give up — so the SECOND has to survive what the VIEW does not.
        //
        // That is exactly what `StoryContentItem.SharedState` is for in their architecture: state
        // deliberately held outside the item so it survives the item's destruction. This is that,
        // for the one value we need it for. It is a `Double` per story, so keeping every clip in the
        // session costs nothing, and a frame regenerated from the file at a remembered second is
        // identical to one generated while the player was alive — the generator reads the FILE, not
        // the player (see `StoryVideoFrames`).
        return lastSecond[key]
    }

    /// WHERE A CLIP WAS PAUSED, KEPT ALIVE ACROSS THE VIEW THAT KNEW IT.
    ///
    /// Cleared with the rest of the session in `releaseAll`, so it can never answer about a sitting
    /// that has ended — which would be the frozen-cover family arriving from a new direction.
    private static var lastSecond: [String: Double] = [:]

    static func releaseAll() {
        let all = kept
        kept.removeAll()
        // The remembered seconds die with the sitting they describe. Left standing they would send
        // a card back to where a clip was paused in a session that is over, which is the frozen
        // cover arriving from a new direction — see `lastSecond`.
        lastSecond.removeAll()
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

    /// ⚠️ KEYS THAT CANNOT BE ANSWERED, REMEMBERED SO THEY ARE NOT ASKED AGAIN. Two things make a
    /// generation fail permanently: the clip is not on disk (which is the state `handleFailedItem`
    /// deliberately creates when it throws away a half-written cache file and streams instead), and
    /// a decoder that will not vend that frame. Neither improves by being retried — and `card` is
    /// called from a view body for every visible card on every frame of a scroll, so without this a
    /// swipe builds an `AVURLAsset` and an `AVAssetImageGenerator` sixty times a second, for ever.
    private static var refused = Set<String>()

    /// FAILED ATTEMPTS ON THE STREAMED PATH, WHICH IS THE ONE THAT CAN FAIL FOR A REASON THAT GOES
    /// AWAY.
    ///
    /// A local file that will not vend a frame will not start; refusing it on the first miss is
    /// right. A clip being read through the range loader is different — the bytes for that second
    /// may simply not have arrived yet, and one miss says nothing about the next. So it gets a small
    /// budget and then the same permanent refusal, because "retry for ever" is how this path opened
    /// a decoder sixty times a second in the first place.
    private static var streamFailures: [String: Int] = [:]
    private static let maxStreamAttempts = 3

    /// ⚠️ AND A CEILING ON HOW MANY RUN AT ONCE. The store caps PLAYERS at three for the decoder
    /// budget, and then this path opened an unbounded number of image generators beside them — one
    /// per distinct key, and a carousel can ask for every visible card in a single pass. Two is
    /// enough to keep the card you are looking at and the one you are swiping towards warm.
    private static let maxConcurrentGenerations = 2

    /// Landings for a key that is still being generated. The opening-frame cover needs one: nothing
    /// else calls back into the item view, and its first ask always answers nil.
    private static var pending: [String: [(UIImage) -> Void]] = [:]

    private static func key(_ url: URL, _ second: Double) -> String {
        "\(url.absoluteString)|\(Int((second * 10).rounded()))"
    }

    /// THE PICTURE FOR A CARD OF THIS CLIP, or nil.
    ///
    /// Nil is a normal answer and always was: a photo has no frame, and neither does a video nobody
    /// has watched in this session. Both fall through to the poster at the call site, exactly as
    /// before.
    ///
    /// ⚠️ `storyId` IS THE SUBJECT AND `url` IS ONLY THE FILE. The live view is found by the story's
    /// own id — the one key the store, the session and SwiftUI's `.id()` all agree on — while the
    /// url is what the generator opens. Asking by url meant three places deriving the same string
    /// three different ways, and any normalisation `URL(string:)` performed broke all of them.
    public static func card(_ url: URL, storyId: String, width: CGFloat) -> UIImage? {
        guard let second = StoryItemViewStore.pausedSecond(of: storyId), second > 0.2 else { return nil }
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

    /// START GENERATING THE FRAME FOR THIS SECOND NOW, because whoever will want it has not asked
    /// yet and would otherwise wait on a decode. Called from the pause, which is the moment the
    /// viewers sheet freezes a story — see `StoryItemVideoView.apply(mode:)`.
    ///
    /// Idempotent: a second call for the same second finds the frame cached or its decode already
    /// running, and starts nothing.
    static func warm(_ url: URL, at second: Double) {
        guard second > 0.2 else { return }
        let k = key(url, second)
        guard full.object(forKey: k as NSString) == nil else { return }
        generate(url, at: second, key: k)
    }

    /// THE COVER THE CLIP IS ABOUT TO HAND OVER TO — second zero, because playback always begins
    /// there. Used behind the video while it loads, for a clip whose poster is missing (the window
    /// between a story doc being written and its `thumb.jpg` upload finishing, and anything posted
    /// before covers existed).
    ///
    /// Deliberately a separate entry point rather than a second meaning for `card`: an opening frame
    /// and a mid-clip frame are two different pictures answering two different questions, and the
    /// last time they shared a slot one overwrote the other on his screen.
    ///
    /// `then` is called on the main thread if the frame has to be generated. Without it the first
    /// ask — which is always the one that matters, at `init`, before anything is cached — would
    /// answer nil and nothing would ever come back.
    public static func opening(_ url: URL, then: ((UIImage) -> Void)? = nil) -> UIImage? {
        frame(url, at: 0, then: then)
    }

    /// THE FRAME AT A GIVEN SECOND, with a landing for the ask that has to wait on the decode.
    ///
    /// `opening` is this at second zero and nothing more; it keeps its own name because an opening
    /// frame and a mid-clip frame answer two different questions at two different call sites, and
    /// the note there is worth keeping pointed at the one that needs it.
    ///
    /// The mid-clip caller is `StoryItemVideoView.freezeCoverToCurrentFrame`, which needs the exact
    /// picture the player is sitting on before the view leaves the screen. Same cache and same key
    /// as the carousel card's still (`card`), so the two cannot disagree about what second four of
    /// a clip looks like — they are literally the same object.
    public static func frame(_ url: URL, at second: Double, then: ((UIImage) -> Void)? = nil) -> UIImage? {
        let k = key(url, second)
        if let hit = full.object(forKey: k as NSString) { return hit }
        // ⚠️ THE LANDING IS REGISTERED ONLY WHEN A DECODE IS ACTUALLY IN FLIGHT, AND THAT ORDERING IS
        // THE FIX. This used to append unconditionally and then ask `generate`, which has four ways
        // to answer "not now" — and on three of them nothing ever drained the array again. The one
        // caller that passes a landing is `openingFrameFallback`, and `layoutSubviews` re-runs it on
        // every pass for as long as the cover is empty, so the single case where no frame could be
        // made was also the case that appended a closure sixty times a second and fired none of them.
        //
        // Safe to append after the call: this type is main-actor and `generate` lands its result in a
        // hop, so the drain cannot run before this returns.
        if generate(url, at: second, key: k), let then {
            pending[k, default: []].append(then)
        }
        return nil
    }

    /// WHERE THE PIXELS COME FROM, AND WHY THIS IS NO LONGER JUST A FILE.
    ///
    /// ⚠️ RANGE STREAMING WENT ON ON 2026-08-12 AND TOOK THE COVERS WITH IT. A streamed clip never
    /// lands a whole object in `VideoCache`: the reader fills `<name>.part` and only promotes it once
    /// every byte is there. So `cachedFileIfUsable` answers nil for exactly the clips people are
    /// watching, this refused to generate, and a story with no `thumb.jpg` and no embedded thumbnail
    /// had nothing at all to draw — a black card, arriving with the switch rather than with any
    /// story code.
    ///
    /// The reader serves an image generator as well as it serves a player, and for the OPENING frame
    /// it is nearly free: second zero is the head of the file, which is the part the lookahead prefix
    /// has already fetched, so the loader answers it off disk without a transfer.
    ///
    /// The whole file still wins whenever it is there — one open and no state machine at all.
    private static func source(for url: URL) -> (asset: AVURLAsset, streamed: Bool)? {
        if let file = CacheManager.cachedFileIfUsable(for: url) {
            return (AVURLAsset(url: file), false)
        }
        guard let streamed = StoryVideoStream.asset(for: url) else { return nil }
        return (streamed, true)
    }

    /// Returns whether a decode for this key is in flight by the time it returns. The caller registers
    /// a landing only on true — see `frame`.
    @discardableResult
    private static func generate(_ url: URL, at second: Double, key k: String) -> Bool {
        // Already decoding: that run drains the landings, so a new one may join it.
        if running.contains(k) { return true }
        guard !refused.contains(k),
              running.count < maxConcurrentGenerations,
              let pixels = source(for: url) else { return false }
        let asset = pixels.asset
        let streamed = pixels.streamed
        running.insert(k)
        let time = CMTime(seconds: second, preferredTimescale: 600)
        // ⚠️ A CARD FRAME IS DRAWN ABOUT A HUNDRED POINTS WIDE. Generating it at 1080 costs eight
        // megabytes a frame, and the cache above holds thirty-two — so five watched clips in one
        // carousel evicted each other and regenerated for ever. Only the OPENING frame, which is
        // drawn full-card behind the video, needs the full size.
        let maxSize = second <= 0 ? CGSize(width: 1080, height: 1920) : CGSize(width: 640, height: 1138)
        DispatchQueue.global(qos: .userInitiated).async {
            let generator = AVAssetImageGenerator(asset: asset)
            // TURNED THE WAY THE CLIP IS MEANT TO BE SEEN. A phone does not rotate the pixels it
            // records: a portrait capture is a landscape buffer plus a 90° transform, and only some
            // of our exports bake it. The layer applies it for playback, so without this the card
            // would lie on its side for exactly the clips the player draws upright.
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = maxSize
            // ⚠️ BOTH TOLERANCES ZERO. The default lets the generator snap to the nearest keyframe,
            // which on a story clip can be seconds away — a picture of a different moment, which is
            // the original complaint with extra steps.
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            let cg = try? generator.copyCGImage(at: time, actualTime: nil)
            DispatchQueue.main.async {
                running.remove(k)
                // ⚠️ THE READER IS RELEASED ON BOTH PATHS. `StoryVideoStream.asset` files its delegate
                // in a table that AVFoundation cannot empty for us, and the delegate owns a URLSession
                // that retains it right back — a reader merely forgotten keeps its transfers running
                // for a picture nobody is waiting for any more.
                if streamed { StoryVideoStream.release(asset) }
                guard let cg else {
                    if streamed {
                        // May yet answer once more bytes land. Budgeted, not endless.
                        let n = (streamFailures[k] ?? 0) + 1
                        streamFailures[k] = n
                        if n >= maxStreamAttempts { refused.insert(k) }
                    } else {
                        // A file that is here and will not vend this frame never will. Do not ask it
                        // sixty times a second.
                        refused.insert(k)
                    }
                    // Dropped rather than kept: the only caller with a landing re-asks from
                    // `layoutSubviews`, and a list nothing drains is what this method used to grow.
                    pending.removeValue(forKey: k)
                    return
                }
                streamFailures.removeValue(forKey: k)
                let image = UIImage(cgImage: cg)
                let cost = Int(image.size.width * image.size.height * 4)
                full.setObject(image, forKey: k as NSString, cost: cost)
                pending.removeValue(forKey: k)?.forEach { $0(image) }
                // The card that asked for this drew a poster; tell the row it may ask again.
                StoryFrameTick.shared.bump()
            }
        }
        return true
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
        refused.removeAll()
        streamFailures.removeAll()
        pending.removeAll()
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
