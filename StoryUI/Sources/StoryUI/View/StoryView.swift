//
//  StoryView.swift
//  StoryUI (iOS)
//
//  Created by Tolga İskender on 28.04.2022.
//

import SwiftUI
import AVFoundation

public struct StoryView: View {
    
    @StateObject private var viewModel = StoryViewModel()
    @Binding private var isPresented: Bool
    
    // Private properties
    private var stories: [StoryUIModel]
    private var selectedIndex: Int
 
    // Public properties
    let userClosure: UserCompletionHandler?
    let onProfile: ((StoryUIUser) -> Void)?
    let onUserChanged: ((String) -> Void)?   // fires the current bucket id on open + each page change
    let onItemSeen: ((String) -> Void)?      // fires each individual story id as it becomes visible
    let onDrag: ((CGFloat) -> Void)?         // swipe-down amount (so the host can hide its overlays)
    let showMore: Bool                      // show the header "…" dropdown menu
    let onSwipeUp: (() -> Void)?            // up-swipe → host opens the views sheet
    let onSwipeUpChanged: ((CGFloat) -> Void)?   // live upward drag amount → real-time sheet open
    let onSwipeUpEnded: ((CGFloat, CGFloat) -> Void)?   // (translation +up, velocity +up) on release
    let dismissEnabled: Bool               // install the library's native DOWN swipe-down-to-dismiss pan
    let swipeUpEnabled: Bool               // install the library's UP pan (false → host owns swipe-up)


    /// Stories and isPresented required, selectedIndex is optional default: 0
    /// - Parameters:
    ///   - stories: all stories to show
    ///   - selectedIndex: current story index selected by user
    ///   - isPresented: to hide and show for closing storyView
    ///   - onProfile: tap a story's avatar/name header → that user's profile
    public init(
        stories: [StoryUIModel],
        selectedIndex: Int = 0,
        isPresented: Binding<Bool>,
        userClosure: UserCompletionHandler? = nil,
        onProfile: ((StoryUIUser) -> Void)? = nil,
        onUserChanged: ((String) -> Void)? = nil,
        onItemSeen: ((String) -> Void)? = nil,
        onDrag: ((CGFloat) -> Void)? = nil,
        showMore: Bool = false,
        onSwipeUp: (() -> Void)? = nil,
        onSwipeUpChanged: ((CGFloat) -> Void)? = nil,
        onSwipeUpEnded: ((CGFloat, CGFloat) -> Void)? = nil,
        dismissEnabled: Bool = true,
        swipeUpEnabled: Bool = true
    ) {
        self.stories = stories
        self.selectedIndex = selectedIndex
        self._isPresented = isPresented
        self.userClosure = userClosure
        self.onProfile = onProfile
        self.onUserChanged = onUserChanged
        self.onItemSeen = onItemSeen
        self.onDrag = onDrag
        self.showMore = showMore
        self.onSwipeUp = onSwipeUp
        self.onSwipeUpChanged = onSwipeUpChanged
        self.onSwipeUpEnded = onSwipeUpEnded
        self.dismissEnabled = dismissEnabled
        self.swipeUpEnabled = swipeUpEnabled
    }
    
    public var body: some View {
        if isPresented {
            // UIKit pager owns left/right (flat slide) AND the swipe-down dismiss. The card moves in pure
            // UIKit (the pan sets the view transform directly = native smooth), so no SwiftUI offset here.
            // The down pan uses require(toFail:) on the pager scroll, so slide and dismiss never overlap.
            StoryPager(
                viewModel: viewModel,
                isPresented: $isPresented,
                userClosure: userClosure,
                onProfile: onProfile,
                onItemSeen: onItemSeen,
                showMore: showMore,
                onDragChanged: { dy in onDrag?(dy) },   // fade the host overlays as the card slides
                // Swipe-commit close: the card has ALREADY slid off in UIKit, so remove the cover with
                // NO dismissal animation. Letting the host's zoom-back transition play here re-laid-out
                // the still-mounted story content into the shrinking cover frame — image and reply bar
                // exploded across a stretched black card for ~0.3s on every fast-flick close. The hero
                // zoom-back stays for the X button / auto-close (they dismiss via other paths).
                onCommit: {
                    var t = Transaction()
                    t.disablesAnimations = true
                    withTransaction(t) { isPresented = false }
                },
                onCancel: { onDrag?(0) },               // sprang back; restore overlays
                onSwipeUp: { onSwipeUp?() },            // up-swipe → host opens the views sheet
                onSwipeUpChanged: { up in onSwipeUpChanged?(up) },
                onSwipeUpEnded: { t, v in onSwipeUpEnded?(t, v) },
                dismissEnabled: dismissEnabled,
                swipeUpEnabled: swipeUpEnabled
            )
            .ignoresSafeArea()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: viewModel.currentStoryUser) { new in onUserChanged?(new) }   // mark each viewed bucket
            .onAppear { startStory() }
            .onDisappear { stopVideo() }
        }
    }
    
    private func startStory() {
        guard !stories.isEmpty else { return }

        viewModel.stories = stories

        let index = stories.indices.contains(selectedIndex) ? selectedIndex : .zero
        let storyUser = stories[index]

        viewModel.currentStoryUser = storyUser.id

        if !storyUser.stories.isEmpty {
            viewModel.stories[index].isSeen = true
        }
    }

    private func stopVideo() {
        NotificationCenter.default.post(name: .stopVideo, object: nil)
        NotificationCenter.default.removeObserver(self)
    }
}
