//
//  File.swift
//  
//
//  Created by Tolga İskender on 21.06.2023.
//

import Foundation

public struct StoryInteractionConfig: Equatable, Hashable {
    let showLikeButton: Bool
    /// ⛔ THE REPOST MARK, LEFT OF THE HEART — owner's spec, 2026-09-11, with the footer he is
    /// matching photographed: the message field, then the two-looping-arrows repost glyph, then the
    /// heart.
    ///
    /// ⚠️ THE HOST DECIDES, NOT THIS PACKAGE. Whether a story may be passed on is a question about
    /// its audience, its flags and whether its author has blocked the viewer — none of which this
    /// package knows or should. The app answers it once (`StoryShareRights`) and hands the answer
    /// down as this flag.
    let showRepostButton: Bool
    
    public init(showLikeButton: Bool = false, showRepostButton: Bool = false) {
        self.showLikeButton = showLikeButton
        self.showRepostButton = showRepostButton
    }
    
}
