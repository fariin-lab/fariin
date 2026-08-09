//
//  VideoView.swift
//  StoryUI
//
//  Created by Tolga İskender on 31.03.2022.
//

import SwiftUI
import AVKit

struct VideoView: UIViewRepresentable {
    
    // MARK: Public Properties
    var videoURL: String
    /// The clip's cover, drawn blurred while it loads. Without it a video story opens on a solid
    /// black rectangle, which is the black screen the owner reported.
    var posterURL: String?
    /// The cover that needs no cache and no network — see `Story.blurThumb`.
    var blurThumb: String = ""
    @Binding var state: MediaState
    var player: AVPlayer
    let mediaState: ((MediaState, Double) -> Void)?
    
    func makeUIView(context: Context) -> PlayerView {
        let playerView = PlayerView(
            frame: .init(
                x: 0, 
                y: 0,
                width: UIScreen.main.bounds.width,
                height: UIScreen.main.bounds.height
            )
        )

        if playerView.player == nil {
            playerView.player = player
        }
        playerView.state = state
        playerView.mediaState = { state, duration in
            mediaState?(state, duration)
        }
        return playerView
    }
    
    func updateUIView(_ playerView: PlayerView, context: Context) {
        // ⚠️ RE-ATTACH THE PLAYER, because it is WEAK and something else nils it.
        //
        // `PlayerView.player` is a weak reference assigned once, in `makeUIView`. The
        // `.replaceCurrentItem` notification handler — posted on every viewer dismiss, with
        // `object: nil`, so it reaches every mounted page — sets `self.player = nil`. This view is
        // reused, so the next story handed to a view that has been through that is a chain of
        // no-ops: both `replaceCurrentItem` calls do nothing, `playerLayer.player` becomes nil,
        // `isReadyForDisplay` can never turn true, and `revealVideoIfReady` (the only thing that
        // takes the cover down on the happy path) can never pass. The result is a story that sits
        // under a loading cover for its whole declared length and then advances, and every later
        // video in that view does the same.
        //
        // Re-asserting it here costs nothing when it is already right and is the only place that
        // runs on every story change.
        if playerView.player !== player { playerView.player = player }
        playerView.state = state
        // BEFORE startVideo, always: `startVideo` puts the loading cover up immediately, and it can
        // only draw a poster it already has. The embedded thumbnail goes first of all, because it is
        // the one that is guaranteed to be here — no cache lookup, no fetch, no chance of arriving
        // after the veil has already been built with nothing in it.
        playerView.setBlurThumb(blurThumb)
        playerView.setPoster(posterURL)
        playerView.startVideo(url: URL(string: videoURL))
        playerView.mediaState = { state, duration in
            mediaState?(state, duration)
        }
    }
    
}
