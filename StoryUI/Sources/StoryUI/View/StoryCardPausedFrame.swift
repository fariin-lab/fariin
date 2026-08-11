//
//  StoryCardPausedFrame.swift
//  StoryUI
//
//  TELEGRAM'S CARD, TRANSLATED — the small preview card is not a photograph of the story, it is a
//  PLAYER holding the exact frame the story is sitting on, paused.
//
//  Read from their source before any of this was written (2026-08-12, on the owner's order):
//  `StoryItemContentComponent` never captures an image of a video. When an item stops being central
//  its `UniversalVideoNode` is kept alive and merely `pause()`d — no hiding, no teardown — so the
//  last decoded frame stays on screen because the LAYER stays on screen. The frame-0 cover
//  (`StoryItemImageView`, `CachedVideoFirstFrameRepresentation`) sits permanently UNDERNEATH it
//  (`insertSubview(videoNode.view, aboveSubview: self.imageView)`) and becomes visible only if the
//  node is destroyed — which happens on a media-id change or when the card is about a screen-width
//  off centre, never merely because the card left the middle. Their framework even offers a
//  snapshot-when-gone fallback and the story code deliberately does not use it.
//
//  Why ours could not do that as it stood: we have ONE shared `AVPlayer` for the whole viewer and
//  the cards are pictures, so the moment the live layer was hidden for a swipe there was nothing
//  holding the frame. Two builds tried to fix the PHOTOGRAPH (539: ask every player, not just the
//  last one; then: decode from the file when the player refuses). He asked for Telegram's answer
//  instead, and this is it: the card gets its own player.
//
//  ⚠️ WHAT IS DELIBERATELY NOT COPIED, AND WHY. Telegram gives EVERY visible item its own live
//  video node. iOS caps how many video decoders may exist at once, and going over that cap does not
//  raise an error — players simply never produce a frame, which would turn cards black on exactly
//  the phones with the least headroom. So the pool below is capped, only clips watched into this
//  session get a player at all, and the cover still sits underneath every one of them. That is
//  their design with a fence around the one part of it we cannot afford.
//

import SwiftUI
import AVFoundation
import UIKit

/// The card players, capped and reused.
///
/// Keyed by the clip's own url, so a card that is rebuilt by SwiftUI (which happens on every scroll
/// frame) reattaches to the SAME player instead of building another one — without that this would
/// spawn a player per render and hit the decoder cap in about a second.
@MainActor
public final class StoryCardPlayerPool {
    public static let shared = StoryCardPlayerPool()
    private init() {}

    /// ⚠️ THE FENCE. Three is enough for the card you came from and its neighbours, and low enough
    /// to leave the live story's own player room to decode. Raising this is how you get black cards
    /// on older phones — the failure is silent, so it will arrive as a bug report, not a crash.
    private let limit = 3

    private var players: [String: AVPlayer] = [:]
    /// Least-recently-asked-for first.
    private var order: [String] = []

    /// A player parked on `seconds` of that clip. Never plays, never makes sound.
    func player(file: URL, key: String, seconds: Double) -> AVPlayer {
        if let existing = players[key] {
            touch(key)
            return existing
        }
        let player = AVPlayer(url: file)
        player.isMuted = true
        // ⚠️ EXACT, BOTH TOLERANCES ZERO. A seek left to its default tolerance lands on the nearest
        // KEYFRAME, which on a story clip can be seconds away — a different picture from the one he
        // was looking at, which is the complaint this whole change exists to answer.
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
        players[key] = player
        order.append(key)
        evictIfNeeded()
        return player
    }

    private func touch(_ key: String) {
        order.removeAll { $0 == key }
        order.append(key)
    }

    private func evictIfNeeded() {
        while order.count > limit, let oldest = order.first {
            order.removeFirst()
            // Emptying the item is what actually hands the decoder back; dropping the reference
            // alone leaves it to whenever the object is collected.
            players[oldest]?.replaceCurrentItem(with: nil)
            players.removeValue(forKey: oldest)
        }
    }

    /// The viewer is gone — see `StoryPlaybackResume.clearAll`, which calls this.
    public func releaseAll() {
        for (_, p) in players { p.replaceCurrentItem(with: nil) }
        players = [:]
        order = []
    }
}

/// One card's frame, held by a paused player.
///
/// Sized by the caller and clipped by the caller, exactly like the picture branch it replaces, so
/// the carousel's own geometry is untouched by this.
public struct StoryCardPausedFrame: UIViewRepresentable {
    private let file: URL
    private let key: String
    private let seconds: Double

    public init(file: URL, key: String, seconds: Double) {
        self.file = file
        self.key = key
        self.seconds = seconds
    }

    public func makeUIView(context: Context) -> PausedFrameView {
        let v = PausedFrameView()
        v.attach(StoryCardPlayerPool.shared.player(file: file, key: key, seconds: seconds))
        return v
    }

    public func updateUIView(_ uiView: PausedFrameView, context: Context) {
        uiView.attach(StoryCardPlayerPool.shared.player(file: file, key: key, seconds: seconds))
    }

    public final class PausedFrameView: UIView {
        public override class var layerClass: AnyClass { AVPlayerLayer.self }
        private var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

        func attach(_ player: AVPlayer) {
            // Re-attaching the same player would tear its layer down and rebuild it — a visible
            // blink on a view SwiftUI re-renders on every frame of a scroll.
            guard playerLayer.player !== player else { return }
            playerLayer.player = player
            // The same gravity the story card itself uses, so the frame is framed identically to
            // the picture it replaces.
            playerLayer.videoGravity = .resizeAspectFill
        }
    }
}
