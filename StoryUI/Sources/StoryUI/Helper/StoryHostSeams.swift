//
//  StoryHostSeams.swift
//  StoryUI
//
//  The two small places where the library asks the APP a question, plus the one call the app makes
//  when the viewer goes away.
//
//  ⚠️ THIS FILE REPLACES `StoryPlaybackResume.swift`, AND ALMOST ALL OF THAT FILE IS DELETED RATHER
//  THAN MOVED. What it held was a frame bank, a separate cover cache, a memo of card-sized copies and
//  a weak map from a shared `AVPlayer` to whichever story last claimed it. Every one of those existed
//  to paper over a single player being handed clip after clip:
//
//    * `frames` / `cardFrames` — a photograph of the live clip, because a paused card could not BE a
//      player. A clip's own player stays alive and paused now, and `StoryVideoFrames` generates the
//      picture from the file at the second that player is on.
//    * `covers` / `usableCoverFrame` — a SECOND slot, added because the card's question ("where was
//      this clip") and the cover's question ("what is about to play") were fighting over one, and one
//      shipped build had the opening frame overwriting the card's. Two questions, two entry points on
//      `StoryVideoFrames`, no shared slot to fight over.
//    * `StoryPlaybackClock` — a weak `AVPlayer → URL` map so the progress bar could tell whether the
//      shared player was on the story it was drawing. A session claimed by the item view itself
//      answers that by construction.
//

import UIKit

/// A MENTION IS A PERSON, AND ONLY THE APP KNOWS PEOPLE.
///
/// Caption mentions are drawn by the library as links carrying this scheme, and the HOST resolves the
/// username and opens that profile. Keeping the resolution outside means the library never learns
/// what a username is, which is the same line every other host callback here draws.
///
/// ⚠️ IT REUSES THE APP'S OWN DEEP LINK RATHER THAN INVENTING A SCHEME. `kulan://u/<handle>` is
/// already the app's "open this person" route — the same one a shared profile link and a chat
/// @username use — so a caption mention needs NO new host code and cannot drift from what a mention
/// means everywhere else in the app: one route, one meaning.
public enum StoryMention {
    public static func url(for username: String) -> URL? {
        URL(string: "kulan://u/\(username)")
    }
}

/// A WAY FOR THE LIBRARY TO ASK THE APP FOR A POSTER IT HAS ALREADY DECODED.
///
/// A story video is hidden until its first frame exists, and what you look at until then is the
/// still underneath it. The library's own poster lookup reads `URLCache.shared` and `StoryDiskCache`,
/// both of which are ITS caches, while the app draws the stories row and the carousel through its own
/// and warms that one. For a story just posted, or one whose cover came down for the ROW rather than
/// for the viewer, both of the library's caches miss, the poster becomes a network fetch, and there
/// is nothing to hold the frame — which is the black.
///
/// So this is the seam that gives the hide-until-ready rule something to hide BEHIND. One synchronous
/// memory-only closure, installed by the app. Nil is a normal answer and falls straight through to
/// the two caches and the network exactly as before, so this can never make a poster arrive later
/// than it used to; it can only make one arrive sooner.
public enum StoryPosterSource {
    /// Must be synchronous and memory-only — it is called on the main thread on the frame a story
    /// opens, which is the whole point of it.
    public static var provider: ((String) -> UIImage?)?
}

/// WHAT THE APP CALLS WHEN THE VIEWER IS GONE.
///
/// One entry point, because the two things it does have to happen together: a retained item view
/// holds a live `AVPlayer`, and a generated frame is several megabytes. Leaving either behind after
/// the viewer closes is a story that keeps decoding in the background, or a card that opens showing
/// where a clip was in a session that has ended.
@MainActor
public enum StoryVideoHost {
    public static func viewerClosed() {
        StoryItemViewStore.retainDismounted = false
        // ⚠️ AND EXPLICITLY, NOT ONLY THROUGH THE FLAG. The flag's own `didSet` releases on a
        // true→false EDGE, and a viewer closed with the sheet already down never crosses that edge.
        // The store is empty in that case, so this is belt — but a live `AVPlayer` surviving behind
        // a chat list is not a thing to leave to an edge.
        StoryItemViewStore.releaseAll()
        StoryVideoFrames.clearAll()
    }
}
