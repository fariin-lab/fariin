//
//  StoryItemVideoView.swift
//  StoryUI
//
//  ONE STORY ITEM'S VIDEO, WITH ITS OWN PLAYER.
//
//  ⚠️ THIS VIEW IS BUILT FOR ONE CLIP AND IS NEVER RE-POINTED AT ANOTHER. That is the whole of the
//  architecture change, and every guard the file it replaces needed came from the opposite rule.
//  There is no `startVideo(url:)` here, no stale-answer check, no "is the player still on my clip",
//  because there is no moment at which this view's player holds anybody else's item. If you find
//  yourself adding a url parameter to something in this file, the thing to do instead is build a new
//  view.
//
//  The reference app's shape, read from its source and followed line for line:
//
//    1. A still image is added FIRST and is never hidden and never removed. The video layer goes in
//       ABOVE it, born hidden, and the only thing that ever unhides it is its own first frame.
//       There is no veil to raise and lower, which deletes the entire family of bugs where a cover
//       was rebuilt over a picture that was already on screen.
//    2. A player is CREATED only when this item's mode is `.play` (`initializeVideoIfReady` opens
//       `if case .pause = self.progressMode.mode { return }`). An item that is merely visible — a
//       card in the collapsed sheet that was never watched — never builds one at all.
//    3. A player is RELEASED only when the item's media changes, which for us means when this view
//       goes. Pausing never tears it down, which is why a paused item keeps its position and its
//       last frame with nothing stored anywhere.
//    4. Pause is `pause()` and resume is `play()`, with NO SEEK. The only `seek(0)` is on a freshly
//       attached player, which is what makes a revisited story restart at zero — the owner's rule —
//       without anything having to remember or forget a position.
//

import UIKit
import AVFoundation

/// ⚠️ NO EXPLICIT `@MainActor` HERE, AND THAT IS NOT AN OVERSIGHT.
///
/// `UIView` is already main-actor isolated by the SDK, so this class is too — but it inherits that
/// isolation through a `@preconcurrency` import, which in Swift 5 language mode downgrades a
/// violation to a warning. An explicit annotation written in this module would not: it makes every
/// call from a non-isolated context (a KVO block, a `URLSession` completion, a plain forwarding
/// object) a hard error. The player this replaces was a bare `UIView` subclass called from exactly
/// those places for forty-five commits, and it compiled. There is no Swift compiler on this machine,
/// so matching the shape that is known to build is worth more than the annotation.
final class StoryItemVideoView: UIView {

    // MARK: - Identity

    /// ⚠️ THE STORY'S OWN ID, NOT ITS URL, AND THE DIFFERENCE IS LOAD-BEARING.
    ///
    /// Three things key on this — the store, the session's claim, and SwiftUI's `.id()` — and while
    /// they used the media url they could disagree about what that url was: the store looked it up
    /// as the RAW string, this derived it through `URL(string:)?.absoluteString`, and the progress
    /// bar compared it against the model's string again. Any normalisation `URL` performs breaks all
    /// three at once, and an unparseable url collapsed every item onto one fallback key.
    ///
    /// A story id is a document id. It is unique, it needs no parsing, and it cannot normalise.
    let storyId: String
    /// The clip. Assigned once, at init, and there is deliberately no setter. Nil when the story's
    /// media url could not be parsed at all — a story that cannot be fetched, which this view
    /// reports as failed rather than sitting on for ever.
    let storyURL: URL?
    var storyKey: String { storyId }

    /// Whether this view is holding a decoder. The store keeps only views that are — see `keep`.
    var hasPlayer: Bool { player != nil }

    // MARK: - The picture underneath

    /// ⚠️ ADDED FIRST, NEVER HIDDEN, NEVER REMOVED — the reference app's `imageView`, which its video
    /// node is inserted above (`insertSubview(videoNode.view, aboveSubview: self.imageView)`) and
    /// which nothing in its story code ever takes down for a video story.
    ///
    /// This is what makes the hand-over invisible and what makes it impossible to show black: there
    /// is no instant at which the still is gone and the clip is not yet there, because the still
    /// never goes. The old design added a "veil" subview on every load and removed it on reveal, and
    /// three separate shipped bugs were a veil being rebuilt over a picture that was already
    /// correct.
    private let coverView = UIImageView()

    /// The gradient behind a clip that does not fill the card. Same sampler as the exporter, so a
    /// story cannot change appearance depending on which half of the app drew its background.
    private let canvasLayer = StoryCanvas.makeLayer()
    private var canvasSourced = false

    /// The loading indicator, as an OVERLAY on whatever is showing. Never a replacement — the
    /// reference app's stall indicator is drawn over the running picture and it excludes initial
    /// buffering outright.
    private let spinner = UIActivityIndicatorView(style: .large)
    private var spinnerShown = false

    // MARK: - The player

    /// Nil until this item is asked to play. See `initializeVideoIfReady`.
    private var player: AVPlayer?
    private var playerLayer: AVPlayerLayer?
    /// The asset this item is streaming through, when it is. AVFoundation holds a resource loader's
    /// delegate WEAKLY, so the reader is kept alive against the asset and has to be let go with it —
    /// see `StoryVideoStream.release`. Nil on the ordinary local-file path.
    private var streamedAsset: AVURLAsset?

    private var mode: StoryProgressMode = .pause
    private weak var session: StoryVideoSession?

    /// The bytes are on disk. The reference app keys its loading shimmer on this and never on player
    /// readiness, so a cached story never shows a loading state.
    private var contentLoaded = false
    private var localFile: URL?
    /// One retry per view, or a dead url becomes an endless download loop.
    private var didRetryRemote = false

