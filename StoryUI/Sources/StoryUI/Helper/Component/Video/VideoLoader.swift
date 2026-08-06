//
//  VideoLoader.swift
//  StoryUI (iOS)
//
//  Created by Tolga İskender on 30.04.2022.
//

import Foundation
import UIKit
import AVKit

final class PlayerView: UIView {

    // MARK: Public Properties
    weak var player: AVPlayer?
    var duration: Double = 0.0
    var state: MediaState = .notStarted
    var mediaState: ((MediaState, Double) -> ())?

    let contentView = UIView()
    /// WHAT FILLS THE BARS WHEN A CLIP DOES NOT FIT THE CARD.
    ///
    /// A photo that does not fit gets a blurred, aspect-filled copy of itself behind it — that is
    /// what `ImageLoader.backgroundImageView` is, and it is the look the owner chose. A video got
    /// `playerLayer.backgroundColor = .black` instead, so a square clip showed the editor's blurred
    /// bars right up until it was posted and then flat black ones for ever after. Same story, two
    /// different backdrops, and only one of them was the one he asked for.
    ///
    /// It is the POSTER, blurred the way `frozenVeil` blurs it: a hard downscale, because a downscale
    /// is a blur and a real Gaussian on every frame of a playing video is not free. Drawn once when
    /// the poster lands, never re-sampled.
    private let backdropView = UIImageView()

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
    /// The clip's cover, drawn blurred while it loads instead of a black rectangle. Set by the host
    /// through `VideoView`; nil simply falls back to the old black.
    var posterImage: UIImage?
    /// The poster this view was told about, so a late fetch can be dropped if the story moved on.
    private var posterURL: String?
    /// Whether we have already told the host it is buffering, so the notification is posted on the
    /// EDGE rather than on every KVO tick — `timeControlStatus` fires often.
    private var didReportBuffering = false

    /// Tell the story's progress bar to hold, or to carry on. One notification, posted only when the
    /// answer actually changes.
    private func setBuffering(_ buffering: Bool) {
        guard didReportBuffering != buffering else { return }
        didReportBuffering = buffering
        NotificationCenter.default.post(name: .storyBuffering, object: buffering)
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
        backdropView.frame = bounds
        CATransaction.commit()
        viewWithTag(999)?.frame = bounds        // the loading veil rides along
        applyGravity()
        refreshBackdrop()
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
        let fills = presentedSize.height / presentedSize.width >= bounds.height / bounds.width - 0.02
        let want: AVLayerVideoGravity = fills ? .resizeAspectFill : .resizeAspect
        guard playerLayer.videoGravity != want else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.videoGravity = want
        CATransaction.commit()
    }

    /// The blurred fill behind a letterboxed clip. Nothing to do when the video fills the card —
    /// there are no bars to fill, and an unnecessary full-size image under a playing video is a
    /// composite nobody is looking at.
    private func refreshBackdrop() {
        guard bounds.width > 1, bounds.height > 1 else { return }
        let fits = playerLayer.videoGravity == .resizeAspectFill
        guard !fits, let poster = posterImage else {
            if !backdropView.isHidden { backdropView.isHidden = true }
            return
        }
        backdropView.isHidden = false
        // Rebuilt only when the box it has to cover changes shape — this runs from layoutSubviews.
        if backdropView.image == nil || backdropSize != bounds.size {
            backdropSize = bounds.size
            backdropView.image = Self.frozenVeil(of: poster, covering: bounds.size)
        }
    }
    private var backdropSize: CGSize = .zero

    /// The observer's landing point: remember the clip's size, re-take the decision.
    fileprivate func notePresentationSize(_ s: CGSize) {
        presentedSize = s
        applyGravity()
        // The clip's own size is what decides fit vs fill, so this is the moment the backdrop is
        // either needed or not. layoutSubviews cannot be relied on to run again after it.
        refreshBackdrop()
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
        player = nil
    }

    required init?(coder: NSCoder) { nil }

    /// Hand over the clip's cover before `startVideo`, so the loading state has a picture to show.
    /// Reads the caches the prefetcher and the image loader already fill, and only fetches if both
    /// miss — the poster is a few KB and is usually already on disk from the story row.
    func setPoster(_ urlString: String?) {
        guard posterURL != urlString else { return }
        posterURL = urlString
        posterImage = nil
        guard let urlString, let u = URL(string: urlString) else { return }
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
                if self.viewWithTag(999) != nil { self.addActivityIndicatory() }
            }
        }.resume()
    }

    func startVideo(url: URL?) {
        guard let validatedUrl = url else { return }
        if self.url == url { return }
        self.url = validatedUrl
        addActivityIndicatory()
        // stop video if it's playing before video request
        stopVideo()
        didRetryRemote = false
        cachedFileInUse = nil
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
        // Streaming failed too, so there is nothing left to try. Stop claiming it is loading —
        // a black frame is honest, an endless spinner is not.
        removeActivityIndicatory()
    }

}

