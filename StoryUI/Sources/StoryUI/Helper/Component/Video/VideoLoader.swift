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
        guard let url = url else { return }
        cacheManager.loadVideo(from: url) { [weak self] result in
            switch result {
            case .success(let url):
                self?.setupPlayer(url)
            case .failure(let error):
                // Never leave the viewer on an eternal spinner: AVPlayer streams https mp4s
                // fine, so a cache failure falls back to playing the remote URL directly.
                print(error)
                DispatchQueue.main.async { self?.setupPlayer(validatedUrl) }
            }
        }
    }

}

//MARK: - Configure

private extension PlayerView {
    func setupPlayer(_ url: URL) {
        // Stories are sound-on media (WhatsApp/Instagram): .playback plays through the ringer
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
