//
//  VideoLoader.swift
//  StoryUI (iOS)
//
//  Created by Tolga İskender on 30.04.2022.
//

import Foundation
import UIKit
import AVKit
import CoreImage   // CIImage / CIContext, for reading a real frame out of the player

final class PlayerView: UIView, StoryVideoFrameSource {

    // MARK: Public Properties
    weak var player: AVPlayer?
    var duration: Double = 0.0
    var state: MediaState = .notStarted
    var mediaState: ((MediaState, Double) -> ())?

    let contentView = UIView()
    /// WHAT FILLS THE BARS WHEN A CLIP DOES NOT FIT THE CARD: Telegram's canvas, the same one the
    /// photo half draws and the same one `VideoTranscoder` bakes into every exported story.
    ///
    /// A clip posted from a recent build already carries the canvas in its own pixels and this is
    /// never seen. It is here for the clips posted before that bake existed, and for anything that
    /// reaches the viewer without it — and it is the SAME gradient, from the SAME sampler, so the
    /// two are indistinguishable. That is the point: a story must not change appearance depending on
    /// which half of the app happened to draw its background.
    private let canvasLayer = StoryCanvas.makeLayer()
    /// The frame the canvas colours were read from, so a poster arriving after the first video frame
    /// cannot re-colour a canvas that is already right (and start an implicit animation doing it).
    private var canvasSourced = false

    // MARK: Private Properties
    private let playerLayer = AVPlayerLayer()
    private var url: URL?
    private let cacheManager: CacheManager

    private var observation: NSKeyValueObservation?
    private var sizeObservation: NSKeyValueObservation?
    /// Watches for an item that CANNOT play. Without it the spinner has no exit: the only thing that
    /// ever takes it down is playback starting.
    private var statusObservation: NSKeyValueObservation?
    /// The cache file currently loaded, so a failure can throw the bad copy away.
    private var cachedFileInUse: URL?
    /// One retry per story, or a dead URL becomes an endless download loop.
    private var didRetryRemote = false
    /// The clip's cover — `thumb.jpg`, a full-size photograph of this clip's own opening frame —
    /// drawn while it loads instead of a black rectangle, and drawn SHARP (see `cover`). Set by the
    /// host through `VideoView`; nil simply falls back to the embedded thumbnail, then to black.
    var posterImage: UIImage?
    /// THE COVER OF LAST RESORT, decoded from the story's own bytes — see `Story.blurThumb`. It is
    /// tiny (about 30px wide) and is the ONLY cover that is drawn blurred, because at card size that
    /// is the only honest thing to do with it: blurred it reads as an out-of-focus frame of the clip,
    /// sharp it reads as a broken image.
    ///
    /// Held decoded because it is asked for on every veil rebuild and the base64 is not free.
    private var blurThumbImage: UIImage?
    private var blurThumbSource: String?

    /// Whatever this view can put on screen RIGHT NOW, in order of truth: the frame the person was
    /// actually watching, then the real poster, then the embedded thumbnail. Nil only when the story
    /// carries none of the three, which for anything posted from a current build cannot happen.
    ///
    /// ⚠️ `isFrame` IS THE DIFFERENCE BETWEEN "THE VIDEO IS HERE" AND "THE VIDEO IS A SMEAR", and
    /// getting it wrong is his 2026-08-09 "tap left/right and it is a full blur screen". A real frame
    /// of this clip — a resume still, or `thumb.jpg`, which is a full-size photograph of the clip's
    /// own opening — is worth showing AS IT IS. Only the 30px embedded thumbnail has to be blurred,
    /// because at card size that is all it can honestly be.
    ///
    /// Telegram draws exactly this distinction and it is the whole reason their stories never look
    /// blurred: `StoryItemImageView` shows the cached first frame or the downloaded preview
    /// representation SHARP (`preparingForDisplay()`, `.scaleAspectFill`), and reaches for
    /// `blurredImage(_:radius: 10, iterations: 3)` only on `decodeTinyThumbnail(immediateThumbnailData)`
    /// — the inline bytes that are all it has when there is nothing else at all.
    private var cover: (image: UIImage, isFrame: Bool)? {
        // Only a frame from the clip's START. Playback always begins at zero now (see
        // StoryPlaybackResume's header), so a mid-clip banked frame would cover second zero with a
        // picture of 0:20 — the picture-and-position disagreement, drawn by the veil itself.
        if let banked = self.url.flatMap({ StoryPlaybackResume.usableCoverFrame($0) }) { return (banked, true) }
        if let poster = posterImage { return (poster, true) }
        if let thumb = blurThumbImage { return (thumb, false) }
        return nil
    }

    func setBlurThumb(_ base64: String?) {
        guard blurThumbSource != base64 else { return }
        blurThumbSource = base64
        blurThumbImage = nil
        guard let base64, !base64.isEmpty,
              let data = Data(base64Encoded: base64),
              let img = UIImage(data: data) else { return }
        blurThumbImage = img
        // The canvas may have given up for want of a colour source before this arrived.
        refreshBackdrop()
    }
    /// The poster this view was told about, so a late fetch can be dropped if the story moved on.
    private var posterURL: String?
    /// Whether we have already told the host it is buffering, so the notification is posted on the
    /// EDGE rather than on every KVO tick — `timeControlStatus` fires often.
    private var didReportBuffering = false
    /// Whether the veil currently up carries a spinner, so a rebuild (a poster landing mid-load)
    /// keeps the answer it was built with instead of resetting a cached clip's cover to "downloading".
    private var veilHasSpinner = false

    /// Tell the story's progress bar to hold, or to carry on. One notification, posted only when the
    /// answer actually changes.
    private func setBuffering(_ buffering: Bool) {
        guard didReportBuffering != buffering else { return }
        didReportBuffering = buffering
        // ⚠️ WHO IS BUFFERING, not just that somebody is. The flag used to travel as a bare Bool and
        // the receiver could only ask whether IT was the current page — never whether the SENDER
        // was. The pager keeps neighbour pages mounted, so a clip stalling on a page nobody is
        // looking at froze the progress bar of the story on screen. Carrying the url makes the
        // question answerable: a report about a clip that is not the one being watched is ignored.
        NotificationCenter.default.post(name: .storyBuffering, object: buffering,
                                        userInfo: url.map { ["url": $0.absoluteString] })
    }

    /// The clip's own pixel size, once the item has reported it. Kept so the fit/fill decision can
    /// be re-taken whenever the VIEW's size changes, not only when the video's does.
    private var presentedSize: CGSize = .zero

