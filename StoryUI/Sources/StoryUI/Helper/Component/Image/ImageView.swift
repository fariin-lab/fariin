//
//  StoryUIImageView.swift
//  StoryUI
//
//  Created by Tolga İskender on 28.03.2022.
//

import SwiftUI
import AVKit

struct ImageView: UIViewRepresentable {

    var imageURL: String?
    /// The story's small poster, drawn blurred while the full-size media downloads instead of a grey
    /// skeleton. See `ImageLoader.showPreviewBlur`.
    var previewURL: String?
    /// ⚠️ THE COVER THAT CANNOT BE MISSING — the ~30px JPEG carried as base64 on the story document
    /// itself. `previewURL` above is a promise this view has to go and collect; this one arrived
    /// with the story, so it is the only cover that is guaranteed to be in hand at the instant an
    /// item becomes current.
    ///
    /// It was wired into the video item view and never into this one, which is why a photo with
    /// nothing cached fell through to the grey shimmer. The reference app uses its equivalent
    /// (`immediateThumbnailData`) for photos and videos alike. See `ImageLoader.seedPreviewBlur`.
    var blurThumb: String = ""
    /// The card's corner, in UIKit, because a SwiftUI clip does not cut the blurred backdrop.
    /// All four of them — see `Constant.cardCornerRadius`.
    var cardCornerRadius: CGFloat = 0
    /// The author asked for this story not to be copied — see `CaptureShield`.
    var isCaptureProtected: Bool = false
    let imageIsLoaded: () -> Void

    func makeUIView(context: UIViewRepresentableContext<ImageView>) -> ImageLoader {
        return ImageLoader()
    }

    func updateUIView(_ uiView: ImageLoader, context: Context) {
        uiView.cardCornerRadius = cardCornerRadius
        // Every update, so it holds through a pause, a swipe either way and an automatic advance.
        uiView.isCaptureProtected = isCaptureProtected
        uiView.loadImageWithUrl(imageURL, previewURL: previewURL, blurThumb: blurThumb,
                                imageIsLoaded: imageIsLoaded)
    }
}
