//
//  StoryUIMedia.swift
//  StoryUI
//
//  Created by Tolga İskender on 28.03.2022.
//

import Foundation

public struct StoryUIModel: Identifiable, Hashable {
    public var id: String
    public var user: StoryUIUser
    public var isSeen: Bool = false
    public var isMine: Bool = false        // my own story → "…" menu shows Delete, not Hide Stories
    public var stories: [Story]

    public init(id: String = UUID().uuidString, user: StoryUIUser, isSeen: Bool = false, isMine: Bool = false, stories: [Story]) {
        self.id = id
        self.user = user
        self.isSeen = isSeen
        self.isMine = isMine
        self.stories = stories
    }
}

/// The items of ONE bucket, refreshed while the viewer is OPEN — posted as `.storyItemsReconciled`.
///
/// A mounted page holds its own `@State` copy of the bucket (that is the delete flow's architecture,
/// and this rides the same rail): when the data changes underneath an open viewer — an upload
/// finishing is the case this was built for — the host posts the bucket's fresh items and the page
/// swaps them IN PLACE, instead of the whole viewer being recreated around the person watching it.
public struct StoryItemsReconcile {
    public let bucketId: String
    public let stories: [Story]
    public init(bucketId: String, stories: [Story]) {
        self.bucketId = bucketId
        self.stories = stories
    }
}
