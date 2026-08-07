//
//  StoryViewModel.swift
//  StoryUI (iOS)
//
//  Created by Tolga İskender on 28.04.2022.
//

import Foundation

final class StoryViewModel: ObservableObject {

    @Published var currentStoryUser: String = ""
    @Published var stories: [StoryUIModel] = []

    /// WHERE EACH PERSON WAS LEFT, FOR THIS VIEWING SESSION ONLY. Keyed by bucket id.
    ///
    /// Instagram's and Snapchat's rule, and the owner's report: swiping back to somebody you were
    /// watching two seconds ago restarted them at item 1, because the only answer the viewer had for
    /// "where does this person open" was `firstUnseenIndex()` — which falls back to 0 the moment
    /// everything of theirs is watched, and it was asked again on every bucket change rather than
    /// only on the way in.
    ///
    /// Deliberately NOT @Published: it is read when a page is built or becomes current, never
    /// rendered, and publishing it would invalidate every page on each swipe.
    ///
    /// Deliberately NOT persisted either. It dies with the viewer, which is what makes a FRESH open
    /// of a fully-watched person replay from the start, exactly as both apps do.
    var lastIndex: [String: Int] = [:]
    
    /// NEVER ZERO, and that floor is what stops the app dying.
    ///
    /// `getProgressBarFrame` divides by this. A duration of 0 made it `0.005 / 0` = INFINITY, which
    /// went straight into `timerProgress`, and the next `getCurrentIndex()` did `Int(infinity)` —
    /// which is a Swift runtime trap, not a wrong answer. EXC_BREAKPOINT on the main thread inside a
    /// GeometryReader update, which is exactly the crash report from build 463.
    ///
    /// A zero duration was always going to do this; it only became reachable when the video's length
    /// started arriving asynchronously. The caller has been fixed too, but the division is the thing
    /// that turns a bad number into a dead app, so it is guarded here as well.
    func getVideoProgressBarFrame(duration: Double) -> Double {
        let seconds = duration.isFinite && duration > 0 ? duration : Constant.storySecond
        return max(0.1, seconds * 0.1) // convert any second to between 0 - 1 second
    }
    
    func getStoryModel() -> StoryUIModel? {
        if let i = stories.firstIndex(where: { $0.id == currentStoryUser }) {
            return stories[i]
        }
        return nil
    }
    
    func getStories() -> [Story]? {
        return getStoryModel()?.stories
    }
    
    func getStory(with index: Int) -> Story? {
        return getStories()?[index]
    }
}