//MARK: - Configure

private extension PlayerView {
    func setupPlayer(_ url: URL) {
        // Stories are sound-on media: .playback plays through the ringer
        // switch. The default (.soloAmbient) muted every story video on a silenced phone.
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        self.player?.replaceCurrentItem(with: nil)
        // AN ITEM PREPARED WHILE YOU WERE WATCHING THE STORY BEFORE, if there is one. It has already
        // had its tracks loaded and its first frames decoded, so it starts on the frame rather than
        // on a beat of nothing. See StoryItemPreloader.
        self.player?.replaceCurrentItem(with: StoryItemPreloader.take(url) ?? .init(url: url))

        observation = player?.observe(\.timeControlStatus, options: [.new, .initial]) { [weak self] player, change in
            guard let self else { return }
            switch player.timeControlStatus {
            case .playing:
                self.removeActivityIndicatory()
                self.setBuffering(false)
                self.state = .started
                self.mediaState?(self.state, self.duration)
            case .waitingToPlayAtSpecifiedRate:
                // GENUINELY WAITING ON BYTES, so the progress bar must wait too. Without this the
                // segment kept counting through a stall and the story moved on while the video was
                // still trying to start — the progress desynchronisation.
                self.addActivityIndicatory()
                self.setBuffering(true)
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
                self.player?.preroll(atRate: 1) { [weak self] finished in
                    guard finished, let self, self.url == url || self.cachedFileInUse == url else { return }
                    self.removeActivityIndicatory()
                }
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
        if player?.timeControlStatus == .playing {
            player?.pause()
            player?.seek(to: .zero)
            state = .stopped
        }
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
    /// The poster as a frozen dark blur: aspect-fill at 1/8 scale (the upscale's interpolation is
    /// the blur) with the dark veil baked in. One draw, at load time, never re-sampled. The small
    /// canvas carries the aspect of the RECT IT WILL COVER — it was UIScreen's, so on the 9:16
    /// card the veil's poster painted at screen-fill zoom, a different scale from the video that
    /// replaced it, which is half of the first-paint jump.
    static func frozenVeil(of poster: UIImage, covering: CGSize) -> UIImage {
        let small = CGSize(width: max(8, covering.width / 8),
                           height: max(8, covering.height / 8))
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        return UIGraphicsImageRenderer(size: small, format: fmt).image { ctx in
            let s = max(small.width / max(poster.size.width, 1), small.height / max(poster.size.height, 1))
            let w = poster.size.width * s, h = poster.size.height * s
            poster.draw(in: CGRect(x: (small.width - w) / 2, y: (small.height - h) / 2, width: w, height: h))
            UIColor.black.withAlphaComponent(0.45).setFill()
            ctx.fill(CGRect(origin: .zero, size: small))
        }
    }

    func addActivityIndicatory() {
        removeActivityIndicatory()
        // THE VIEW'S OWN SIZE, not UIScreen's — the veil must cover exactly the card the video
        // will paint in, or the two show the same picture at two different scales.
        let w = bounds.width > 1 ? bounds.width : UIScreen.main.bounds.width
        let h = bounds.height > 1 ? bounds.height : UIScreen.main.bounds.height
        let view = UIView(frame: CGRect(x: 0, y: 0, width: w, height: h))
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.backgroundColor = .black
        view.tag = 999
        if let poster = posterImage {
            // STATIC PIXELS, NOT A LIVE MATERIAL. This used to be a UIVisualEffectView over the
            // poster, and a visual effect re-samples what is behind it EVERY FRAME and composites
            // outside its view's transform — so the moment the viewers-sheet morph scaled the card,
            // the veil shimmered and shook against the poster it was supposed to be part of (owner
            // 2026-08-05: "scroll up video blur... is shaking"). A photo story never shook because
            // ImageLoader FREEZES its blur into a bitmap when the sheet opens. The video's veil is
            // now born frozen: the poster downscaled hard (a downscale is a blur — the profile
            // poster's wash trick) and darkened once, drawn as an ordinary image that transforms
            // like every other pixel on the card.
            let iv = UIImageView(image: Self.frozenVeil(of: poster, covering: view.bounds.size))
            iv.frame = view.bounds
            iv.contentMode = .scaleAspectFill
            iv.clipsToBounds = true
            iv.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(iv)
        }
        self.addSubview(view)
        let activityView = UIActivityIndicatorView(style: .large)
        activityView.color = UIColor.lightGray.withAlphaComponent(0.7)
        activityView.frame = CGRect(x: w / 2, y: h / 2, width: .zero, height: .zero)
        view.addSubview(activityView)
        addConst(view: activityView)
        activityView.startAnimating()
    }

    func setupPlayer() {
        backgroundColor = .black
        backdropView.contentMode = .scaleAspectFill
        backdropView.clipsToBounds = true
        backdropView.isHidden = true
        self.addSubview(backdropView)      // behind everything
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
