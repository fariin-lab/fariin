//
//  Constant.swift
//  StoryUI (iOS)
//
//  Created by Tolga İskender on 29.04.2022.
//

import Foundation
import UIKit
import SwiftUI

enum Constant {
    /// THE REFERENCE APP'S OWN NUMBERS, read out of the reference implementation rather than
    /// matched by eye — an item height of 2 and an ideal spacing of 2.
    ///
    /// Ours were 3 and 5. The height was half again as tall and the gaps were two and a half times
    /// wider, and the gaps were the louder of the two: at five or ten stories they eat a real slice
    /// of the width, which is what made the strip read as a heavy dashed line instead of a thin rule.
    static let progressBarHeight: CGFloat = 2
    static var storySecond: Double = 5.0
    static let progressBarSpacing: CGFloat = 2
    
    enum UserView {
        static let hStackSpace: CGFloat = 13
        static let textSize: CGFloat = 16
        static let closeImage: String = "xmark"
    }
    
    enum MessageView {
        static let height: CGFloat = 44   // spec: 40–44pt pill (Capsule → 22pt radius)
        static let padding = EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8)
        static let cornerRadius: CGFloat = 24
        static let likeImage: String = "heart"
        static let likeImageTapped: String = "heart.fill"
        static let shareImage: String = "paperplane"
    }
    
}