    private var readyObservation: NSKeyValueObservation?
    private var sizeObservation: NSKeyValueObservation?
    private var statusObservation: NSKeyValueObservation?
    private var rateObservation: NSKeyValueObservation?
    private var timeObserver: Any?
    private var endToken: NSObjectProtocol?

    /// The clip's own pixel size once the item reports it, so fit-vs-fill can be re-taken when the
    /// VIEW's size changes and not only when the video's does.
    private var presentedSize: CGSize = .zero

    /// TRUE once the first frame of THIS clip is on screen. One-shot, like the reference app's
    /// `didProcessFramesToDisplay` — the readiness callback there fires per frame otherwise.
    private var didShowFirstFrame = false

    /// Whether playback has ever actually started. Initial buffering is not a stall, and reporting
    /// it as one is what froze the progress bar before a clip had begun.
    private var didBeginPlayback = false

    private let poster: String?
    private let blurThumb: String
    private var posterImage: UIImage?
    private var blurThumbImage: UIImage?
    /// The picture the still is built FROM, and whether it is a real frame of this clip. Kept apart
    /// from `coverView.image` because the blurred variant is composited at the card's size — see
    /// `renderCover`.
    private var coverSource: UIImage?
    private var coverIsFrame = false
    /// What the cover currently on show is WORTH. Nil until one is set. See `CoverRank`.
    private var coverRank: CoverRank?
    /// The card size the blurred variant was composited for, so `layoutSubviews` does not re-run a
    /// render pass on every frame of a sheet pull. `.zero` for a real frame, which needs no compositing.
    private var coverRenderedSize: CGSize = .zero

    /// ⛔ THE AUTHOR ASKED FOR THIS STORY NOT TO BE COPIED. `CaptureShield` holds what iOS actually
    /// promises here, which is less than the word "block" suggests — read it before changing this.
    private lazy var shield = CaptureShield(host: self)

    /// Set from the story on every attach, so protection survives a pause, a swipe to the next clip,
    /// a swipe back, an automatic advance, and a view handed back by `StoryItemViewStore` with its
    /// player still running.
    var isCaptureProtected: Bool = false {
        didSet {
            guard isCaptureProtected != oldValue else { return }
            shield.onCaptureStateChanged = { [weak self] capturing in
                self?.applyCaptureBlank(capturing)
            }
            shield.setProtected(isCaptureProtected)
            applyCaptureBlank(shield.isCapturing)
        }
    }

    /// ⚠️ THE CLIP KEEPS PLAYING. Blanking is one opacity write on the shield's content: no pause, no
    /// seek, no teardown and no layout, so a recording that starts mid-story cannot desynchronise the
    /// progress bar from the picture or leave a frozen frame behind when it stops.
    private func applyCaptureBlank(_ capturing: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shield.content.layer.opacity = capturing ? 0 : 1
        CATransaction.commit()
    }

    // MARK: - Init

