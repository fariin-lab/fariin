//
//  StoryPlaybackResume.swift
//  StoryUI
//
//  Where a video story's playback was, in seconds, for the length of ONE viewer session.
//
//  His report (2026-08-08): a 50s video playing at 20s, scroll up into the viewers sheet, swipe the
//  carousel to another item and back — and the video is at 0. The viewer draws one story at a time,
//  so leaving an item tears its player down and coming back builds a fresh one; without a memory,
//  fresh means the beginning. "Preserve the exact current video/player state… do not recreate or
//  reset the player" — the view IS recreated (that is the viewer's architecture and not this fix's
//  to change), so what is preserved is the state: the clip's position rides here across the gap.
//
//  Two readers, and they must agree: `PlayerView` seeks the player (`take`, one-shot — a consumed
//  position must not resurrect on the next rebuild), and `StoryDetailView` tops up the progress
//  bar's fraction (`peek`, because it reads BEFORE the player has taken). The bar counts its own
//  clock against the story's declared duration, so a resumed player under a zeroed bar would run
//  the segment ~30s past the clip's end — the two restores are one fix, not two.
//
//  Emptied when the viewer goes (`clearAll`, from the door's `closed` and the presenter's
//  dismissal belt): stories start from the beginning on a fresh open, the way every story app
//  works. Within the session, swiping away and back — the sheet's carousel or a person swipe —
//  resumes, which is his expected behaviour in as many words.
//

import Foundation

@MainActor
public enum StoryPlaybackResume {
    private static var positions: [URL: Double] = [:]

    static func remember(_ url: URL, seconds: Double) { positions[url] = seconds }
    static func peek(_ url: URL) -> Double? { positions[url] }
    static func take(_ url: URL) -> Double? { positions.removeValue(forKey: url) }

    /// The viewer is gone: a story opened later must start at its beginning.
    public static func clearAll() { positions = [:] }
}
