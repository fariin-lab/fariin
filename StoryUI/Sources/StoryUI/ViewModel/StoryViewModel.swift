//
//  StoryViewModel.swift
//  StoryUI (iOS)
//
//  Created by Tolga İskender on 28.04.2022.
//

import Foundation

final class StoryViewModel: ObservableObject {

    @Published var currentStoryUser: String = "" {
        didSet { if oldValue != currentStoryUser { previousStoryUser = oldValue } }
    }
    @Published var stories: [StoryUIModel] = []

    /// WHO WE CAME FROM. Set in `currentStoryUser`'s didSet, so it is already correct by the time any
    /// page's `onChange` runs — a page cannot work out the direction of travel on its own, and asking
    /// each page to publish it would be a race between two views observing the same value.
    var previousStoryUser: String = ""

    /// WHERE EACH PERSON WAS LEFT, FOR THIS VIEWING SESSION ONLY. Keyed by bucket id.
    ///
    /// The standard messengers' rule, and the owner's report: swiping back to somebody you were
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
    
    /// WHERE A FULLY-WATCHED PERSON OPENS, when nothing is remembered about them.
    ///
    /// The reference app's rule, read from its source rather than guessed
    /// (the reference implementation's left/right tap handlers):
    ///
    ///     didTapLeft():  transitionToPreviousItem(previousContextLoadPositionIfRead: .newest)
    ///     didTapRight(): transitionToNextItem(nextContextLoadPositionIfRead: .oldest)
    ///
    /// Going BACKWARDS lands on their newest item, so reversing walks the timeline back item by item
    /// instead of dumping you at the oldest thing they posted. Going FORWARDS lands on their oldest,
    /// so a replay runs in the order it was posted. It only applies when everything of theirs is
    /// read: an unwatched item always wins, in both directions.
    ///
    /// The owner asked for exactly this without knowing it had a name: "it need to land me where [I
    /// left] or [the] last [one]".
    func startIndexForFullyRead(bucketId: String, count: Int) -> Int {
        guard count > 0 else { return 0 }
        guard let to = stories.firstIndex(where: { $0.id == bucketId }),
              let from = stories.firstIndex(where: { $0.id == previousStoryUser })
        else { return 0 }   // opened straight from the row: no direction, start at the beginning
        return to < from ? count - 1 : 0
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
