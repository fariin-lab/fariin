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
        self.player?.replaceCurrentItem(with: .init(url: url))

        observation = player?.observe(\.timeControlStatus, options: .new) { [weak self] player, change in
            guard let self else { return }
            if player.timeControlStatus == .playing {
                self.removeActivityIndicatory()
                self.state = .started
                self.mediaState?(self.state, self.duration)
            } else if player.timeControlStatus == .waitingToPlayAtSpecifiedRate {
                self.addActivityIndicatory()
            }
        }

        // An item that cannot be played reports it HERE and nowhere else — timeControlStatus simply
        // never reaches .playing, which is silence, not an answer.
        // `.initial` too: an item that is already failed when we start watching would otherwise
        // never send a change, and never sending one is the bug.
        statusObservation = player?.currentItem?.observe(\.status, options: [.new, .initial]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            DispatchQueue.main.async { self?.handleFailedItem() }
        }

        self.player?.automaticallyWaitsToMinimizeStalling = false
        self.getVideoLength(videoURL: url)
        self.playerLayer.player = self.player
        self.playerLayer.videoGravity = .resizeAspectFill
        // Fill vs fit decided by aspect, like photos (ImageLoader.decideContentMode): a landscape/
        // wide video hard-cropped by an unconditional fill lost most of its frame — FIT those
        // (black bars), keep tall videos edge-to-edge. presentationSize is 0 until the item is
        // ready, so observe it once and default to fill.
        sizeObservation = player?.currentItem?.observe(\.presentationSize, options: [.new, .initial]) { [weak self] item, _ in
            let s = item.presentationSize
            guard let self, s.width > 0, s.height > 0 else { return }
            let screen = UIScreen.main.bounds
            let fills = s.height / s.width >= screen.height / screen.width - 0.02
            DispatchQueue.main.async { self.playerLayer.videoGravity = fills ? .resizeAspectFill : .resizeAspect }
        }
        self.playerLayer.backgroundColor = UIColor.black.cgColor
        playerLayer.removeFromSuperlayer()
        self.contentView.layer.addSublayer(self.playerLayer)
        state = .ready
        mediaState?(.ready, duration)
        addObserverToVideo()
    }

    func getVideoLength(videoURL: URL) {
        duration = AVURLAsset(url: videoURL).duration.seconds
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
        // Host asks (on story swipe-up) for the CURRENT video frame so the morph card shows where
        // the video actually is, not its first-frame poster. object = the story's previewUrl key.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(captureCurrentFrameObserver(_:)),
            name: Notification.Name("captureStoryFrame"),
            object: nil
        )
    }

    // Grab the frame at the current playback time and cache it under the story's previewUrl, so
    // StorySnapshotCache-backed cards show it. Only the ACTIVE, advanced video responds (others are
    // stopped/at zero). Fails silently → the card keeps its poster fallback.
    @objc func captureCurrentFrameObserver(_ note: Notification) {
        // `.started` STAYS. Pausing does not change this state — `pauseVideo()` never writes it — so a
        // paused-for-the-sheet player still answers, which is exactly what we want. Widening it to
        // `.ready`/`.restart` would let a NON-active loader answer and store its own frame under the
        // active story's url, which is a wrong picture rather than a missing one.
        guard let urlStr = note.object as? String,
              state == .started,
              let item = player?.currentItem else { return }
        let time = item.currentTime()
        guard time.seconds > 0.05 else { return }   // still on frame 0 → the poster is already correct
        let gen = AVAssetImageGenerator(asset: item.asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 1080, height: 1920)
        gen.requestedTimeToleranceBefore = CMTime(seconds: 0.25, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 0.25, preferredTimescale: 600)
        gen.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) { _, cg, _, result, _ in
            guard result == .succeeded, let cg else { return }
            let img = UIImage(cgImage: cg)
            DispatchQueue.main.async { StoryCompositeCache.store(img, for: urlStr) }
        }
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
    func addActivityIndicatory() {
        removeActivityIndicatory()
        let w = UIScreen.main.bounds.width
        let h = UIScreen.main.bounds.height
        let view = UIView(frame: CGRect(x: 0, y: 0, width: w, height: h))
        view.backgroundColor = .black
        view.tag = 999
        self.addSubview(view)
        let activityView = UIActivityIndicatorView(style: .large)
        activityView.color = UIColor.lightGray.withAlphaComponent(0.7)
        activityView.frame = CGRect(x: w / 2, y: h / 2, width: .zero, height: .zero)
        view.addSubview(activityView)
        addConst(view: activityView)
        activityView.startAnimating()
    }

    func setupPlayer() {
        self.addSubview(contentView)
        contentView.frame.size.width = self.frame.size.width
        contentView.frame.size.height = self.frame.size.height
        self.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            contentView.leadingAnchor.constraint(equalTo: self.leadingAnchor, constant: 0),
            contentView.rightAnchor.constraint(equalTo: self.rightAnchor, constant: 0),
            contentView.bottomAnchor.constraint(equalTo: self.safeAreaLayoutGuide.bottomAnchor, constant: 0),
            contentView.topAnchor.constraint(equalTo: self.topAnchor, constant: 0),
        ])
        playerLayer.frame = contentView.frame
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
