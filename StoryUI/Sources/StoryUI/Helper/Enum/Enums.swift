//
//  Enums.swift
//  StoryUI
//
//  Created by Tolga İskender on 28.03.2022.
//

import Foundation

// MARK: - StoryType
public enum StoryType: Equatable, Hashable {
    case plain(config: StoryInteractionConfig? = nil)
    case message(
        config: StoryInteractionConfig? = nil,
        emojis: [[String]]? = nil,
        placeholder: String
    )
}

// MARK: - StoryUIMediaType
public enum StoryUIMediaType: Equatable {
    case image
    case video
}

// MARK: - StoryUIMediaStateType
public enum StoryUIMediaStateType {
    case seen
    case notSeen
}

// MARK: - StoryDirectionEnum
enum StoryDirectionEnum {
    case previous
    case next
}

// DELETED HERE: `MediaState`. It was the shared player's readiness, mirrored into the story page as
// `@State` so `playVideo()` could ask whether there was anything to play — and its `.onChange` was
// one of the callers that meant nothing and called `play()` anyway, which is the ~1s in the
// "it pauses under my finger and then starts again" report. Readiness belongs to the item that owns
// the player and is read off `StoryVideoSession`.


