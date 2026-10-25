//
//  StorySound.swift
//  StoryUI
//
//  THE VIEWER'S SOUND SWITCH (owner 2026-10-26, from the reference app's story header): a speaker
//  in the header of a video story that has sound, left of the "more" mark. One switch for the whole
//  viewer, not per story, so muting one clip keeps the next one quiet too, the way theirs behaves.
//  It starts with sound on every launch (his rule: stories play through the silent switch, see
//  `StoryAudioSession`).
//
//  Which clips have sound is learned from the clip itself (its audio track), when its player is
//  built: a story posted muted has none, and no speaker is drawn for it.
//

import Foundation
import Combine

final class StorySound: ObservableObject {
    static let shared = StorySound()

    /// Every story player follows this (`StoryItemVideoView` sets `isMuted` from it).
    @Published var muted = false
    /// Story ids whose clip carries an audio track.
    @Published private(set) var withSound: Set<String> = []

    private init() {}

    /// Main thread only (the header reads it).
    func noteAudio(storyId: String, has: Bool) {
        if has { withSound.insert(storyId) } else if withSound.contains(storyId) { withSound.remove(storyId) }
    }
}
