import SwiftUI
import UIKit

// One sticker, drawn from the permanent disk cache.
//
// The synchronous `cached` read on init is the whole point: a sticker you have seen before must be
// on screen in the FIRST frame, both in a scrolling grid and in a chat bubble. Loading everything
// through the async path instead makes the panel flicker placeholders every time it opens, which is
// what a sticker keyboard must never do.
struct StickerImageView: View {
    let url: String
    /// Off in the picker grid: a hundred cells each fading in separately is noise, and they are
    /// nearly all cache hits anyway. On in chat bubbles, where a miss is visible.
    var fadeIn: Bool = true

    @State private var image: UIImage?
    @State private var appeared = false

    init(url: String, fadeIn: Bool = true) {
        self.url = url
        self.fadeIn = fadeIn
        _image = State(initialValue: StickerImages.cached(url))
    }

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.high)   // 512px art drawn at ~140pt: without this the edges crawl
                    .scaledToFit()
                    .opacity(appeared || !fadeIn ? 1 : 0)
            }
        }
        .task(id: url) {
            if let hit = StickerImages.cached(url) {
                image = hit
                appeared = true
                return
            }
            image = nil
            appeared = false
            let loaded = await StickerImages.load(url)
            guard !Task.isCancelled else { return }
            image = loaded
            withAnimation(.easeOut(duration: 0.15)) { appeared = true }
        }
    }
}
