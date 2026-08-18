//
//  StoryUIUser.swift
//  StoryUI
//
//  Created by Tolga İskender on 28.03.2022.
//

import Foundation

/// WHO A STORY WENT TO, as the header shows it: an SF Symbol and a word.
///
/// Per STORY, not per person, which is the point of it — an author with ten stories up posted them
/// to different audiences and the header has to say which one you are looking at (his request,
/// 2026-08-06, three reference screens).
///
/// The library is handed a finished symbol and a finished string and knows nothing else. Deciding
/// what a viewer is allowed to be told is the host's job, and this is the seam that keeps it there:
/// the author's own device turns "custom" into the list's private name, and everybody else's turns
/// it into the plain word "Custom".
public struct StoryAudienceBadge: Hashable {
    public let systemImage: String
    /// An ASSET name from the app's own catalogue, drawn instead of `systemImage` when set.
    ///
    /// The custom-audience badge is the owner's own drawing (`ic_story_folder`), and it lives in the
    /// app target rather than in this package — so the view resolves it against `Bundle.main`. Left
    /// optional and defaulted so every existing badge keeps passing an SF Symbol and nothing else in
    /// the file changes.
    public let assetImage: String?
    public let text: String
    public init(systemImage: String, assetImage: String? = nil, text: String) {
        self.systemImage = systemImage
        self.assetImage = assetImage
        self.text = text
    }
}

public struct Story: Identifiable, Hashable {
    public var id: String
    public var mediaURL: String
    /// The small poster the story row and the card strip already show, which for a video is its
    /// cover. Optional because the library must keep working without one.
    ///
    /// It is here so the viewer has SOMETHING TRUE to draw while the real media downloads. The
    /// standard messengers all show a blurred version of the picture you are waiting for; none of
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
    /// The audience line under the name. Nil draws nothing, which is what every story had before.
    public var audience: StoryAudienceBadge? = nil

    /// ⚠️ THE PICTURE THAT IS ALWAYS THERE — a base64 JPEG about 30px wide, carried INSIDE the story
    /// itself. Empty for a story posted before this existed.
    ///
    /// `previewURL` is a URL, and a URL is a promise, not a picture: it has to be found in a cache or
    /// fetched, and for a video it is the separately-uploaded `thumb.jpg` which can be missing
    /// outright. When it is not there, the viewer has NOTHING to draw while the clip decodes, so the
    /// hide-until-ready rule leaves the canvas gradient or plain black on screen — his 2026-08-09
    /// "tap left/right and the video is full blur or black, then in seconds it works", reported over
    /// and over because every fix so far has been to the loading, never to what is UNDERNEATH it.
    ///
    /// This is what the reference app does and the reason it never shows it. The reference implementation
    /// draws the cached first frame when it has one and otherwise
    /// `decodeTinyThumbnail(file.immediateThumbnailData)` blurred — thumbnail bytes that travel in
    /// the story's own data, so a cover exists on the first frame of the first visit with no cache
    /// and no network at all. A few hundred bytes buys that outright.
    public var blurThumb: String = ""

    /// HOW MANY BYTES OF THIS CLIP ARE WORTH FETCHING BEFORE IT IS WATCHED, written onto the story
    /// document at post time. Zero means "not recorded" — anything posted before the field existed —
    /// and the lookahead falls back to its own default.
    ///
    /// The reference app takes exactly this per file from the server (`preload_prefix_size`) and it
    /// is what lets a neighbour cost a few hundred KB instead of a whole clip. Only read when range
    /// streaming is on; see `StoryVideoStream`.
    public var preloadPrefix: Int64 = 0

    /// TAPPABLE AREAS OVER THE PICTURE — a Link or a Location sticker the author placed.
    ///
    /// ⚠️ THE LIBRARY IS NOT TOLD WHAT THEY ARE, ONLY WHERE AND WHAT THEY OPEN. The drawing is
    /// already in the media: a story is a flat JPEG, or a clip with the art burned into its frames,
    /// so by the time it reaches anybody a Link sticker is a photograph of a button. This is the one
    /// thing the picture could not carry.
    public var taps: [StoryTapArea] = []

    /// ⛔ THE AUTHOR ASKED FOR THIS STORY NOT TO BE COPIED, and the viewer must honour it for the
    /// whole session rather than only on the frame it opens. What iOS will and will not do about it
    /// is written down in `CaptureShield`; the short version is that a screen recording is genuinely
    /// defeated and a still screenshot is made black by a mechanism Apple has never documented.
    ///
    /// False for every story posted before the option existed, which is what those stories were.
    public var isCaptureProtected: Bool = false

    /// ⚠️ WHETHER THIS STORY MAY HAVE ITS AUDIENCE CHANGED FROM THE "…" MENU — the host's
    /// answer, never the library's.
    ///
    /// It is true for my own posted stories and false for everything else, and the two exclusions
    /// are not tidiness. A story still UPLOADING has no document to write to yet. And a ONE-TIME
    /// story's audience is spent as it is watched — being taken out of the recipient list is exactly
    /// what a single view costs — so rewriting that list would hand somebody a second look at
    /// something they have already burned. The server refuses it too; this is the half that keeps
    /// the option from being offered in the first place.
    public var canEditAudience: Bool = false

    public init(id: String = UUID().uuidString,
                mediaURL: String,
                previewURL: String? = nil,
                blurThumb: String = "",
                preloadPrefix: Int64 = 0,
                taps: [StoryTapArea] = [],
                date: String,
                isLiked: Bool = false,
                isSeen: Bool = false,
                duration: Double = 5,
                caption: String = "",
                audience: StoryAudienceBadge? = nil,
                isCaptureProtected: Bool = false,
                canEditAudience: Bool = false,
                config: StoryConfiguration) {

        self.id = id
        self.mediaURL = mediaURL
        self.previewURL = previewURL
        self.blurThumb = blurThumb
        self.preloadPrefix = preloadPrefix
        self.taps = taps
        self.date = date
        self.duration = duration
        self.config = config
        self.caption = caption
        self.audience = audience
        self.isLiked = isLiked
        self.isSeen = isSeen
        self.isCaptureProtected = isCaptureProtected
        self.canEditAudience = canEditAudience
        // (Removed `Constant.storySecond = duration` — mutating a global per-instance leaked the
        //  last story's duration into the default for any story built without an explicit one.)
    }
}



/// One tappable rectangle over a story, in the story frame's OWN terms.
///
/// ⚠️ NORMALISED 0-1, NEVER POINTS. The phone that placed it, the file it was baked into and the
/// phone showing it are three different sizes; a rectangle in points would be right on exactly one
/// of them. The centre and the size are fractions of the frame, and the turn is the one the author
/// left the sticker at.
public struct StoryTapArea: Identifiable, Hashable {
    public let id: String
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double
    public var rotation: Double   // radians
    public var url: URL

    public init(id: String = UUID().uuidString, x: Double, y: Double, w: Double, h: Double,
                rotation: Double, url: URL) {
        self.id = id
        self.x = x; self.y = y; self.w = w; self.h = h
        self.rotation = rotation
        self.url = url
    }
}
