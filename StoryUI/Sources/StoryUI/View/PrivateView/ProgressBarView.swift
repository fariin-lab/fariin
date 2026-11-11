//
//  ProgressView.swift
//  StoryUI (iOS)
//
//  Created by Tolga İskender on 29.04.2022.
//

import SwiftUI

/// The story bar's live position, apart from the page: the bars observe it, the page body does not
/// (see `StoryDetailView.clock`), so the 20 Hz tick redraws a few capsules, not the whole page.
final class StoryProgressClock: ObservableObject {
    @Published var value: CGFloat
    init(_ value: CGFloat) { self.value = value }
}

struct ProgressBarView: View {
    @ObservedObject var clock: StoryProgressClock
    var index: Int
    
    var body: some View {
        GeometryReader { proxy in
            
            let width = proxy.size.width
            let progress = clock.value - CGFloat(index)
            let perfectProgress = min(max(progress, 0), 1)
            
            Capsule()
                // The reference implementation's unplayed-segment colour is white at 40% alpha.
                // Ours was grey at 50%, which goes muddy on a dark photo and reads as a solid bar;
                // white at 40% stays a hint of one. Its PLAYED colour is plain white, which
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