    /// EVERY PIECE OF VIDEO GEOMETRY, GLUED TO THE REAL BOUNDS. The layer's frame was assigned
    /// once, at init, from a view created at UIScreen size — and CALayer sublayers do not
    /// autoresize, so when the story shrank into the 9:16 card (`8e224d9`) the AVPlayerLayer
    /// silently stayed a full screen tall. A letterboxed clip then centred itself in that
    /// invisible 852pt layer, not in the card: ~76pt of black above the video and the bottom
    /// cropped off — his "video frame drops downward" screenshot, as steady state. Photos never
    /// did this because ImageLoader has always re-pinned its subviews in layoutSubviews; this is
    /// the video's missing half of that.
    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)   // a resize correction must not animate
        contentView.frame = bounds
        playerLayer.frame = bounds
        StoryCanvas.frame(canvasLayer, to: bounds)
        CATransaction.commit()
        viewWithTag(999)?.frame = bounds        // the loading veil rides along
        applyGravity()
        refreshBackdrop()
        // A clip whose frame and size both landed while this view had no bounds yet is waiting on
        // exactly this pass, and nothing else would come along to release it.
        revealVideoIfReady()
    }

    /// Fill vs fit, decided against the CARD the video actually lives in — it was decided against
    /// UIScreen (aspect 2.17), so every ordinary 9:16 clip (aspect 1.78) was demoted to letterbox
    /// inside a 16:9 card it fits exactly. And it was applied on an async hop when
    /// `presentationSize` arrived, AFTER the first painted frame — the first paint showed one
    /// scale and a beat later the other: his "zoomed out for a brief moment, then it suddenly
    /// zooms in". Synchronous when the size is already known (a preloaded item knows it at
    /// attach), so the first frame is born at its final scale.
    private func applyGravity() {
        guard presentedSize.width > 0, presentedSize.height > 0,
              bounds.width > 0, bounds.height > 0 else { return }
        let fills = StoryCanvas.fills(media: presentedSize, in: bounds.size)
        let want: AVLayerVideoGravity = fills ? .resizeAspectFill : .resizeAspect
        guard playerLayer.videoGravity != want else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.videoGravity = want
        CATransaction.commit()
    }

    /// The canvas behind a letterboxed clip. Nothing to do when the video fills the card — there are
    /// no bars to fill.
    ///
    /// ⚠️ SECOND ATTEMPT. The first shipped in 470 and did nothing, and the flaw was that it asked
    /// `playerLayer.videoGravity` whether the clip fits. That is a DERIVED value written by
    /// `applyGravity`, so the answer depended on whether that had already run — and it starts life
    /// as `.resizeAspectFill` (set in `setupPlayer(_:)`), which reads as "fills, no bars needed", so
    /// every call before the clip's real size arrived HID the backdrop. Hiding is exactly the black
    /// he photographed.
    ///
    /// Both this and `applyGravity` go through `StoryCanvas.fills`, so the two cannot disagree and
    /// neither waits on the other. And when the answer is not known yet — the poster is here but the
    /// clip's size is not — it SHOWS. A canvas behind a video that turns out to fill the frame is
    /// invisible; black behind a video that does not is the bug.
    private func refreshBackdrop() {
        // ⚠️ THE POSTER WAS NEVER GUARANTEED TO BE HERE, AND THAT IS THE BLACK BARS.
        //
        // This used to give up when `posterImage` was nil, and giving up means HIDING, which is a
        // black bar. `setPoster` looks in `URLCache.shared` and `StoryDiskCache` — both StoryUI's own
        // caches, filled by its ImageLoader and prefetcher. The app draws its story row through its
        // OWN DiskImageCache and warms that one. So for a story you just posted, the two caches this
        // reads are cold, the poster becomes a network fetch, and until it lands there is nothing to
        // sample. That is the square-video report, three times: the decision logic was right all
        // along, the picture it needed was simply not there yet.
        //
        // The player is a better source than the poster anyway: it is the frame actually on screen
        // rather than second zero, it needs no network, and it cannot come back black the way a
        // screen capture can. The poster stays as the fallback for the moments before the first
        // frame is decoded.
        guard bounds.width > 1, bounds.height > 1 else { return }
        // Undecided (presentedSize still zero) counts as "might have bars" — see the note above.
        let known = presentedSize.width > 0 && presentedSize.height > 0
        let fills = known && StoryCanvas.fills(media: presentedSize, in: bounds.size)
        canvasLayer.isHidden = fills
        guard !fills else { return }
        // The colours are read ONCE, from whichever frame is available first, and then left alone.
        // Re-reading them when the poster lands after the video has already started would repaint
        // the bars mid-story, which is a colour change under a still picture — the exact class of
        // thing this rewrite exists to remove. Nothing about the canvas depends on the card's size,
        // so unlike the veil it replaced there is nothing to rebuild when the box changes shape.
        guard !canvasSourced else { return }
        // ⚠️ THE LIVE FRAME MAY ONLY SPEAK FOR THIS CLIP ONCE ITS ITEM IS ATTACHED. In the load gap
        // the player still holds the PREVIOUS clip, and a canvas sourced from its buffer here would
        // latch A's colours onto B for the whole visit (`canvasSourced` never re-asks). Before the
        // attach, the remembered frame — keyed by THIS clip's url — is the only live answer allowed.
        let live = awaitedItem != nil ? currentVideoFrame()
                                      : self.url.flatMap { StoryPlaybackResume.frame($0) }
        // The embedded thumbnail is a legitimate colour source and is the ONLY one available on a
        // first visit to a story whose `thumb.jpg` is missing — which is exactly the case that left
        // the canvas at its neutral black in his screenshots.
        guard let source = posterImage ?? live ?? blurThumbImage else { return }
        canvasSourced = true
        StoryCanvas.apply(StoryCanvas.colours(of: source), to: canvasLayer)
    }

    // MARK: - HIDDEN UNTIL THERE IS A FRAME (Telegram's rule)

    /// ⚠️ THE PLAYER LAYER IS HIDDEN FROM BIRTH AND SHOWN ONCE, WHEN IT HAS A PICTURE.
    ///
    /// His 2026-08-08 report: tap across to a video and it blinks BLACK, then paints the clip at the
    /// wrong size, then settles. Both faults are the same mistake — the layer was on screen before it
    /// had anything to draw.
    ///
    /// An `AVPlayerLayer` with no decoded frame draws its background, and behind it is a canvas that
    /// starts life black-to-black (`StoryCanvas.makeLayer`) over a black view. That is the blink. And
    /// `videoGravity` is still the `.resizeAspectFill` it was born with until `presentationSize`
    /// arrives, so the first frame it does paint is at the wrong scale and then corrects itself. That
    /// is the second screenshot.
    ///
    /// Telegram, read from source before this was written
    /// (`StoryItemContentComponent`, `MediaPlayerNode`): the video node is created `isHidden = true`
    /// over a thumbnail view, and the ONLY thing that ever unhides it is `hasSentFramesToDisplay` —
    /// which they raise from the first `enqueue` of a sample buffer, and on iOS 17.4+ from
    /// `AVSampleBufferDisplayLayerReadyForDisplayDidChange`. There is no timer and no fallback. Our
    /// exact equivalent on an `AVPlayerLayer` is `isReadyForDisplay`, which Apple documents as "the
    /// first video frame has been made ready for display for the current item".
    ///
    /// ⚠️ WHY THIS IS NOT THE REVEAL GATE HE REVERTED THIS MORNING (`a0947b3`). That one waited for
    /// `timeControlStatus == .playing`, and a story is allowed to sit PAUSED — held under his finger,
    /// or opened paused — in which case playback never starts and the veil never lifts. Its 0.4s
    /// backstop did not save it, because that was itself gated on playback having started.
    /// `isReadyForDisplay` has no such problem: a paused player still decodes and still becomes
    /// ready, which is precisely why it is the signal Telegram uses and the reason there is no timer
    /// here to go wrong.
    private var readyObservation: NSKeyValueObservation?

    /// The clip whose first frame the cover is waiting for, or nil while there is no such clip.
    ///
    /// Held so the reveal can tell THIS clip's readiness from the previous one's — the player is
    /// shared across every page of the viewer and keeps the old item attached across the async gap
    /// between `startVideo` and `setupPlayer(_:)`. See the note in `revealVideoIfReady`. Weak,
    /// because the player owns the item and this must never be the reason one stays alive.
    private weak var awaitedItem: AVPlayerItem?

    /// Both answers have to be in: a frame exists, and we know the shape to frame it at. Whichever
    /// lands second does the reveal. Runs once per clip — the `isHidden` test is the latch.
    ///
    /// The frame half is READ LIVE off the layer rather than latched from the observer, and that is
    /// deliberate. `isReadyForDisplay` is documented to belong to the CURRENT ITEM, so replacing the
    /// item puts it back to false; if that ever failed to hold, a latched copy could leave this clip
    /// covered for ever, while a live read can at worst show it a frame early. One of those is the
    /// old bug and the other is a dead story, so the live read is the one that fails safely.
    private func revealVideoIfReady() {
        guard playerLayer.isHidden else { return }
        // ⚠️ THE PREVIOUS CLIP IS STILL ATTACHED WHEN THIS CLIP GOES UNDER COVER, and it is ready for
        // display, and its `presentationSize` is not zero. `startVideo` hides the layer immediately,
        // but the swap to the new item happens in `setupPlayer(_:)`, which is an ASYNC hop later — the
        // cache has to answer first. Every test below would pass in that window on the OLD clip's
        // answers, so a single `layoutSubviews` pass (which calls straight into here) would uncover
        // the layer and pull the veil down, and then `replaceCurrentItem(with: nil)` would blank it.
        // That is a black frame with nothing left covering it: the same fault this gate exists to
        // remove, arriving through the back door.
        //
        // So the gate asks WHICH CLIP as well as whether there is a frame. `awaitedItem` is set on
        // the line after the swap and nowhere else, and `startVideo` clears it, so between the two
        // there is deliberately nothing this can reveal.
        guard let awaited = awaitedItem, player?.currentItem === awaited else { return }
        // ⚠️ AND NOT IN THE SAME RUNLOOP TURN AS THE SWAP. `isReadyForDisplay` is reset by
        // AVFoundation asynchronously after `replaceCurrentItem`, so inside `setupPlayer` — where
        // the `.initial` presentationSize delivery for a preloaded item calls straight back in
        // here — the layer can still be answering TRUE about the clip that was just flushed. That
        // reveal uncovers a layer with no frame for THIS clip: his first-tap black flash. The hop
        // that clears this flag re-asks the reveal itself, and the `isReadyForDisplay` KVO below
        // keeps re-asking on every later change, so the strictest thing that can happen is the
        // cover staying up ONE turn longer — never a stranded spinner.
        guard !itemSwapSettling else { return }
        // (A `pendingResumeSeek` guard lived here while `setupPlayer` seeked to a remembered
        // position. There is no resume seek any more — a story always restarts at zero, the
        // owner's 2026-08-11 rule — so the first displayable frame IS the frame being handed to.)
        guard playerLayer.isReadyForDisplay else { return }
        // A LAYER WITH A FRAME KNOWS ITS SIZE, so ask the item directly rather than wait to be told.
        // The observer below is still what usually answers first; this is here so that a clip whose
        // `presentationSize` notification is late or missed cannot leave the cover up for ever. There
        // is deliberately no timer anywhere in this path — a timer is what would put the wrong
        // gravity back on screen, which is the fault this whole change exists to remove.
        let live = awaited.presentationSize
        if presentedSize.width <= 0 || presentedSize.height <= 0, live.width > 0, live.height > 0 {
            presentedSize = live
        }
        guard presentedSize.width > 0, presentedSize.height > 0 else { return }
        // A CARD WITH NO SIZE CANNOT DECIDE FIT VERSUS FILL, so revealing into one would show the
        // clip at whatever gravity it was born with — the very frame this exists to prevent.
        // `layoutSubviews` calls back here, so this is a wait rather than a refusal.
        guard bounds.width > 1, bounds.height > 1 else { return }
        // ORDER MATTERS: the gravity and the canvas colours are settled while the layer is still
        // hidden, so the first frame anybody sees is already at its final scale on a coloured
        // backdrop. This is the flicker in his second screenshot, removed by construction.
        applyGravity()
        refreshBackdrop()
        CATransaction.begin()
        CATransaction.setDisableActions(true)   // an appearance must not fade in
        playerLayer.isHidden = false
        CATransaction.commit()
        // The cover comes down in the same turn as the clip goes up, so there is no frame with
        // neither of them on screen.
        removeActivityIndicatory()
    }

    /// The observer's landing point: remember the clip's size, re-take the decision.
    fileprivate func notePresentationSize(_ s: CGSize) {
        presentedSize = s
        applyGravity()
        // The clip's own size is what decides fit vs fill, so this is the moment the backdrop is
        // either needed or not. layoutSubviews cannot be relied on to run again after it.
        refreshBackdrop()
        // LAST, deliberately: the gravity is right and the canvas is coloured, so this is the first
        // moment the clip may be shown without showing a frame of either being wrong.
        revealVideoIfReady()
    }

    // MARK: - Initializers
    override init(frame: CGRect) {
        self.cacheManager = CacheManager()
        super.init(frame: frame)
        self.layer.cornerRadius = 12
        self.clipsToBounds = true
        setupPlayer()
    }

    deinit {
        observation = nil
        sizeObservation = nil
        statusObservation = nil
        readyObservation = nil
        if let tok = endObservationToken { NotificationCenter.default.removeObserver(tok) }
        player = nil
    }

    required init?(coder: NSCoder) { nil }

    // MARK: - A real frame, from the player rather than from the screen

    /// ⚠️ `drawHierarchy` DOES NOT RELIABLY CAPTURE A VIDEO LAYER. It sometimes returns the frame and
    /// sometimes a plain black rectangle, with no error and no way for the caller to tell — which is
    /// what made the viewers carousel go black in build 470, and what still makes a video story fall
    /// back to its second-zero poster whenever a capture quietly fails.
    ///
    /// `AVPlayerItemVideoOutput` asks the PLAYER for the frame it is showing, which is the only way
    /// to get one that cannot come back black. Attached when the item is set rather than when a
    /// picture is wanted: an output has no frames for the first moments after it is added, so one
    /// created on demand answers nil exactly when it is needed.
    private var frameOutput: AVPlayerItemVideoOutput?
    private let frameContext = CIContext(options: [.useSoftwareRenderer: false])
    /// TRUE for the runloop turn in which `setupPlayer` swaps items. `isReadyForDisplay` can still
    /// be answering about the flushed clip inside that turn — see the guard in `revealVideoIfReady`.
    private var itemSwapSettling = false

    /// The end-of-clip report for the CURRENT item, recreated per item and scoped to the item
    /// object — Telegram advances a video only from the player's own completion
    /// (`videoNode.playbackCompleted` → `presentationProgressUpdated(1.0, canSwitch: true)`), never
    /// from progress arithmetic, and this is our half of that rule. The bar is capped just under
    /// the segment boundary (`syncBarToPlayer`), so this report is the ONLY thing that can complete
    /// a video segment: the clip can neither be cut off early nor outlived by its own bar.
    private var endObservationToken: NSObjectProtocol?

    /// The item the current `frameOutput` was added to, so it can be taken off again. Weak: the
    /// player owns its items and this must never be the reason one stays alive.
    private weak var frameOutputItem: AVPlayerItem?

    /// ⚠️ HOW THIS CLIP IS MEANT TO BE TURNED, and without it a portrait story hands back a
    /// LANDSCAPE picture — his 2026-08-09 screenshot of the carousel, one card lying on its side
    /// among portrait ones.
    ///
    /// A phone does not rotate the pixels it records. A portrait capture is stored as a landscape
    /// buffer plus a 90° `preferredTransform`, and `AVAssetExportSession` carries that transform
    /// through rather than baking it, unless a `videoComposition` forces a re-render. So our own
    /// clips are split: anything that went through the gradient canvas or the editor's burn-in is
    /// baked and upright, and everything on the fast path is stored sideways. That is the "sometimes".
    ///
    /// `AVPlayerLayer` applies the transform for playback, which is why the story itself always looks
    /// right. `AVPlayerItemVideoOutput.copyPixelBuffer` does NOT — it hands over the raw decoded
    /// buffer. The other cover path already gets this right (`coverFromFirstFrame` sets
    /// `appliesPreferredTrackTransform`), so the two disagreed and only one of them was ever wrong.
    private var frameOrientation: UIImage.Orientation = .up

    private func attachFrameOutput() {
        guard let item = player?.currentItem else { return }
        // A new item means the old output belongs to a video that is no longer playing.
        if let old = frameOutput, item.outputs.contains(old) { return }
        // ⚠️ AND THE OLD ONE COMES OFF THE OLD ITEM. This only ever added. An attached
        // `AVPlayerItemVideoOutput` makes the pipeline vend a pixel buffer for every frame it
        // decodes, and we read one at a pause and nowhere else — so every story watched left another
        // clip paying that cost for as long as its item survived. Removing it is one line and it is
        // the difference between a per-view cost and a per-session one.
        if let old = frameOutput, let previous = frameOutputItem, previous !== item {
            previous.remove(old)
        }
        let out = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        item.add(out)
        frameOutput = out
        frameOutputItem = item
        // The rotation is asked for ONCE per item, off the main thread, and `.up` stands until the
        // answer lands. `.up` is also the right answer for every clip whose transform is baked, so a
        // slow load costs nothing on the common path.
        frameOrientation = .up
        loadFrameOrientation(for: item)
    }

    /// Reads the video track's `preferredTransform` and stores it as a `UIImage.Orientation`.
    ///
    /// Deliberately NOT applied to the `CIImage` directly: Core Image works bottom-left, the
    /// transform is written for a top-left space, and a rotation composed across that flip comes out
    /// turned the wrong way. `UIImage.Orientation` has no such ambiguity — UIKit applies it when the
    /// image is drawn, and every consumer of this frame draws it (`UIImageView`, `draw(in:)`).
    private func loadFrameOrientation(for item: AVPlayerItem) {
        guard #available(iOS 16.0, *) else { return }
        let asset = item.asset
        Task { [weak self] in
            guard let track = try? await asset.loadTracks(withMediaType: .video).first,
                  let t = try? await track.load(.preferredTransform) else { return }
            let o: UIImage.Orientation
            switch (t.a, t.b, t.c, t.d) {
            case (0, 1, -1, 0):   o = .right      // portrait recorded on a landscape sensor
            case (0, -1, 1, 0):   o = .left
            case (-1, 0, 0, -1):  o = .down
            default:              o = .up         // identity, or something we should not guess at
            }
            await MainActor.run { [weak self] in
                // Still the same item: a swap while this was loading must not re-turn the new clip.
                guard let self, self.frameOutputItem === item else { return }
                self.frameOrientation = o
            }
        }
    }

    /// The frame on screen right now, or the last frame this clip actually rendered, or nil.
    ///
    /// THE SECOND ANSWER IS WHY THE FROZEN COVER STOPPED RESETTING TO SECOND ZERO. His 2026-08-09
    /// report: watch a video to 10s, pull the sheet, swipe the carousel away and back — the card
    /// wore the FIRST frame. The story is paused under the sheet, and a paused item's video output
    /// hands its buffer over ONCE: the pause path (`rememberPlaybackFrame`) reads it into
    /// `StoryPlaybackResume.rememberFrame`, so when `snapshotCard` asks a beat later for the SAME
    /// time there is no new buffer, this answered nil, and the caller fell back to the poster —
    /// which is second zero by construction. The remembered frame IS the 10s picture, decoded from
    /// this very output, so answering with it keeps every promise the buffer path makes: real clip
    /// pixels, never chrome, never a black rectangle.
    ///
    /// Nil still means nil when this clip has never rendered anything — the callers' own fallbacks
    /// (the poster) remain the right answer there.
    /// The clip this view is currently pointed at — the subject of `currentVideoFrame`. See the
    /// protocol note: without it a snapshot is an answer with no question attached.
    var currentVideoURL: String? { self.url?.absoluteString }

    /// Where this clip is, for callers deciding whether the frame is worth keeping. A player with no
    /// item answers 0 rather than pretending — see `bankCurrentState`, which treats anything under a
    /// second as "not worth overwriting the bank with", exactly as `rememberPlaybackFrame` does.
    var currentVideoSeconds: Double {
        guard let p = player, p.currentItem != nil else { return 0 }
        let t = p.currentTime().seconds
        return t.isFinite ? t : 0
    }

    /// WRITE THE FRAME DOWN NOW, because whoever is asking is about to freeze this player or take
    /// it away — see `StoryVideoFrameSource.rememberPlaybackState`. The frame ONLY: there is no
    /// stored playback position any more (a story always restarts at zero — the owner's 2026-08-11
    /// rule and Telegram's behaviour), so what travels across a teardown is the picture the cards
    /// draw, never a seek target.
    ///
    /// Two callers, and neither of them can reach the guards or should have to know them:
    /// `StoryCardMorph.bankCurrentState` at the sheet's pause, and `StoryDetailView.resetAVPlayer`
    /// when a photo story replaces the whole `AVPlayer`.
    ///
    /// ⚠️ It lives in the class body and not in the private extension below with the function it
    /// calls: a `private extension` member cannot satisfy a public protocol requirement.
    func rememberPlaybackState() { rememberPlaybackFrame() }

    func currentVideoFrame() -> UIImage? {
        if let item = player?.currentItem, let out = frameOutput,
           let buffer = out.copyPixelBuffer(forItemTime: item.currentTime(), itemTimeForDisplay: nil) {
            let ci = CIImage(cvPixelBuffer: buffer)
            if let cg = frameContext.createCGImage(ci, from: ci.extent) {
                // TURNED THE WAY THE CLIP IS MEANT TO BE SEEN — see `frameOrientation`. The layer
                // does this for playback; the pixel buffer arrives raw.
                return UIImage(cgImage: cg, scale: 1, orientation: frameOrientation)
            }
        }
        guard let url = self.url else { return nil }
        return StoryPlaybackResume.frame(url)
    }

    /// Hand over the clip's cover before `startVideo`, so the loading state has a picture to show.
    /// Reads the caches the prefetcher and the image loader already fill, and only fetches if both
    /// miss — the poster is a few KB and is usually already on disk from the story row.
    func setPoster(_ urlString: String?) {
        guard posterURL != urlString else { return }
        posterURL = urlString
        posterImage = nil
        // A DIFFERENT CLIP, so the canvas has to be read again. This view is reused across stories,
        // and without this the second clip would wear the first one's colours — the video half of
        // the same bug audit finding C1 caught on the photo half. Layer reset too, same reason as
        // `startVideo`'s: the flag alone left the old gradient painted through the new clip's load.
        canvasSourced = false
        StoryCanvas.apply(StoryCanvas.neutral, to: canvasLayer)
        guard let urlString, let u = URL(string: urlString) else { return }
        // A POSTER IS A PICTURE. A video url arriving here (the empty-thumb window used to hand the
        // mp4 through `previewUrl`) read megabytes off disk on the main thread at the disk-cache
        // line below and then DOWNLOADED THE WHOLE CLIP a second time in the dataTask — in parallel
        // with the player's own fetch — to decode nothing. Refuse it outright; no poster beats that.
        guard !["mp4", "mov", "m4v"].contains(u.pathExtension.lowercased()) else { return }
        // THE APP'S OWN CACHE FIRST, and that is the black blink. The two caches below are StoryUI's;
        // the app draws the row and the carousel through a different one and warms THAT. For a story
        // just posted, or one whose cover came down for the row rather than for the viewer, both of
        // these miss and the cover becomes a network fetch — leaving the hide-until-ready rule above
        // with nothing to hide behind. See `StoryPosterSource`.
        if let img = StoryPosterSource.provider?(urlString) { posterImage = img; refreshBackdrop(); return }
        if let cached = URLCache.shared.cachedResponse(for: .init(url: u)),
           let img = UIImage(data: cached.data) { posterImage = img; refreshBackdrop(); return }
        if let disk = StoryDiskCache.image(u) { posterImage = disk; refreshBackdrop(); return }
        URLSession.shared.dataTask(with: u) { [weak self] data, _, _ in
            guard let data, let img = UIImage(data: data) else { return }
            StoryDiskCache.store(data, for: u)
            DispatchQueue.main.async {
                // Still the same clip, and still loading — otherwise this would drop a poster on top
                // of a video that has already started.
                guard let self, self.posterURL == urlString else { return }
                self.posterImage = img
                self.refreshBackdrop()   // the poster IS the backdrop; build it the moment it lands
                // Rebuilt WITH THE ANSWER IT HAD — a poster landing late must not promote a cached
                // clip's quiet cover back into a "loading" one.
                if self.viewWithTag(999) != nil { self.addActivityIndicatory(spinning: self.veilHasSpinner) }
            }
        }.resume()
    }

    func startVideo(url: URL?) {
        guard let validatedUrl = url else { return }
        if self.url == url { return }
        // The story this view is LEAVING banks its last picture for the cards — and ONLY the
        // picture. Its position deliberately dies with this navigation: a story moved away from is
        // PASSED, and a passed story restarts from zero on its next visit (the owner's 2026-08-11
        // rule; Telegram removes the item's whole player on navigation and a revisit seeks to 0).
        // Here as well as in `stopVideo`, because a paused player (the sheet pauses, it does not
        // stop) reaches this point with its frame unbanked and `stopVideo`'s guard never fires.
        rememberPlaybackFrame()
        // The old clip's clock and end-report go with it: the bar must never read the previous
        // story's player across the load gap, and a stale clip's end must never advance this one.
        if let p = player { StoryPlaybackClock.detach(p) }
        if let tok = endObservationToken {
            NotificationCenter.default.removeObserver(tok)
            endObservationToken = nil
        }
        // ⚠️ STOP THE OLD CLIP WHILE `self.url` STILL NAMES IT. `stopVideo` remembers the playhead
        // and the frame too, and it keys them by `self.url` — with the stop AFTER the line below,
        // it wrote clip A's picture and position under clip B's address. That poisoned entry then
        // painted A's frame, sharp and full-card, behind every rebuild of B's veil, and seeked B to
        // A's timestamp: his 2026-08-09 "i see flash cover… like i see again story a but u stay
        // story b". Only when A had played past its first second (the remember guard), which is
        // why it read as sometimes.
        stopVideo()
        self.url = validatedUrl
        // Belt for `setPoster`'s braces: two clips that both arrive with no poster never move
        // `posterURL`, so its reset would not fire and clip B would keep clip A's canvas.
        canvasSourced = false
        // AND THE LAYER ITSELF GOES NEUTRAL, not just the flag: resetting `canvasSourced` alone
        // left A's gradient painted for the whole of B's load — the warm bands behind his spinner.
        StoryCanvas.apply(StoryCanvas.neutral, to: canvasLayer)
        // A NEW CLIP HAS NO FRAME AND NO KNOWN SHAPE, and it goes back under cover until it has both.
        // Hiding here as well as at init is what makes this hold for the SECOND video in a row: this
        // view is reused, so without it clip B would be shown by clip A's reveal.
        presentedSize = .zero
        // AND THERE IS NOTHING TO REVEAL UNTIL THE NEW ITEM IS ATTACHED. Without this the old clip
        // would answer the reveal's questions for as long as the cache takes to reply.
        awaitedItem = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.isHidden = true
        CATransaction.commit()
        // A CLIP THAT IS ON DISK IS NOT LOADING, so its veil is a cover without a wheel — see
        // `addActivityIndicatory`. Asked here, synchronously, because by the time the cache
        // answers `loadVideo` the veil has already been up for the whole question.
        // ⚠️ AND THE COLOURS COME STRAIGHT BACK. The reset two lines up is right — clip B must not
        // wear clip A's gradient — but it was the LAST word on the canvas for the whole of B's load,
        // so the backdrop sat at its neutral near-black even when B's cover was already in hand.
        // `setPoster` and `setBlurThumb` both run BEFORE this (see `VideoView.updateUIView`) and both
        // call `refreshBackdrop`, and this line was quietly undoing them. It matters most for the
        // cover that is drawn `.scaleAspectFit`: without it the bars are black under the still and
        // then change colour the instant the clip appears.
        refreshBackdrop()
        let cachedFile = CacheManager.cachedFileIfUsable(for: validatedUrl)
        addActivityIndicatory(spinning: cachedFile == nil)
        // A CACHED CLIP CAN BE ITS OWN POSTER. A video with no thumbnail (the empty-thumb upload
        // window, older stories) reaches here with nothing to cover with — the spinner over a bare
        // gradient in his screenshot. Telegram decodes the cached file's first frame and shows THAT
        // (`CachedVideoFirstFrameRepresentation`); ours lands in the remembered-frame slot, which
        // the veil already draws SHARP at the clip's own gravity — it is pixel-for-pixel the frame
        // the reveal will hand over to, the same promise that slot has always kept.
        if posterImage == nil, StoryPlaybackResume.usableCoverFrame(validatedUrl) == nil, let file = cachedFile {
            coverFromFirstFrame(of: file, for: validatedUrl)
        }
        // (the stop happens ABOVE, before `self.url` moves — see the warning there)
        didRetryRemote = false
        cachedFileInUse = nil
        // ⚠️ A NEW CLIP GETS TO ANNOUNCE ITSELF AGAIN. `setBuffering` only posts on a CHANGE, so
        // once this view has said "not buffering" it will never say it again until it has said the
        // opposite — and if that `false` was posted while the host page was already being swiped
        // away, nobody was listening and the host's flag stayed up for good. Re-arming per clip
        // means the edge is per clip, which is the only scope it was ever meaningful at.
        didReportBuffering = false
        cacheManager.loadVideo(from: validatedUrl) { [weak self] result in
            // STALE ANSWER GUARD. This view is reused across stories, so a download started for the
            // last one can land after the next one has claimed it — and it would then set up the
            // wrong video and take the spinner down over it.
            guard let self, self.url == validatedUrl else { return }
            switch result {
            case .success(let fileUrl):
                self.cachedFileInUse = fileUrl
                self.setupPlayer(fileUrl)
            case .failure(let error):
                // Never leave the viewer on an eternal spinner: AVPlayer streams https mp4s
                // fine, so a cache failure falls back to playing the remote URL directly.
                print(error)
                self.didRetryRemote = true
                self.setupPlayer(validatedUrl)
            }
        }
    }

    /// The cached clip's opening frame, decoded off-main and delivered into the remembered-frame
    /// slot — where the veil, the canvas sampler and `currentVideoFrame`'s fallback all already
    /// look. One seam, three readers, no new drawing path. Guarded at the landing: still this
    /// clip, still under cover, and no usable cover has appeared meanwhile. Playback always starts
    /// at zero now, so second zero is exactly the honest cover — banked with `at: 0` so
    /// `usableCoverFrame` will hand it back.
    private func coverFromFirstFrame(of file: URL, for story: URL) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: file))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 1080, height: 1920)
            guard let cg = try? generator.copyCGImage(at: .zero, actualTime: nil) else { return }
            let image = UIImage(cgImage: cg)
            DispatchQueue.main.async {
                guard let self, self.url == story, self.playerLayer.isHidden,
                      StoryPlaybackResume.usableCoverFrame(story) == nil else { return }
                StoryPlaybackResume.rememberFrame(story, image: image, at: 0)
                self.refreshBackdrop()   // the frame is also the canvas's colour source
                if self.viewWithTag(999) != nil { self.addActivityIndicatory(spinning: self.veilHasSpinner) }
            }
        }
    }

    /// THE ONLY WAY OUT OF THE SPINNER USED TO BE PLAYBACK STARTING.
    ///
    /// So anything that stopped the item from ever playing — a truncated cache file, an object that
    /// is not there yet, a URL that 404s — left the wheel turning for as long as you cared to look
    /// at it, with no retry and no message (owner 2026-08-04: "when i upload video is loading never
    /// play"). An item that fails now says so, and this answers it.
    private func handleFailedItem() {
        // A half-written cache file is the worst case, because it is PERMANENT: it exists, so every
        // future open finds it and never downloads again. Throw it away and stream instead.
        if let bad = cachedFileInUse {
            cachedFileInUse = nil
            try? FileManager.default.removeItem(at: bad)
            if let remote = url, !didRetryRemote {
                didRetryRemote = true
                setupPlayer(remote)
                player?.play()
                return
            }
        }
        // Streaming failed too, so there is nothing left to try. Stop claiming it is loading — an
        // endless spinner is not honest.
        //
        // ⚠️ BUT KEEP THE COVER. This called `removeActivityIndicatory()`, which takes down the
        // WHOLE veil — and the veil is what was carrying the clip's poster. Behind it is the view's
        // own black, so a story whose video could not play went from showing its cover to showing a
        // solid black rectangle for its full duration, with the layer still hidden and nothing left
        // to reveal. Rebuilding the veil without a spinner leaves the picture up and only drops the
        // claim that something is still coming, which is the true statement here.
        addActivityIndicatory(spinning: false)
    }

}