    init(storyId: String, storyURL: URL?, poster: String?, blurThumb: String) {
        self.storyId = storyId
        self.storyURL = storyURL
        self.poster = poster
        self.blurThumb = blurThumb
        super.init(frame: .zero)

        backgroundColor = .black
        // ⚠️ THE CARD'S ONE CORNER, NOT A 12 OF THIS VIEW'S OWN — his 2026-08-18 "video top corners
        // and bottom corners is small". A clip carried 12 while a photo carried 24 underneath the
        // page's 12, so the two media types did not even agree with each other. See
        // `Constant.cardCornerRadius` for the measurement off his reference.
        layer.cornerRadius = Constant.cardCornerRadius
        layer.cornerCurve = .circular
        clipsToBounds = true

        // ⚠️ THE PICTURE GOES IN THE SHIELD, THE CHROME DOES NOT — see `CaptureShield`. The cover,
        // the canvas and the player layer are the clip; the spinner is ours and keeps its own
        // constraints, which a reparented layer would not honour.
        canvasLayer.isHidden = true          // shown only once a clip is known not to fill the card
        shield.content.layer.addSublayer(canvasLayer)

        coverView.contentMode = .scaleAspectFill
        coverView.clipsToBounds = true
        // Frames are set explicitly in `layoutSubviews`, which is what keeps this right inside the
        // shield's content view — autoresizing needs a view hierarchy that reaches a window.
        coverView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        shield.content.addSubview(coverView)

        spinner.color = UIColor.lightGray.withAlphaComponent(0.7)
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.alpha = 0
        addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])

        StoryItemViewStore.register(self)
        resolveCover()
        // The fetch starts as soon as the item is mounted, whatever the mode — the reference app
        // fetches the current item's media on `update()` and builds the node separately. A story
        // being paused under a sheet should still be arriving.
        ensureContent()
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        readyObservation?.invalidate()
        sizeObservation?.invalidate()
        statusObservation?.invalidate()
        rateObservation?.invalidate()
        if let endToken { NotificationCenter.default.removeObserver(endToken) }
    }

    // MARK: - The session this view reports into

    /// Join this page's session: take the claim, take the mode it should already be in, and publish
    /// what is already true.
    ///
    /// ⚠️ THE LAST PART MATTERS WHEN A VIEW COMES BACK OUT OF THE STORE. Its player is part-way
    /// through a clip and its numbers are real, so pushing them here is what stops the progress bar
    /// jumping to zero for the frame between the bind and the first periodic tick.
    func attach(to s: StoryVideoSession) {
        session = s
        s.bind(self)
        s.update(storyKey,
                 timestamp: currentSecond,
                 duration: knownDuration,
                 isPlaying: player?.timeControlStatus == .playing,
                 // ⚠️ THE LIVE ANSWER, NEVER A FLAT `false`. `updateUIView` calls this on every
                 // re-render of the story page, and a re-render happens for reasons that have
                 // nothing to do with the network. Publishing `false` here would clear a genuine
                 // stall — and `noteTimeControl` only fires on a CHANGE, so nothing would ever
                 // re-report it and the progress bar would count straight through a clip that had
                 // stopped moving. That is the desynchronisation this engine exists to remove,
                 // reintroduced by a line that looks like tidy initialisation.
                 isBuffering: isStalled,
                 contentLoaded: contentLoaded,
                 failed: player?.currentItem?.status == .failed)
    }

    /// Waiting on bytes MID-CLIP. Initial buffering is not a stall — see `noteTimeControl`, and the
    /// reference app's `.buffering(initial: false, whilePlaying: true, …)` pattern, which counts only
    /// an interruption to playback that had already begun.
    private var isStalled: Bool {
        player?.timeControlStatus == .waitingToPlayAtSpecifiedRate
            && didBeginPlayback && currentSecond > 0.3
    }

    /// ⚠️ WAITING ON THE FIRST BYTES, WHICH ONLY THE STREAMING PATH CAN BE IN.
    ///
    /// The download path says "still fetching" with `!contentLoaded`, and that is what puts the
    /// wheel on a story that has not arrived yet. A reader has no such moment: content is "here" the
    /// instant the item mounts, because the point of it is that the bytes come in behind the player.
    /// So `contentLoaded` is true immediately, `isStalled` is false until playback has begun — and
    /// between those two a slow connection had a frozen cover with nothing on screen saying why,
    /// which is the report this spinner exists to prevent, arriving through the new path.
    private var isAwaitingFirstBytes: Bool {
        streamedAsset != nil && !didBeginPlayback
            && player?.timeControlStatus == .waitingToPlayAtSpecifiedRate
    }

    /// Leave the session, if it is still ours to leave.
    func detach() {
        session?.unbind(self)
        session = nil
    }

    // MARK: - Mode

    /// THE REFERENCE APP'S `updateProgressMode`, IN ORDER: settle the existing player first, then
    /// give a player to an item that has just been allowed to play.
    ///
    /// That order is load-bearing and is easy to get backwards. Unpausing is also the CREATION
    /// trigger — an item whose media finished loading while it was paused has no player at all, and
    /// nothing else would ever come along to build one for it.
    func apply(mode newMode: StoryProgressMode) {
        mode = newMode
        if let player {
            // Playing needs more than permission: the bytes have to be here and the view has to be
            // in the hierarchy. The reference app gates on exactly these two
            // (`contentLoaded && hierarchyTrackingLayer.isInHierarchy`), because an off-screen item
            // that keeps decoding is a story you can hear but not see.
            let canPlay = newMode == .play && contentLoaded && window != nil
            if canPlay {
                player.play()
            } else {
                player.pause()
                // ⚠️ THE CARD'S PICTURE IS STARTED HERE, AT THE PAUSE, AND NOT WHEN A CARD ASKS.
                //
                // Generating it is a decode off the main thread, so a card that asks and waits shows
                // its poster for the first fifty milliseconds — and a poster for a video is second
                // zero, which is exactly the "the moment it leaves centre it reverts to the upload
                // cover" report this whole area has been failing on. Half a solved bug looks
                // identical to the bug.
                //
                // Pausing IS the moment the sheet comes up over a story, so the frame is in hand
                // before the first swipe can ask for it. Idempotent and cheap: a second call for the
                // same second finds it cached and starts nothing.
                if let storyURL { StoryVideoFrames.warm(storyURL, at: currentSecond) }
            }
        }
        initializeVideoIfReady()
        publishStatus()
    }

    /// ⚠️ THE OTHER SEEK, AND THE ONLY ONE THAT IS NOT ON A FRESH PLAYER. It is an explicit thing the
    /// person did — tapping back past the first story of the first person restarts what is playing.
    /// Do not add a second one: every other "go back to the beginning" in this viewer is a new item,
    /// and a new item is a new player, which begins at zero because it has never been anywhere else.
    func restart() {
        player?.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        apply(mode: mode)
    }

    /// Where this clip is. Answers 0 rather than guessing when there is no player.
    var currentSecond: Double {
        guard let player, player.currentItem != nil else { return 0 }
        let t = player.currentTime().seconds
        return t.isFinite && t >= 0 ? t : 0
    }

    private var knownDuration: Double {
        guard let d = player?.currentItem?.duration.seconds, d.isFinite, d > 0 else { return 0 }
        return d
    }

    // MARK: - Creating the player

    /// ⚠️ THE FOUR PRECONDITIONS, AND THE SECOND ONE IS THE ARCHITECTURE.
    ///
    /// The reference app's `initializeVideoIfReady` opens with exactly this pair — return if a node
    /// already exists, return `if case .pause = self.progressMode.mode` — and the second line is why
    /// its side cards cost nothing and why ours can now be alive at all. A card that is merely
    /// visible never builds a player; only the item actually playing does.
    ///
    /// It deliberately does NOT check whether the item is on screen: a story opened while the sheet
    /// is already up is legitimately built before it is looked at. `apply(mode:)` holds `play()`
    /// back until the window is real.
    private func initializeVideoIfReady() {
        guard player == nil else { return }
        guard mode == .play else { return }
        guard contentLoaded, let file = localFile else { return }

        // Stories are sound-on media: `.playback` plays through the ringer switch. The default
        // muted every story video on a silenced phone.
        try? AVAudioSession.sharedInstance().setCategory(.playback)

        // ⚠️ THE STREAM IS TRIED FIRST AND ONLY WHEN THE WHOLE FILE IS NOT ALREADY HERE. A clip that
        // is fully cached has nothing to gain from a reader and everything to lose — a local file is
        // one open and no state machine at all. `StoryVideoStream.asset` answers nil when streaming
        // is off, and IT IS ON as of 2026-08-12 — this line is live, not the no-op it used to be.
        // The knock-on is worth knowing here: while a clip is being read this way there is no whole
        // file in `VideoCache`, so anything that wants a still of it has to go through the reader
        // too. See `StoryVideoFrames.source`.
        // ⚠️ `!didRetryRemote` IS THE FALLBACK, NOT A DETAIL. `handleFailedItem` recovers a clip that
        // will not play by pointing `localFile` at the remote url and rebuilding — and on the
        // streaming path `localFile` IS the remote url, so without this the recovery built a second
        // reader over the same broken fetch, failed the same way, and gave up. The retry is a plain
        // https `AVPlayerItem`, which is what "stream the remote url directly" always meant.
        let streamed: AVURLAsset? = (localFile == storyURL && !didRetryRemote)
            ? StoryVideoStream.asset(for: file) : nil
        let item = streamed.map { AVPlayerItem(asset: $0) }
            ?? StoryItemPreloader.take(file)
            ?? AVPlayerItem(url: file)
        streamedAsset = streamed
        let p = AVPlayer(playerItem: item)
        // LET AVFOUNDATION WAIT. Forcing this false tells the player to start the instant it is
        // asked whether or not a frame is buffered, so on anything less than a good connection a
        // story began by stuttering. Holding a moment longer on a picture beats starting on one.
        p.automaticallyWaitsToMinimizeStalling = true
        player = p

        let pl = AVPlayerLayer(player: p)
        // CLEAR, not black: the canvas lives behind this layer and a black fill would cover it.
        pl.backgroundColor = UIColor.clear.cgColor
        pl.videoGravity = .resizeAspectFill
        // ⚠️ BORN HIDDEN. A layer with no decoded frame draws its background, and behind it is a
        // canvas that starts black over a black view — that is the blink. The reference app's node
        // is created `isHidden = true` over its thumbnail and only its own first frame unhides it.
        pl.isHidden = true
        pl.frame = bounds
        playerLayer = pl
        // ABOVE THE STILL, NEVER INSTEAD OF IT — and inside the shield with it, so a protected
        // clip and its own cover frame are one thing to the compositor.
        shield.content.layer.insertSublayer(pl, above: coverView.layer)

        // ⚠️ EVERY OBSERVER IS INSTALLED BEFORE THE FIRST `play()`. The reference app installs
        // `playbackCompleted` and `ownsContentNodeUpdated` before `canAttachContent = true`, because
        // attaching can synchronously deliver content and fire the callback that starts playback —
        // install them afterwards and the first play is lost.
        installObservers(on: p, item: item)

        // ⚠️ ONE OF THE ONLY TWO SEEKS IN THIS FILE, AND IT IS ON A FRESH PLAYER. The reference app seeks to 0
        // from `ownsContentNodeUpdated`, which fires when a NEW node acquires its content — not on
        // any pause or resume path. A brand-new `AVPlayerItem` is already at zero, so this is belt
        // for a preloaded item that has been prerolled: it costs nothing and it makes the rule
        // explicit rather than implied.
        p.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)

        applyGravity()
        refreshBackdrop()

        if mode == .play, window != nil { p.play() }
        publishStatus()
    }

    private func installObservers(on p: AVPlayer, item: AVPlayerItem) {
        // THE END OF A CLIP IS THE PLAYER'S TO REPORT, and it is the only thing that may complete a
        // video segment. The reference app advances a story from `playbackCompleted` alone; its
        // ordinary progress updates carry `canSwitch = false`, so a bar reaching 1.0 can never move
        // the story on. Scoped to this exact item, and re-checked when it fires.
        endToken = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self, weak item] _ in
            guard let self, let item, self.player?.currentItem === item else { return }
            self.session?.noteFinished(self.storyKey)
        }

        // The one thing that ever takes the video layer off `isHidden`. Observed on the LAYER, which
        // owns the answer, and once for the life of this view.
        readyObservation = playerLayer?.observe(\.isReadyForDisplay, options: [.new]) { [weak self] _, _ in
            guard let self else { return }
            if Thread.isMainThread { self.revealIfReady() }
            else { DispatchQueue.main.async { self.revealIfReady() } }
        }

        sizeObservation = item.observe(\.presentationSize, options: [.new, .initial]) { [weak self] i, _ in
            let s = i.presentationSize
            guard let self, s.width > 0, s.height > 0 else { return }
            if Thread.isMainThread { self.notePresentationSize(s) }
            else { DispatchQueue.main.async { self.notePresentationSize(s) } }
        }

        statusObservation = item.observe(\.status, options: [.new, .initial]) { [weak self] i, _ in
            guard let self else { return }
            if Thread.isMainThread { self.noteItemStatus(i) }
            else { DispatchQueue.main.async { self.noteItemStatus(i) } }
        }

        rateObservation = p.observe(\.timeControlStatus, options: [.new, .initial]) { [weak self] pl, _ in
            guard let self else { return }
            let s = pl.timeControlStatus
            if Thread.isMainThread { self.noteTimeControl(s) }
            else { DispatchQueue.main.async { self.noteTimeControl(s) } }
        }

        // ⚠️ THE BAR READS THE PLAYER, so the player has to publish. Twenty times a second, which is
        // the rate the viewer's own tick already runs at — the reference app polls its player at 60
        // and interpolates between them, and a bar drawn at 20Hz cannot show the difference.
        timeObserver = p.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.05, preferredTimescale: 600), queue: .main
        ) { [weak self] _ in
            self?.publishStatus()
        }
    }

    // MARK: - Status out

    private func publishStatus() {
        guard let session else { return }
        session.update(storyKey,
                      timestamp: currentSecond,
                      duration: knownDuration,
                      isPlaying: player?.timeControlStatus == .playing,
                      contentLoaded: contentLoaded)
    }

    private func noteItemStatus(_ item: AVPlayerItem) {
        guard item === player?.currentItem else { return }
        switch item.status {
        case .failed:
            // ⚠️ HOPPED OUT OF THE OBSERVER'S OWN CALLBACK. The recovery below tears the player down,
            // which invalidates the very `NSKeyValueObservation` this is running inside. Doing that
            // one runloop turn later keeps the teardown out of its own notification.
            DispatchQueue.main.async { [weak self] in self?.handleFailedItem() }
        case .readyToPlay:
            session?.update(storyKey, duration: knownDuration, failed: false)
            // PREROLL DECODES; IT DOES NOT DISPLAY, and it is called HERE and nowhere earlier.
            // `preroll(atRate:)` raises an Objective-C exception if the item is not ready, and an
            // Objective-C exception in Swift is not catchable — it goes straight to abort(). That
            // was a shipped crash. `.readyToPlay` is the state the documentation requires.
            player?.preroll(atRate: 1) { _ in }
        default:
            break
        }
    }

    private func noteTimeControl(_ s: AVPlayer.TimeControlStatus) {
        switch s {
        case .playing:
            didBeginPlayback = true
            setBuffering(false)
        case .waitingToPlayAtSpecifiedRate:
            // ⚠️ INITIAL BUFFERING IS NOT A STALL. The reference app counts only
            // `.buffering(initial: false, whilePlaying: true, ...)` as something to show, and
            // suppresses even that for the first 0.3s of a clip. A story that has not started yet is
            // LOADING, which the spinner already says; calling it a stall froze the progress bar
            // before there was anything for it to measure.
            setBuffering(isStalled)
        default:
            setBuffering(false)
        }
        publishStatus()
        updateSpinner()
    }

    private func setBuffering(_ on: Bool) {
        session?.update(storyKey, isBuffering: on)
    }

    /// A clip that can never play says so, instead of leaving the wheel turning for ever.
    private func handleFailedItem() {
        // ⚠️ NOT ON A VIEW THAT HAS ALREADY BEEN TORN DOWN. This runs one runloop turn after the
        // failure was noticed, and a teardown can happen inside that gap — the recovery below would
        // then build a BRAND NEW `AVPlayer` on a detached, unparented view that nothing will ever
        // tear down again, holding a decoder for the life of the process. A view that has left its
        // session has left the viewer.
        guard session != nil else { return }
        // A half-written cache file is the worst case because it is PERMANENT: it exists, so every
        // later open finds it and never downloads again. Throw it away and stream instead.
        if let bad = localFile, !didRetryRemote, let remote = storyURL {
            didRetryRemote = true
            localFile = nil
            // Only a real cache file is worth deleting; the "bad" url may already BE the remote one.
            if bad.isFileURL { try? FileManager.default.removeItem(at: bad) }
            // A STREAMED CLIP'S RUBBISH IS IN THE PARTIAL, NOT IN A CACHE FILE. Same reasoning as
            // the line above and the same permanence: whatever is on disk here was reached through
            // a fetch that has just failed, and a partial nobody throws away is found by every
            // later open and trusted. See `StoryPartialFile.discard`.
            if streamedAsset != nil { StoryVideoStream.discardPartial(for: remote) }
            teardownPlayer()
            localFile = remote            // stream the remote url directly
            contentLoaded = true
            initializeVideoIfReady()
            return
        }
        // Argument order follows the declaration — Swift enforces it even for defaulted parameters.
        session?.update(storyKey, isBuffering: false, failed: true)
        updateSpinner()
    }

    // MARK: - Reveal

    /// BOTH ANSWERS HAVE TO BE IN: a frame exists, and we know the shape to frame it at. Whichever
    /// lands second does the reveal, and `didShowFirstFrame` is the latch that makes it once.
    ///
    /// ⚠️ THERE IS NO "WHICH CLIP" QUESTION HERE ANY MORE. The file this replaces needed `awaitedItem`
    /// and a swap-settling flag because one player was handed clip after clip and `isReadyForDisplay`
    /// could still be answering about the one just flushed. This layer's player has held exactly one
    /// item since it was created, so a true answer can only be about this clip.
    private func revealIfReady() {
        guard !didShowFirstFrame, let pl = playerLayer, pl.isHidden else { return }
        guard pl.isReadyForDisplay else { return }
        if presentedSize.width <= 0 || presentedSize.height <= 0,
           let live = player?.currentItem?.presentationSize, live.width > 0, live.height > 0 {
            presentedSize = live
        }
        guard presentedSize.width > 0, presentedSize.height > 0 else { return }
        // A CARD WITH NO SIZE CANNOT DECIDE FIT VERSUS FILL, so revealing into one would show the
        // clip at whatever gravity it was born with. `layoutSubviews` calls back here, so this is a
        // wait rather than a refusal.
        guard bounds.width > 1, bounds.height > 1 else { return }
        // ORDER MATTERS: gravity and canvas colours are settled while the layer is still hidden, so
        // the first frame anybody sees is already at its final scale on a coloured backdrop.
        applyGravity()
        refreshBackdrop()
        didShowFirstFrame = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)   // an appearance must not fade in
        pl.isHidden = false
        CATransaction.commit()
        updateSpinner()
    }

    private func notePresentationSize(_ s: CGSize) {
        presentedSize = s
        applyGravity()
        refreshBackdrop()
        revealIfReady()
    }

    // MARK: - Geometry

    override func layoutSubviews() {
        super.layoutSubviews()
        // FIRST: the shield holds the clip at this view's own bounds whether it is shielded or not,
        // so every frame below is set in the coordinates it always was.
        shield.layout(in: bounds)
        shield.retryIfNeeded()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        coverView.frame = bounds
        playerLayer?.frame = bounds
        StoryCanvas.frame(canvasLayer, to: bounds)
        CATransaction.commit()
        applyGravity()
        refreshBackdrop()
        // A blurred thumbnail is composited at the card's size, so it is built here — but ONLY when
        // the size it was built for has actually changed. `loadingVeil` runs a real render pass, and
        // `layoutSubviews` fires on every frame of the sheet pull.
        if !coverIsFrame, coverRenderedSize != bounds.size { renderCover() }
        // ⚠️ AND A STILL THAT WAS NOT READY THE FIRST TIME IS ASKED FOR AGAIN. A clip with no
        // `thumb.jpg` and no embedded thumbnail — one posted before either existed, or one whose
        // second upload failed — has only its own opening frame to show, and that is a decode: the
        // first ask returns nil because it is still running. Nothing calls back into this view when
        // it lands, so without a retry the card would sit black until the player itself revealed.
        // `layoutSubviews` runs often enough to be that retry and costs nothing when a cover exists.
        if coverView.image == nil { openingFrameFallback() }
        applyCoverGravity()
        revealIfReady()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // The reference app re-runs its progress mode whenever the item enters or leaves the
        // hierarchy, and gates both playback and its progress timer on being in it. An off-screen
        // item neither plays nor ticks.
        apply(mode: mode)
    }

    private func applyGravity() {
        guard let pl = playerLayer,
              presentedSize.width > 0, presentedSize.height > 0,
              bounds.width > 0, bounds.height > 0 else { return }
        let want: AVLayerVideoGravity = StoryCanvas.fills(media: presentedSize, in: bounds.size)
            ? .resizeAspectFill : .resizeAspect
        guard pl.videoGravity != want else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pl.videoGravity = want
        CATransaction.commit()
    }

    /// The still is framed by the same question through the same function, so it and the clip that
    /// appears over it cannot be framed two different ways.
    private func applyCoverGravity() {
        guard let img = coverView.image, bounds.width > 1, bounds.height > 1 else { return }
        coverView.contentMode = StoryCanvas.fills(media: img.size, in: bounds.size)
            ? .scaleAspectFill : .scaleAspectFit
    }

    private func refreshBackdrop() {
        guard bounds.width > 1, bounds.height > 1 else { return }
        // Undecided counts as "might have bars": a canvas behind a video that turns out to fill the
        // frame is invisible, black behind one that does not is the bug.
        let known = presentedSize.width > 0 && presentedSize.height > 0
        let fills = known && StoryCanvas.fills(media: presentedSize, in: bounds.size)
        canvasLayer.isHidden = fills
        guard !fills, !canvasSourced else { return }
        // The SOURCE picture, never the composited veil: sampling the blurred variant would read the
        // gradient this is about to draw and give the bars a colour taken from themselves.
        guard let source = posterImage ?? coverSource ?? blurThumbImage else { return }
        // ⚠️ THE 30px THUMBNAIL COLOURS THE BARS BUT DOES NOT SETTLE THEM. It is the only picture in
        // hand on the first frame of a cold open, and it is a legitimate colour source — but the
        // real poster is usually a moment behind it, and latching on the blur meant the letterbox
        // bars kept colours sampled from thirty pixels of smear for the whole story. Anything better
        // is allowed to re-take the decision exactly once.
        canvasSourced = (source !== blurThumbImage)
        StoryCanvas.apply(StoryCanvas.colours(of: source), to: canvasLayer)
    }

    // MARK: - The still

    /// ⚠️ ONE PICTURE, TWO TREATMENTS, AND THE DIFFERENCE IS NOT COSMETIC. A real frame of this clip
    /// — its `thumb.jpg`, which is a full-size photograph of its own opening — goes up AS IT IS, so
    /// the hand-over to the live layer is invisible: same picture, same size, same place. Only the
    /// ~30px embedded thumbnail is blurred, because at card size that is the only honest thing to do
    /// with it. Blurring the real one is what the owner photographed and called "full blur screen".
    private func resolveCover() {
        if !blurThumb.isEmpty, let data = Data(base64Encoded: blurThumb), let img = UIImage(data: data) {
            blurThumbImage = img
            setCover(img, rank: .blurThumb)
        }
        guard let poster, let u = URL(string: poster) else { openingFrameFallback(); return }
        // A POSTER IS A PICTURE. A video url arriving here (the window before `thumb.jpg` exists
        // hands the mp4 through `previewUrl`) read megabytes off disk on the main thread and then
        // downloaded the whole clip a second time to decode nothing.
        guard !["mp4", "mov", "m4v"].contains(u.pathExtension.lowercased()) else {
            openingFrameFallback(); return
        }
        // THE APP'S OWN CACHE FIRST. The two below are StoryUI's; the app draws its row through a
        // different one and warms that, so for a story just posted both of these miss and the cover
        // becomes a network fetch — leaving the hide-until-ready rule with nothing to hide behind.
        if let img = StoryPosterSource.provider?(poster) { posterImage = img; setCover(img, rank: .poster); return }
        if let cached = URLCache.shared.cachedResponse(for: .init(url: u)), let img = UIImage(data: cached.data) {
            posterImage = img; setCover(img, rank: .poster); return
        }
        if let disk = StoryDiskCache.image(u) { posterImage = disk; setCover(disk, rank: .poster); return }
        URLSession.shared.dataTask(with: u) { [weak self] data, _, _ in
            guard let data, let img = UIImage(data: data) else { return }
            StoryDiskCache.store(data, for: u)
            DispatchQueue.main.async {
                guard let self else { return }
                self.posterImage = img
                // ⚠️ AND IT IS RANKED, BECAUSE THIS IS THE LATE ARRIVAL THAT USED TO DEMOTE A BETTER
                // PICTURE. A poster cannot be drawn over a clip that is playing — the still lives
                // UNDERNEATH the video layer — but it was replacing what was behind it, and by the
                // time a network fetch lands the view may already have frozen itself on the second
                // it was paused at. Second zero over 0:20 is a downgrade, and `setCover` now refuses
                // it. `posterImage` is still recorded: the canvas reads it and `openingFrameFallback`
                // uses it to decide whether it is needed at all.
                self.setCover(img, rank: .poster)
            }
        }.resume()
        openingFrameFallback()
    }

    /// A CACHED CLIP CAN BE ITS OWN POSTER. A video with no thumbnail reaches here with nothing to
    /// cover with — the spinner over a bare gradient. Second zero is exactly the honest cover,
    /// because playback always begins there.
    private func openingFrameFallback() {
        guard posterImage == nil, let storyURL else { return }
        // ⚠️ WITH A LANDING, BECAUSE THE FIRST ASK ALWAYS ANSWERS NIL. Generating this is a decode
        // off the main thread, and nothing used to call back into this view when it finished — the
        // only listener was the carousel's redraw counter. So the one case this fallback exists for
        // (a clip whose `thumb.jpg` has not uploaded yet, and which has no embedded thumbnail
        // either) showed BLACK for the whole load, with a perfectly good opening frame arriving into
        // a cache nobody re-read.
        if let frame = StoryVideoFrames.opening(storyURL, then: { [weak self] image in
            guard let self, self.posterImage == nil else { return }
            self.setCover(image, rank: .openingFrame)
        }) {
            setCover(frame, rank: .openingFrame)
        }
    }

    /// ⚠️ THE BLURRED THUMBNAIL IS COMPOSITED AT A SIZE, SO IT CANNOT BE BUILT BEFORE THERE IS ONE.
    ///
    /// `resolveCover` runs in `init`, where `bounds` is still zero — `loadingVeil(of:covering: .zero)`
    /// would draw nothing and the story would open on black with a perfectly good thumbnail in hand.
    /// So the source is remembered and the composite is (re)built from `layoutSubviews`, which is
    /// also where it belongs when the card changes shape.
    /// PUT THE FRAME WE ARE PAUSED ON UNDER THE PLAYER BEFORE THIS VIEW LEAVES THE SCREEN.
    ///
    /// ⚠️ HIS 2026-08-12 REPORT, AND THE REASON ONLY ONE STORY EVER FLASHED.
    ///
    /// While the viewers sheet is up every item is `.pause`, and a paused item never builds a player
    /// (`initializeVideoIfReady`) — so the story the sheet came up over is the ONLY one holding a
    /// player, and the only one that can show this. `StoryItemViewStore.keep` takes the view out of
    /// the hierarchy to store it, iOS reclaims the decoded frame of an `AVPlayerLayer` that is not on
    /// screen, and `revealIfReady` is a spent latch by then — nothing waits for the picture to come
    /// back. For those frames the layer is visible with nothing in it and the cover shows through.
    ///
    /// The cover was the UPLOAD POSTER, which is second zero. So swiping back to a clip paused at
    /// four seconds showed its opening frame for a frame and then snapped. Same picture on both sides
    /// of the hand-over is the rule the carousel already follows for its centre slot; this is that
    /// rule applied to the one exchange that was still showing two different pictures.
    ///
    /// The still is the same one `StoryVideoFrames` already generates for the carousel card — the
    /// pause warms it (see `apply(mode:)`), so by here it is usually a cache hit, and the landing
    /// covers the case where it is not. Deliberately does NOT re-hide the player layer: a hidden
    /// layer that never becomes ready again would strand the still permanently, and with the right
    /// picture underneath there is nothing left to hide it for.
    func freezeCoverToCurrentFrame() {
        guard let storyURL, hasPlayer else { return }
        let second = currentSecond
        guard second > 0.2 else { return }
        if let frame = StoryVideoFrames.frame(storyURL, at: second, then: { [weak self] image in
            self?.setCover(image, rank: .pausedFrame)
        }) {
            setCover(frame, rank: .pausedFrame)
        }
    }

    /// WHAT A COVER IS WORTH. Four sources reach `setCover` and they are not equally good pictures.
    ///
    /// ⚠️ THIS USED TO BE A BOOLEAN AND THAT IS THE BUG. `isFrame` said only "better than the blurred
    /// thumbnail", so the three that were all `true` had no order between them and the LAST writer
    /// won. The poster is fetched from the network at the bottom of `resolveCover`, and a fetch that
    /// lands after the view has frozen itself on the second it was paused at replaced a picture of
    /// 0:20 with a picture of 0:00. That is the "it reverts to the upload cover" report arriving down
    /// the network path — a different route to the same wrong picture as the one already fixed on the
    /// capture side, which is why fixing that one did not end the reports.
    private enum CoverRank: Int, Comparable {
        /// The ~30px blurred thumbnail carried on the story document. A stand-in that looks like one.
        case blurThumb = 0
        /// The uploaded `thumb.jpg`. A real photograph of the clip, but only ever of second zero.
        case poster = 1
        /// Second zero decoded from the clip itself. The same instant as the poster and a truer
        /// picture of it, and it exists for clips that never got a poster at all.
        case openingFrame = 2
        /// The second the player is actually parked on. The only cover that answers "what was on
        /// screen when I left it", which is the question the card in the row is asking.
        case pausedFrame = 3
        static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    }

    private func setCover(_ image: UIImage, rank: CoverRank) {
        // A cover may only be replaced by one at least as good. Equal rank still replaces: a freshly
        // frozen frame at a new second is worth more than the one held from the second before it.
        if let have = coverRank, rank < have { return }
        coverSource = image
        coverRank = rank
        coverIsFrame = rank > .blurThumb
        renderCover()
    }

    private func renderCover() {
        guard let src = coverSource else { return }
        if coverIsFrame {
            coverView.image = src
            coverRenderedSize = .zero          // a real frame is size-independent
        } else {
            guard bounds.width > 1, bounds.height > 1 else { return }   // rebuilt from layoutSubviews
            coverView.image = StoryCanvas.loadingVeil(of: src, covering: bounds.size)
            coverRenderedSize = bounds.size
        }
        applyCoverGravity()
        refreshBackdrop()
    }

    // MARK: - Content

    private func ensureContent() {
        // A story whose media url will not parse can never be fetched. Say so straight away: the
        // progress bar falls back to the wall clock on a failed item, so the story hands the screen
        // on after its declared length instead of freezing the viewer on a cover.
        guard let storyURL else {
            session?.update(storyKey, isBuffering: false, failed: true)
            updateSpinner()
            return
        }
        if let file = CacheManager.cachedFileIfUsable(for: storyURL) {
            localFile = file
            contentLoaded = true
            session?.update(storyKey, contentLoaded: true)
            openingFrameFallback()
            initializeVideoIfReady()
            updateSpinner()
            return
        }
        // ⚠️ WITH STREAMING ON, THERE IS NOTHING TO WAIT FOR. The clip is not on disk, and the whole
        // point of the reader is that it does not need to be: the player asks for the ranges it
        // wants and they arrive behind it, starting from whatever prefix the lookahead already put
        // in the partial file. So content is "here" the moment the item mounts, which is the
        // difference between a story that starts now and one that starts after a full download.
        //
        // Off by default, so the branch below is what runs until it is turned on — see
        // `StoryVideoStream.enabled`.
        if StoryVideoStream.enabled {
            localFile = storyURL
            contentLoaded = true
            session?.update(storyKey, contentLoaded: true)
            openingFrameFallback()
            initializeVideoIfReady()
            updateSpinner()
            return
        }
        updateSpinner()
        // `loadVideo` already answers on the main thread — a hit on the main thread answers in the
        // same turn, and everything else is hopped for it.
        CacheManager().loadVideo(from: storyURL) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let file):
                self.localFile = file
            case .failure:
                // Never leave the viewer on an eternal spinner: a cache failure falls back to
                // streaming the remote url, which AVPlayer does perfectly well for an https mp4.
                self.didRetryRemote = true
                self.localFile = storyURL
            }
            self.contentLoaded = true
            self.session?.update(self.storyKey, contentLoaded: true)
            self.openingFrameFallback()
            self.initializeVideoIfReady()
            self.updateSpinner()
        }
    }

    /// THE SPINNER IS FOR FETCHING, NOT FOR EXISTING, and it is an overlay on the cover rather than
    /// a thing that replaces it. It appears 0.2s late, so a cached or preloaded story never flashes
    /// one.
    private func updateSpinner() {
        // ⚠️ A MID-CLIP STALL SHOWS IT TOO, and that is not decoration. The progress bar HOLDS while
        // a clip is stalled, so without an indicator the story simply stops with nothing on screen
        // saying why — a frozen picture under a frozen bar, which reads as the app being broken
        // rather than as the network being slow. Initial buffering is excluded by `isStalled`
        // itself, so a clip that has not started yet still shows only the fetch wheel.
        let want = (!contentLoaded || isStalled || isAwaitingFirstBytes) && !(session?.failed ?? false)
        guard want != spinnerShown else { return }
        spinnerShown = want
        guard want else {
            spinner.stopAnimating()
            spinner.alpha = 0
            return
        }
        spinner.startAnimating()
        spinner.alpha = 0
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, self.spinnerShown else { return }
            self.spinner.alpha = 1
        }
    }

    // MARK: - Teardown

    private func teardownPlayer() {
        readyObservation?.invalidate(); readyObservation = nil
        sizeObservation?.invalidate(); sizeObservation = nil
        statusObservation?.invalidate(); statusObservation = nil
        rateObservation?.invalidate(); rateObservation = nil
        if let timeObserver, let player { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        // ⚠️ BOUND TO A DIFFERENT NAME, and the shorthand is why. `if let endToken { … }` shadows the
        // property with a NON-optional local, so the clear inside the braces was assigning nil to
        // `any NSObjectProtocol` rather than to the property. That was the one thing in this whole
        // rewrite the compiler caught.
        if let token = endToken { NotificationCenter.default.removeObserver(token) }
        endToken = nil
        player?.pause()
        // ⚠️ `replaceCurrentItem(with: nil)` AND NOT JUST DROPPING THE REFERENCE. Releasing an
        // AVPlayer does not hand its decoder back promptly, and iOS caps simultaneous decoders and
        // fails SILENTLY over the cap — a player that never produces a frame, which reads as a black
        // card rather than as an error.
        player?.replaceCurrentItem(with: nil)
        playerLayer?.removeFromSuperlayer()
        playerLayer = nil
        player = nil
        // The reader is retained against its asset, so it only goes when the asset does.
        StoryVideoStream.release(streamedAsset)
        streamedAsset = nil
        didShowFirstFrame = false
    }

    /// The end of this view. Called by the store when it decides not to keep it, and by the
    /// representable when the viewer is closing.
    func teardown() {
        detach()
        teardownPlayer()
        removeFromSuperview()
    }
}
