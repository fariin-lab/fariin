//
//  StoryUIUser.swift
//  StoryUI
//
//  Created by Tolga İskender on 28.03.2022.
//

import Foundation

public struct Story: Identifiable, Hashable {
    public var id: String
    public var mediaURL: String
    /// The small poster the story row and the card strip already show, which for a video is its
    /// cover. Optional because the library must keep working without one.
    ///
    /// It is here so the viewer has SOMETHING TRUE to draw while the real media downloads. WhatsApp,
    /// Telegram and Instagram all show a blurred version of the picture you are waiting for; none of
    /// them show a grey block, because a grey block tells you nothing and reads as broken. This is a
    /// few KB and is usually already on disk from the story row, so it lands more or less at once.
    public var previewURL: String?
    public var date: String
    public var isReady: Bool = false
    public var isLiked: Bool = false
    public var isSeen: Bool = false   // per-item seen flag (host-supplied) → viewer opens at the first UNSEEN item
    public var duration: Double = Constant.storySecond
    public var config: StoryConfiguration
    public var caption: String = ""   // overlay caption (rendered on the media, never baked in)

    public init(id: String = UUID().uuidString,
                mediaURL: String,
                previewURL: String? = nil,
                date: String,
                isLiked: Bool = false,
                isSeen: Bool = false,
                duration: Double = 5,
                caption: String = "",
                config: StoryConfiguration) {

        self.id = id
        self.mediaURL = mediaURL
        self.previewURL = previewURL
        self.date = date
        self.duration = duration
        self.config = config
        self.caption = caption
        self.isLiked = isLiked
        self.isSeen = isSeen
        // (Removed `Constant.storySecond = duration` — mutating a global per-instance leaked the
        //  last story's duration into the default for any story built without an explicit one.)
    }
}

