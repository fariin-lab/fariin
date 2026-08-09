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
