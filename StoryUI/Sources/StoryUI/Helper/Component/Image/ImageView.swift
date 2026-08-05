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
    var bottomCornerRadius: CGFloat = 0   // round the card's bottom corners in UIKit (clips the blur)
    let imageIsLoaded: () -> Void

    func makeUIView(context: UIViewRepresentableContext<ImageView>) -> ImageLoader {
        return ImageLoader()
    }

    func updateUIView(_ uiView: ImageLoader, context: Context) {
        uiView.bottomCornerRadius = bottomCornerRadius
        uiView.loadImageWithUrl(imageURL, previewURL: previewURL, imageIsLoaded: imageIsLoaded)
    }
}
