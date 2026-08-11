//
//  File.swift
//  
//
//  Created by Tolga İskender on 1.05.2022.
//

import Foundation

extension NSNotification.Name {
    static let stopVideo = Notification.Name("stopVideo")
    static let restartVideo = Notification.Name("restartVideo")
    static let replaceCurrentItem = Notification.Name("replaceCurrentItem")
    static let stopAndRestartVideo = Notification.Name("stopAndRestartVideo")
    // Host (app) can freeze/resume the running story+progress while it shows a sheet over the viewer.
    static let pauseStory = Notification.Name("pauseStory")
    static let resumeStory = Notification.Name("resumeStory")
    /// One bucket's items changed under an OPEN viewer (object: `StoryItemsReconcile`).
    public static let storyItemsReconciled = Notification.Name("storyItemsReconciled")
    // Seamless per-item delete: host posts deleteCurrentStoryItem (trash tap); the viewer drops the active
    // item + slides to the adjacent one in-place, then posts storyItemDeleted(object: id) for the host to
    // remove it from the database.
    static let deleteCurrentStoryItem = Notification.Name("deleteCurrentStoryItem")
    static let storyItemDeleted = Notification.Name("storyItemDeleted")
    /// The video is waiting on bytes (`object: Bool`). The progress bar holds while this is true, so
    /// a stalled clip cannot have its segment counted out from under it — the desynchronisation where
    /// a story moved on while the video was still trying to start.
    static let storyBuffering = Notification.Name("storyBuffering")
    /// The current clip played to its end (`userInfo["url"]` names it). Telegram's rule, and now
    /// ours: a VIDEO story segment is completed ONLY by the player's own end-of-clip report — the
    /// bar reads the player's clock and is capped under the boundary (`syncBarToPlayer`), so
    /// arithmetic can neither cut a clip off early nor keep the bar running after it finished.
    static let storyVideoFinished = Notification.Name("storyVideoFinished")
}
