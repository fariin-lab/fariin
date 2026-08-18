//
//  StoryVideoContent.swift
//  StoryUI
//
//  The SwiftUI seam for one story item's video. Replaces `VideoView`, which handed a SHARED player
//  down into a REUSED `PlayerView` and re-pointed it at each new clip.
//

import SwiftUI
import AVKit

/// ⚠️ IDENTITY IS THE POINT OF THIS TYPE. It must be given `.id(story.mediaURL)` at the call site so
/// that a new item is a NEW view rather than the old one handed a different url.
///
/// That single fact is what removes every stale-clip guard the old player needed: `makeUIView` is
/// where a clip's player is born and `dismantleUIView` is where it dies, so there is no window in
/// which one player holds two stories' worth of state.
///
/// ⚠️ NO MODE IS PASSED THROUGH HERE, AND THAT IS DELIBERATE. The mode lives on the session, because
/// the pause that matters most arrives on a gesture's `.began` and a `@State` flip there re-renders
/// the hosted view mid-gesture. Attaching applies whatever the session already says, so an
/// imperative pause and a re-render cannot disagree. See `StoryVideoSession`.
struct StoryVideoContent: UIViewRepresentable {

    /// ⚠️ THE STORY'S ID IS THE KEY EVERYWHERE — the store, the session's claim and `.id()`. See
    /// `StoryItemVideoView.storyId` for why it is not the media url.
    let storyId: String
    let storyURL: String
    let posterURL: String?
    let blurThumb: String
    /// This page's video session: the mode going down, the clock and the end coming back.
    let session: StoryVideoSession
    /// The author asked for this story not to be copied — see `CaptureShield`. Applied on every
    /// update, not only on creation, because a view kept by `StoryItemViewStore` comes back already
    /// built and would otherwise carry the last story's answer.
    let isCaptureProtected: Bool

    func makeUIView(context: Context) -> StoryItemVideoView {
        // A STORED VIEW COMES BACK WITH ITS PLAYER AND ITS POSITION. This is the collapsed-sheet
        // case and nothing else: `StoryItemViewStore` only keeps anything while the viewers sheet is
        // engaged, so ordinary navigation always lands on the `else` and gets a fresh player, which
        // starts at zero. See the store's own note — that switch IS the restart-at-zero rule.
        if let kept = StoryItemViewStore.take(storyId) {
            kept.isCaptureProtected = isCaptureProtected
            kept.attach(to: session)
            return kept
        }
        // ⚠️ AN UNPARSEABLE URL GETS NO PLAYER AND SAYS SO. This used to substitute
        // `URL(fileURLWithPath: "/dev/null")`, which builds a view that plays nothing, reports
        // nothing and never fails — a story frozen on its cover with no spinner and no way out. A
        // view told its clip is unreachable at least marks itself failed, and the progress bar falls
        // back to the wall clock, so the story hands the screen on.
        let view = StoryItemVideoView(storyId: storyId,
                                      storyURL: URL(string: storyURL),
                                      poster: posterURL,
                                      blurThumb: blurThumb)
        view.isCaptureProtected = isCaptureProtected
        view.attach(to: session)
        return view
    }

    func updateUIView(_ view: StoryItemVideoView, context: Context) {
        view.isCaptureProtected = isCaptureProtected
        // Idempotent: binding an already-bound view re-applies the same mode and re-publishes the
        // same numbers. This runs on every re-render of the story page, which is often.
        view.attach(to: session)
    }

    static func dismantleUIView(_ view: StoryItemVideoView, coordinator: Coordinator) {
        // The store decides: kept and paused while the sheet is up, torn down otherwise.
        view.detach()
        StoryItemViewStore.keep(view)
    }
}
