//
//  File.swift
//  
//
//  Created by Tolga İskender on 1.05.2022.
//

import Foundation

// ⚠️ SIX VIDEO NOTIFICATIONS ARE GONE FROM HERE, AND NONE OF THEM SHOULD COME BACK.
//
// `stopVideo`, `restartVideo`, `replaceCurrentItem`, `stopAndRestartVideo`, `storyBuffering` and
// `storyVideoFinished` all existed because a player was shared and nothing could be addressed to one
// item. Every one of them was posted with `object: nil`, so it reached EVERY mounted page, and every
// receiver had to work out whether it was the one meant — usually by comparing a clip url carried in
// `userInfo`. Two shipped bugs came from getting that comparison wrong and one from
// `replaceCurrentItem` nil-ing the player in pages that were about to be reused.
//
// An item owns its player now and each page owns a `StoryVideoSession`: the mode goes down that seam
// and the clock, the stall and the end come back up it. There is nobody left to broadcast to.
//
// `pauseStory` / `resumeStory` stay, because they are the HOST's voice — the app telling the viewer
// that a sheet went up — and the host legitimately does not know which page is current.

extension NSNotification.Name {
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
}
