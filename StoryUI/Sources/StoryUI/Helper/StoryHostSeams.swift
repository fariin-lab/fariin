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
    /// THE STORIES THE PREVIEW ROW LAID OUT THIS PASS — their `validIds`, published by the thing that
    /// computes it.
    ///
    /// ⚠️ IT COMES FROM THE ROW NOW, AND THAT IS THE FIX RATHER THAN THE PLUMBING.
    ///
    /// The reference app has ONE loop: the same pass that positions an item is the pass that decides
    /// the item is still valid, so what is laid out and what is retained cannot disagree. We had two
    /// answers to that one question — the row's own visibility window (their formula, verbatim) and a
    /// separate hand-written "centre ±1" on the library side. The ±1 was the narrower of the two, so
    /// a story two cards away was destroyed while the row was still drawing it: watch A, open the
    /// sheet, swipe to B then C, and A's player was torn down on the second swipe. Swiping back
    /// built a new one, and a new player starts at zero.
    ///
    /// Now there is one answer and it is the row's, which is theirs.
    public static func previewWindow(_ storyIds: Set<String>) {
        StoryItemViewStore.setWindow(storyIds)
    }

    public static func viewerClosed() {
        StoryItemViewStore.retainDismounted = false
        // ⚠️ AND EXPLICITLY, NOT ONLY THROUGH THE FLAG. The flag's own `didSet` releases on a
        // true→false EDGE, and a viewer closed with the sheet already down never crosses that edge.
        // The store is empty in that case, so this is belt — but a live `AVPlayer` surviving behind
        // a chat list is not a thing to leave to an edge.
        StoryItemViewStore.releaseAll()
        StoryVideoFrames.clearAll()
        StoryItemLayout.shared.clear()
    }

    /// WHERE EVERY STORY'S VIEW GOES THIS FRAME — the host's one loop, published for all of them.
    ///
    /// ⚠️ THIS IS THE SEAM THAT REMOVES THE SINGLE LIVE SURFACE, AND IT DELIBERATELY MOVES NUMBERS
    /// RATHER THAN VIEWS.
    ///
    /// The obvious way to give every story its own moving view is to hand the row the real story
    /// views. It is the wrong way here: the row's parent (`viewersBackdrop`) only exists while the
    /// sheet is up, so a live surface handed to it is handed to something SwiftUI destroys on
    /// collapse — plus the row's carousel opacity, its own pan and tap, and the tint sublayer order
    /// all have to be unpicked first.
    ///
    /// Nothing needs to move. The row already computes a placement for EVERY story in its loop; it
    /// simply applies most of them to its own thumbnails and hands only the central one over. Send
    /// all of them instead and the library places its own views. Layout stays where it is already
    /// correct, and the views stay where their players, identities and lifetimes are already
    /// correct — which is one loop with one placement per item, theirs, without a view changing
    /// parent.
    public static func itemPlacements(_ placements: [String: StoryItemPlacement]) {
        StoryItemLayout.shared.set(placements)
    }

    /// The pull, so an item view can tell the row state from the full-screen one without the host
    /// having to say it twice. Their `contentScaleFraction`: 0 is full screen, 1 is the row.
    public static func pullFraction(_ f: CGFloat) {
        StoryItemLayout.shared.setFraction(max(0, min(1, f)))
    }
}

/// WHERE ONE STORY'S VIEW SITS — in WINDOW coordinates, the space the host computes in.
///
/// A value rather than four writes because two things consume it and they must not each do their own
/// arithmetic: that is the exact defect that put a half-covered tint on the owner's screen, and the
/// exact defect that made a card and its crop disagree about one rectangle.
public struct StoryItemPlacement: Equatable {
    public let center: CGPoint
    public let size: CGSize
    public let cornerRadius: CGFloat

    public init(center: CGPoint, size: CGSize, cornerRadius: CGFloat) {
        self.center = center
        self.size = size
        self.cornerRadius = cornerRadius
    }
}

/// The published placements, read by the item views.
///
/// ⚠️ EMPTY MEANS "THE HOST IS NOT PLACING ITEMS", NOT "PLACE THEM AT ZERO". The library draws
/// exactly as it does today whenever this is empty, which is every path that is not the viewers
/// sheet — the full-screen viewer, the hero flight, a friend's bucket. The rewrite has to be
/// invisible everywhere it is not being used.
final class StoryItemLayout: ObservableObject {
    static let shared = StoryItemLayout()
    @Published private(set) var placements: [String: StoryItemPlacement] = [:]
    /// Their `contentScaleFraction`. 0 = the story is full screen and the library lays itself out as
    /// it always has; 1 = the row owns the layout.
    @Published private(set) var fraction: CGFloat = 0

    /// ⚠️ THE SWITCH, AND IT IS FALSE UNTIL THE ROW HAS STOPPED DRAWING ITS OWN CARDS.
    ///
    /// The two layouts cannot both be right at once. While the row draws a thumbnail per story and
    /// the morph transforms the whole card container for the pull, an item that also placed itself
    /// would wear the shrink TWICE and every story would be drawn twice over — once by the row and
    /// once here.
    ///
    /// So the item side is built, compiled and inert, and the flip is one commit: the row stops
    /// drawing cards for stories the library holds views for, `carIn` stops hiding them, the morph's
    /// sheet path stands down, and this goes true. Anything less than all of those together is a
    /// screen with two of every story on it.
    @Published private(set) var hostOwnsItems = false

    func setHostOwnsItems(_ on: Bool) {
        guard on != hostOwnsItems else { return }
        hostOwnsItems = on
    }

    func set(_ p: [String: StoryItemPlacement]) {
        guard p != placements else { return }
        placements = p
    }

    func setFraction(_ f: CGFloat) {
        guard f != fraction else { return }
        fraction = f
    }

    func clear() {
        if !placements.isEmpty { placements = [:] }
        if fraction != 0 { fraction = 0 }
        if hostOwnsItems { hostOwnsItems = false }
    }
}
