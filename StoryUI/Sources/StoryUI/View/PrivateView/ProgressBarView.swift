//
//  ProgressView.swift
//  StoryUI (iOS)
//
//  Created by Tolga İskender on 29.04.2022.
//

import SwiftUI

struct ProgressBarView: View {
    var timerProgress: CGFloat
    var index: Int
    
    var body: some View {
        GeometryReader { proxy in
            
            let width = proxy.size.width
            let progress = timerProgress - CGFloat(index)
            let perfectProgress = min(max(progress, 0), 1)
            
            Capsule()
                // Signal's `unplayedColor = .ows_whiteAlpha40` (StoryPlaybackProgressView.swift:16).
                // Ours was grey at 50%, which goes muddy on a dark photo and reads as a solid bar;
                // white at 40% stays a hint of one. Their PLAYED colour is `.ows_white` (:10), which
                // is what we already had — so the filled bar is left exactly as it was.
                .fill(.white.opacity(0.4))
                .overlay (
                    Capsule()
                        .fill(.white)
                        .frame(width: width * perfectProgress)
                        .animation(.linear(duration: 0.08), value: perfectProgress)   // > the 0.05s tick → steps overlap into smooth, gap-free motion
                    ,alignment: .leading
                )
        }.frame(height: Constant.progressBarHeight)
    }
}
