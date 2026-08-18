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
    /// The card's corner, in UIKit, because a SwiftUI clip does not cut the blurred backdrop.
    /// All four of them — see `Constant.cardCornerRadius`.
    var cardCornerRadius: CGFloat = 0
    let imageIsLoaded: () -> Void

    func makeUIView(context: UIViewRepresentableContext<ImageView>) -> ImageLoader {
        return ImageLoader()
    }

    func updateUIView(_ uiView: ImageLoader, context: Context) {
        uiView.cardCornerRadius = cardCornerRadius
        uiView.loadImageWithUrl(imageURL, previewURL: previewURL, imageIsLoaded: imageIsLoaded)
    }
}