//MARK: - Configure

private extension PlayerView {
    func setupPlayer(_ url: URL) {
        // Stories are sound-on media: .playback plays through the ringer
        // switch. The default (.soloAmbient) muted every story video on a silenced phone.
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        // The reveal must not trust anything read in THIS turn — see revealVideoIfReady. The hop
        // that lifts the flag re-asks the reveal, so a preloaded clip is shown one turn later at
        // the very worst; the isReadyForDisplay KVO carries every later re-ask.
        itemSwapSettling = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.itemSwapSettling = false
            self.revealVideoIfReady()
        }
        self.player?.replaceCurrentItem(with: nil)
        // AN ITEM PREPARED WHILE YOU WERE WATCHING THE STORY BEFORE, if there is one. It has already
        // had its tracks loaded and its first frames decoded, so it starts on the frame rather than
        // on a beat of nothing. See StoryItemPreloader.
        let item = StoryItemPreloader.take(url) ?? AVPlayerItem(url: url)
        self.player?.replaceCurrentItem(with: item)
        // THE CLIP THE COVER IS WAITING FOR. Until this line there was no item to be ready, and
        // `revealVideoIfReady` refuses on that — see its note on the previous clip's readiness.
        awaitedItem = item
        // The frame output belongs to the NEW clip from the first moment anything can ask for a
        // picture — attached down at the bottom of this function, it still belonged to the OLD
        // clip while the `.initial` observations above it were already firing.
        attachFrameOutput()
        // NO RESUME SEEK, ON PURPOSE. A block here used to seek to the story's remembered position,
        // which is how a returned-to clip played from 0:14 under a bar that had just started at
        // zero. The owner's 2026-08-11 rule is Telegram's: a story navigated back to RESTARTS from
        // its beginning, always. Their revisit builds a fresh player and seeks it straight to 0
        // (`ownsContentNodeUpdated` in StoryItemContentComponent), and no per-item position is
        // stored anywhere in their story code. A fresh item starts at zero by construction, so
        // there is nothing to do here — and the veil above is already a second-zero picture
        // (`usableCoverFrame`), so the hand-over matches.
        //
        // THE CLOCK: from this moment the player's time speaks for THIS story and the progress bar
        // may read it — see StoryPlaybackClock. Before this line the player still held the previous
        // clip, which is exactly why the bar refuses to read an unattached player.
        if let story = self.url, let p = self.player {
            StoryPlaybackClock.attach(story, to: p)
        }
        // THE END OF A CLIP IS THE PLAYER'S TO REPORT — Telegram's `videoNode.playbackCompleted` is
        // the only thing that advances a video story there, never progress arithmetic, and
        // `.storyVideoFinished` is ours. Scoped to this exact item and re-checked against the
        // current item when it fires, so a stale clip finishing mid-swap can never complete
        // somebody else's segment.
        if let tok = endObservationToken { NotificationCenter.default.removeObserver(tok) }
        endObservationToken = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self, weak item] _ in
            guard let self, let item, let story = self.url,
                  self.player?.currentItem === item else { return }
            NotificationCenter.default.post(name: .storyVideoFinished, object: nil,
                                            userInfo: ["url": story.absoluteString])
        }

        observation = player?.observe(\.timeControlStatus, options: [.new, .initial]) { [weak self] player, change in
            guard let self else { return }
            switch player.timeControlStatus {
            case .playing:
                // ⚠️ THIS NO LONGER UNCOVERS THE CLIP, because playing is not the same as having a
                // picture — it was the premature reveal that let the black through. The first reveal
                // belongs to `revealVideoIfReady` alone.
                //
                // It still takes the cover down when the clip is ALREADY on screen, and that case is
                // not cosmetic: `.waitingToPlayAtSpecifiedRate` puts the cover back up mid-story for
                // a stall, and this is the only thing that ever takes it down again.
                if !self.playerLayer.isHidden { self.removeActivityIndicatory() }
                self.setBuffering(false)
                self.state = .started
                self.mediaState?(self.state, self.duration)
            case .waitingToPlayAtSpecifiedRate:
                // GENUINELY WAITING ON BYTES, so the progress bar must wait too. Without this the
                // segment kept counting through a stall and the story moved on while the video was
                // still trying to start — the progress desynchronisation.
                //
                // ⚠️ AND THE VEIL IS NOT REBUILT OVER A PICTURE THAT IS ALREADY ON SCREEN. THIS IS
                // HIS 0-SECOND FLASH, and he bisected it to build 514.
                //
                // A veil is a COVER: it draws the poster, or the remembered frame. For a video both
                // of those are second zero. Putting one up over a clip that is visibly playing at
                // ten seconds does not indicate loading, it REPLACES the picture with the start of
                // the clip. `99ab7d18` narrowed this to "only with the picture up", which is the
                // half that is visible, and `coverFromFirstFrame` in the same build gave that cover
                // a real decoded frame-zero image where it used to be a bare gradient — which is
                // why 514 is exactly where he started seeing "the 0-second frame".
                //
                // It stranded, too, and that is the swipe-up half of his report. A streaming clip
                // dips in and out of this state through its first seconds; only `.playing` took the
                // cover down, and pulling the sheet up pauses the story — so `.playing` never came
                // back, and the frame-zero cover stayed up. **Only while playing, only in the first
                // seconds, and never if he long-pressed to pause first**, which is his report word
                // for word.
                //
                // Telegram's stall indicator is an OVERLAY on the running picture, never a
                // replacement, and they exclude initial buffering from it outright. The bar hold
                // below is the honest part of this and it stays: waiting on bytes is waiting.
                self.setBuffering(true)
            case .paused:
                // ⚠️ A DELIBERATE PAUSE IS NOT A STALL, AND IT MUST CLEAR ONE. Belt for any cover
                // raised by a stall an instant before playback was stopped: `.playing` is the only
                // other thing that takes a veil down, and a pause means it is not coming. Without
                // this, a clip stalled at the exact moment the sheet pull pauses it keeps its cover
                // for the rest of the session. Guarded on the layer being visible, because a veil
                // over a HIDDEN layer is the real load and taking it down would show black.
                if !self.playerLayer.isHidden { self.removeActivityIndicatory() }
                self.setBuffering(false)
            default:
                self.setBuffering(false)
            }
        }

        // An item that cannot be played reports it HERE and nowhere else — timeControlStatus simply
        // never reaches .playing, which is silence, not an answer.
        // `.initial` too: an item that is already failed when we start watching would otherwise
        // never send a change, and never sending one is the bug.
        statusObservation = player?.currentItem?.observe(\.status, options: [.new, .initial]) { [weak self] item, _ in
            guard let self else { return }
            if item.status == .failed {
                DispatchQueue.main.async { self.handleFailedItem() }
                return
            }
            // PREROLL BELONGS HERE, AND NOWHERE EARLIER. This is the fix for the build 462 crash.
            //
            // `AVPlayer.preroll(atRate:completionHandler:)` RAISES AN OBJECTIVE-C EXCEPTION if the
            // player has no current item ready — and an Objective-C exception in Swift is not
            // catchable, it goes straight to `abort()`. I called it immediately after
            // `replaceCurrentItem`, which is exactly the moment the item is NOT ready yet, so the
            // first story video played on a device with any latency at all killed the app.
            // Symbolicated frame 10 of his report: `-[AVPlayer prerollAtRate:completionHandler:]`
            // → objc_exception_throw → abort.
            //
            // `.readyToPlay` is the state the documentation requires and the only one that is safe.
            guard item.status == .readyToPlay else { return }
            DispatchQueue.main.async {
                guard self.url == url || self.cachedFileInUse == url else { return }   // reused meanwhile
                guard self.player?.currentItem === item else { return }                // item swapped meanwhile
                // PREROLL DECODES; IT DOES NOT DISPLAY. Its completion used to take the cover down,
                // which is a second premature reveal — a filled render pipeline is not a frame on the
                // layer. It is still worth calling, because it is what brings `isReadyForDisplay`
                // forward, and that is now the only thing that uncovers anything.
                self.player?.preroll(atRate: 1) { _ in }
            }
        }

        // LET AVFOUNDATION WAIT. This was forced to `false`, which tells the player to start the
        // instant it is asked whether or not a single frame is buffered — so on anything less than a
        // good connection a story began by stuttering, which is precisely the complaint. The default
        // behaviour is to hold until it can play through, and holding for a moment on a picture beats
        // starting on a stutter.
        self.player?.automaticallyWaitsToMinimizeStalling = true
        // The preroll that used to be here is in the status observer above. Calling it at this point
        // is what crashed build 462: the item is not ready yet, and preroll raises an Objective-C
        // exception rather than returning an error. Do not move it back.
        self.getVideoLength(videoURL: url)
        self.playerLayer.player = self.player
        self.playerLayer.videoGravity = .resizeAspectFill
        // Fill vs fit decided by aspect, like photos (ImageLoader.decideContentMode): a landscape/
        // wide video hard-cropped by an unconditional fill lost most of its frame — FIT those
        // (black bars), keep tall videos edge-to-edge. The decision itself lives in
        // `applyGravity`, measured against the view's own bounds (the card), NOT UIScreen, and is
        // applied synchronously when the size is already known — a preloaded item answers on the
        // `.initial` delivery, so the first painted frame is already at its final scale.
        sizeObservation = player?.currentItem?.observe(\.presentationSize, options: [.new, .initial]) { [weak self] item, _ in
            let s = item.presentationSize
            guard let self, s.width > 0, s.height > 0 else { return }
            if Thread.isMainThread { self.notePresentationSize(s) }
            else { DispatchQueue.main.async { self.notePresentationSize(s) } }
        }
        // The frame output was attached right after the item swap, where it belongs to the new
        // clip before any observation can fire. (attachFrameOutput is idempotent.)
        StoryCardMorph.shared.frameSource = self
        // CLEAR, not black: the backdrop lives behind this layer and a black fill would cover it.
        // The view's own backgroundColor still guarantees nothing shows through when there is no
        // poster to blur.
        self.playerLayer.backgroundColor = UIColor.clear.cgColor
        playerLayer.removeFromSuperlayer()
        self.contentView.layer.addSublayer(self.playerLayer)
        state = .ready
        mediaState?(.ready, duration)
        addObserverToVideo()
    }

    /// A SYNCHRONOUS `AVURLAsset.duration` ON THE MAIN THREAD, which is what this was.
    ///
    /// That property blocks until the asset has parsed enough of the container to answer, and it was
    /// being read from `setupPlayer` on the main thread every time a story opened. On a local cache
    /// file that is a short stall; on the fallback path, where the url is remote, it is a network
    /// round trip with the whole UI stopped behind it.
    ///
    /// It is loaded asynchronously now and reported when it arrives. Nothing needs it in the same
    /// turn: the progress bar starts from the story's declared duration and refines to the real one,
    /// which is what `mediaState` already existed to do.
    func getVideoLength(videoURL: URL) {
        let asset = AVURLAsset(url: videoURL)
        Task { [weak self] in
            guard let seconds = try? await asset.load(.duration).seconds, seconds.isFinite, seconds > 0
            else { return }
            await MainActor.run {
                guard let self, self.url == videoURL || self.cachedFileInUse == videoURL else { return }
                self.duration = seconds
                self.mediaState?(self.state, seconds)
            }
        }
    }

    func stopAndRestartVideo() {
        player?.seek(to: .zero)
    }

    func stopVideo() {
        // ⚠️ A CLIP THAT HAS NOT STARTED YET STILL HAS TO BE STOPPED, and asking only for `.playing`
        // is what let it keep going.
        //
        // A player that is spinning up reports `.waitingToPlayAtSpecifiedRate`, not `.playing`. So
        // every `.stopVideo` on a page change was a no-op against a clip that was still loading, its
        // rate stayed non-zero, and when the bytes finally arrived it began playing OFF SCREEN: you
        // hear the story you swiped away from over the one you are looking at.
        //
        // The frozen bar is the same bug's other half. That page had already announced
        // `storyBuffering = true` while it was current; its matching `false` now arrives after the
        // swipe, where the host drops it as belonging to somebody else — and `didReportBuffering` is
        // only re-armed by a NEW clip, so returning to that person leaves the bar held for good.
        //
        // `pause()` on an idle player is harmless, and the guards inside `rememberPlaybackFrame`
        // already refuse to bank a frame for a clip that never reached its second second — so
        // widening this cannot invent a card picture for a story nobody watched.
        guard player?.timeControlStatus != .paused || state != .stopped else { return }
        // ⚠️ THE REWIND KEEPS THE OLD CONDITION, AND ONLY THE REWIND.
        //
        // Widening this function so a BUFFERING clip can be stopped was right — that is the audio
        // that kept playing from a story you swiped away from. But the function ends by seeking to
        // zero, and before the widening a PAUSED player left early and was never seeked. Now it
        // reaches that line, and the sheet pull pauses the story by design: pulling up on a clip
        // three seconds in would rewind it to zero and put frame zero on the card. His "the first
        // frame flashes for a split second" is exactly that shape, and it would have been a new
        // bug in the build this went out on.
        //
        // So the pause and the remembering are unconditional, which is the fix, and the REWIND
        // stays behind the condition it always had. A clip that was genuinely playing and is being
        // left behind still rewinds; a paused one is left exactly where the person stopped it.
        let wasPlaying = player?.timeControlStatus == .playing
        // BEFORE the seek, which rewinds the very picture being kept. `.stopVideo` fires on a
        // person swipe (and on the close, where the door clears the whole store anyway), and
        // this is the last moment the mid-clip frame is still on the layer on that path.
        rememberPlaybackFrame()
        player?.pause()
        if wasPlaying { player?.seek(to: .zero) }
        state = .stopped
    }

    /// The last picture this clip showed, banked for the cards — and NOTHING else. The playback
    /// position used to be written here too, so the next player built for this url could resume it;
    /// that is gone, deliberately: a story always restarts at zero now (the owner's 2026-08-11
    /// rule, and Telegram's behaviour), so a stored position had exactly one power left — to
    /// disagree with the progress bar. The middle-of-the-clip guard stays: the first second is
    /// second zero in all but name (the poster already shows it), and the last second is the
    /// natural end the auto-advance already owns.
    private func rememberPlaybackFrame() {
        guard let story = self.url, let p = player, p.currentItem != nil else { return }
        let t = p.currentTime().seconds
        guard t.isFinite, t > 1, duration <= 0 || t < duration - 1 else { return }
        // `currentVideoFrame` reads the player's own display output; nil is a normal answer and
        // simply leaves the poster in charge, as before. Banked WITH its clip-second, so the veil
        // can tell an honest second-zero cover from a mid-clip card picture (`usableCoverFrame`).
        StoryPlaybackResume.rememberFrame(story, image: currentVideoFrame(), at: t)
    }

    func restartVideo() {
        if player?.timeControlStatus == .paused {
            player?.seek(to: .zero)
            player?.play()
            state = .restart
        }
    }

    func addObserverToVideo() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(restartVideoObserver),
            name: .restartVideo,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(stopVideoObserver),
            name: .stopVideo,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(stopAndRestartVideoObserver),
            name: .stopAndRestartVideo,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(replaceCurrentItemObserver),
            name: .replaceCurrentItem,
            object: nil
        )
        // A `captureStoryFrame` observer lived here. It decoded the frame at the current playback
        // time into `StoryCompositeCache` so the card behind the viewers sheet could show where the
        // video actually was. Nothing decodes anything now: the card behind the sheet IS this
        // player's own layer, paused in place, so the frame it is on is already on screen. See
        // StoryCardMorph.
    }

    @objc
    func stopAndRestartVideoObserver() {
        stopAndRestartVideo()
    }

    @objc
    func restartVideoObserver() {
        restartVideo()
    }

    @objc
    func stopVideoObserver() {
        stopVideo()
    }

    @objc
    func replaceCurrentItemObserver() {
        self.player?.replaceCurrentItem(with: nil)
        self.observation = nil
        self.sizeObservation = nil
        self.player = nil
    }
}

