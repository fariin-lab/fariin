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
    /// ⛔ THE "CAN'T REPLY" LINE, DRAWN IN THE CARD — owner 2026-10-16: swiping to the next person
    /// turned the story but the locked bar stayed still. The host drew it as an overlay on the
    /// whole viewer; drawn here, in the card's own bottom row where the reply pill sits on other
    /// stories, it turns with the cube. nil = no line (the host decides when replies are closed).
    let lockedText: String?
    /// A button in that same bottom row ("Learn more"), set by the host for an official story. It
    /// takes the place of the locked line and opens `actionURL` through `StoryLinkOpener`.
    let actionTitle: String?
    let actionURL: URL?

    public init(showLikeButton: Bool = false, showRepostButton: Bool = false, lockedText: String? = nil,
                actionTitle: String? = nil, actionURL: URL? = nil) {
        self.showLikeButton = showLikeButton
        self.showRepostButton = showRepostButton
        self.lockedText = lockedText
        self.actionTitle = actionTitle
        self.actionURL = actionURL
    }
    
}
