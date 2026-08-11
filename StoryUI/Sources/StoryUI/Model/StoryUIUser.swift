//
//  User.swift
//  StoryUI (iOS)
//
//  Created by Tolga İskender on 1.05.2022.
//

import Foundation

public struct StoryUIUser: Identifiable, Hashable {
    public var id: String
    public var name: String
    public var image: String
    /// Whether this person carries the app's verification tick, as a plain answer from the host.
    ///
    /// ⚠️ A BOOL AND NOT A VIEW, and that is the package boundary rather than a shortcut. `VerifiedMark`
    /// is the app's component and reads the app's `VerificationIndex`; this library cannot see either.
    /// The host answers the question once, where it already knows, and the header draws the same glyph
    /// the app draws — so there is still exactly one place that DECIDES who is verified.
    public var isVerified: Bool

    public init(id: String = UUID().uuidString, name: String, image: String, isVerified: Bool = false) {
        self.id = id
        self.name = name
        self.image = image
        self.isVerified = isVerified
    }
}