// MARK: - Setup Func

private extension PlayerView {
    /// THE LOADING STATE FOR A VIDEO WAS A SOLID BLACK VIEW OVER THE WHOLE SCREEN, and that is the
    /// black screen the owner keeps seeing. It went up on EVERY `startVideo`, before anything had
    /// even been asked for.
    ///
    /// It is the clip's own poster behind glass now, the same treatment a photo story already gets
    /// while it downloads, so a video opens on a picture of itself rather than on a hole. The spinner
    /// stays on top of it, because a video genuinely can take a moment and something has to say so —
    /// but it turns over the picture instead of over nothing. Black is only the fallback for a clip
    /// whose poster we have not got.
    ///
    /// `frozenVeil` lived here and is now `StoryCanvas.loadingVeil` — the same function, the same
    /// numbers, in the one file that owns everything drawn behind or over a story, so the photo half
    /// and the video half cannot drift apart in how a loading story looks.
    /// `spinning`: whether the wheel itself goes up. THE SPINNER IS FOR FETCHING, NOT FOR EXISTING.
    /// Telegram's loading shimmer is keyed on whether the bytes are on disk ("contentLoaded"), never
    /// on player readiness, so a cached story there never shows a loading state — his "already i
    /// downloaded but still is loading". The veil goes up either way: it is the cover the
    /// born-hidden layer reveals out of. Only the claim of loading is now reserved for actual
    /// loading. And the wheel appears 0.2s late (Telegram's appearance timer), so a fast network
    /// never flashes one for a story that arrives immediately.
    func addActivityIndicatory(spinning: Bool = true) {
        removeActivityIndicatory()
        veilHasSpinner = spinning
        // THE VIEW'S OWN SIZE, not UIScreen's — the veil must cover exactly the card the video
        // will paint in, or the two show the same picture at two different scales.
        let w = bounds.width > 1 ? bounds.width : UIScreen.main.bounds.width
        let h = bounds.height > 1 ? bounds.height : UIScreen.main.bounds.height
        let view = UIView(frame: CGRect(x: 0, y: 0, width: w, height: h))
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        // CLEAR, not black. This veil sits ON TOP of everything while the clip loads, so an opaque
        // black one hides the blurred backdrop underneath it for as long as it is up — and it is
        // only taken down when the player reports `.playing`. The poster image it carries already
        // covers the card; the black behind that was belt on top of braces and it was the belt that
        // showed.
        view.backgroundColor = .clear
        view.tag = 999
        // ⚠️ ONE BRANCH, TWO TREATMENTS — see `cover`. A REAL FRAME of this clip goes up AS IT IS,
        // at the gravity the video itself will use, so the hand-over to the live layer is invisible:
        // the same picture, the same size, in the same place. Only the 30px embedded thumbnail is
        // blurred, because at card size that is the only honest thing to do with it.
        //
        // Two frames qualify, for two different reasons. The one he LEFT ON (`StoryPlaybackResume`)
        // is not a loading state at all: the clip is going to reappear at 10s, and covering that with
        // a picture of second zero — sharp or blurred — is the bug where the position resumed and the
        // picture did not. And `thumb.jpg` is a full-size photograph of this clip's own opening
        // frame, so it is the first frame, a beat early. Blurring THAT is what he photographed and
        // called "full blur screen": the cover was there and correct, and we were smearing it.
        if let cover = cover {
            let iv = UIImageView(image: cover.isFrame
                                 ? cover.image
                                 : StoryCanvas.loadingVeil(of: cover.image, covering: view.bounds.size))
            iv.frame = view.bounds
            // The same question `applyGravity` asks, through the same function, so the still and the
            // clip that replaces it cannot be framed two different ways. The blurred thumbnail always
            // fills: it has no detail to crop and the canvas behind it owns the bars either way.
            iv.contentMode = cover.isFrame
                ? (StoryCanvas.fills(media: cover.image.size, in: view.bounds.size)
                   ? .scaleAspectFill : .scaleAspectFit)
                : .scaleAspectFill
            iv.clipsToBounds = true
            iv.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(iv)
        }
        self.addSubview(view)
        guard spinning else { return }
        let activityView = UIActivityIndicatorView(style: .large)
        activityView.color = UIColor.lightGray.withAlphaComponent(0.7)
        activityView.frame = CGRect(x: w / 2, y: h / 2, width: .zero, height: .zero)
        view.addSubview(activityView)
        addConst(view: activityView)
        activityView.startAnimating()
        // Invisible for its first 0.2s. A reveal that lands inside that window — the normal case
        // for anything local or preloaded — never shows a wheel at all. The guard asks whether the
        // VEIL this wheel belongs to is still on the card (its superview's superview): a veil that
        // was torn down keeps its wheel dark, a NEW veil built meanwhile owns a wheel of its own,
        // and a page pre-built offscreen — where `window` would answer nil — still gets its wheel
        // the moment it is looked at.
        activityView.alpha = 0
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak activityView] in
            guard let activityView, activityView.superview?.superview != nil else { return }
            activityView.alpha = 1
        }
    }

    func setupPlayer() {
        backgroundColor = .black
        canvasLayer.isHidden = true        // shown only once a clip is known not to fill the card
        // HIDDEN UNTIL IT HAS A PICTURE — Telegram's `videoNode.isHidden = true` at construction.
        // A layer with no decoded frame paints its background, and that is the black he photographed.
        playerLayer.isHidden = true
        // The one thing that ever takes it back off. Observed on the LAYER, which owns the answer,
        // and once for the life of this view — the layer outlives every item put through it.
        readyObservation = playerLayer.observe(\.isReadyForDisplay, options: [.new]) { [weak self] _, _ in
            guard let self else { return }
            if Thread.isMainThread { self.revealVideoIfReady() }
            else { DispatchQueue.main.async { self.revealVideoIfReady() } }
        }
        self.layer.addSublayer(canvasLayer)   // behind everything
        self.addSubview(contentView)
        // layoutSubviews owns this geometry now (see its note) — the one-shot frame here only
        // covers the beat before the first layout pass. The old Auto Layout pins are gone: they
        // fought contentView's autoresizing constraints (its TAMIC was never turned off), and
        // their safe-area bottom was a full-screen assumption the 9:16 card broke.
        contentView.frame = bounds
        playerLayer.frame = bounds
    }

    func removeActivityIndicatory() {
        self.subviews.forEach { (view) in
            if view.tag == 999 {
                view.removeFromSuperview()
            }
        }
    }

    func addConst(view: UIActivityIndicatorView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.centerXAnchor.constraint(equalTo: view.superview!.centerXAnchor),
            view.centerYAnchor.constraint(equalTo: view.superview!.centerYAnchor)
        ])
    }
}
