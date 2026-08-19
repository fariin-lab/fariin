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

    /// ⛔ THE STORY CARD'S CORNER, AND THERE IS EXACTLY ONE OF IT. HIS 2026-08-18 REPORT:
    /// "my story view has 2 type corners — image top corners and bottom corners are different, also
    /// video top and bottom corners are small", with two screenshots of the app he wants matched.
    ///
    /// There were three numbers and two SHAPES. The page's SwiftUI clip rounded all four at 12 in the
    /// `.continuous` style; the photo view rounded its own BOTTOM TWO at 24 with a plain circular
    /// `layer.cornerRadius` (`maskedCorners`); the clip's own view rounded all four at 12, also
    /// circular. So a photo showed a soft 12 on top and a hard 24 underneath — his "2 types" — and a
    /// clip showed 12 all round, which is his "small".
    ///
    /// ⚠️ MEASURED OFF HIS SCREENSHOTS, NOT CHOSEN. Fitting the arc down the left edge of the panel
    /// in both of them gives 41.7px against a panel 1183px wide — 3.5% of the width, which on a
    /// 428pt phone is 15pt, and 16 after the second measurement below. (That fit was read as proof
    /// the reference corner was CIRCULAR rather than a squircle; a 3x screenshot of one arc cannot
    /// settle that, and he has since said plainly which shape he wants. The number survives the
    /// correction because it was measured; the conclusion drawn about the style did not.)
    ///
    /// ⚠️ THE STYLE IS PART OF THE NUMBER, AND IT IS `.continuous` NOW — his 2026-08-18 report
    /// with both bottom corners circled: "not feeling smooth rounded corners, use apple, don't
    /// change my size, same size just looks smooth".
    ///
    /// A circular corner is an arc bolted onto two straight edges: curvature goes from nothing to
    /// its full value in one step, and the eye reads that step as a crease however clean the pixels
    /// are. Apple's `.continuous` corner — the shape every icon, sheet and card on the system wears
    /// — eases curvature in and out instead, which is the whole of what "smooth" means here.
    ///
    /// ⚠️ 18, AND THE NUMBER IS HIS — 2026-08-18, all four corners circled: "increase slightly,
    /// they are a little too small". I reached for 20 and he said 18, so 18 it is. The style change
    /// earlier that day had left the number where it was on his own instruction; with the smoother
    /// curve actually on screen he wanted a little more of it.
    ///
    /// Worth knowing before anybody nudges it again: a continuous corner spreads its curve about
    /// 1.5× further along each edge than a circle at the same radius, so two points here read as
    /// three on the old shape. This is the one number to move; the style is settled.
    ///
    /// ⚠️ 16, NOT 15, AND IT WAS MEASURED AGAIN. He put his own card beside theirs — "not smooth
    /// like snapchat" — and the two photographs settle it: ours fits a circle of 38.4px against
    /// their 41.7px on the same 1183px panel. About a point and a quarter short, which is why 16.
    ///
    /// ⚠️ THE OTHER HALF OF "not smooth" WAS NOT THE NUMBER AT ALL — see `ImageLoader.applyCornerMask`.
    /// The media view and the page were BOTH cutting the same curve, and two antialiased edges on one
    /// arc multiply their coverage, so the boundary pixels came out at a quarter strength and the
    /// curve read as hard and slightly ragged. One mask cuts it now.
    static let cardCornerRadius: CGFloat = 18

    enum UserView {
        static let hStackSpace: CGFloat = 13
        static let textSize: CGFloat = 16
        static let closeImage: String = "xmark"
    }
    
    enum MessageView {
        static let height: CGFloat = 44   // spec: 40–44pt pill (Capsule → 22pt radius)
        /// The send circle beside the pill. 40, his call 2026-08-19, after seeing it at the pill's
        /// full 44 — a hair smaller than the field reads as a button next to it rather than a second
        /// field. Its own number so the two can be tuned apart.
        static let sendSize: CGFloat = 40
        static let padding = EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8)
        static let cornerRadius: CGFloat = 24
        static let likeImage: String = "heart"
        static let likeImageTapped: String = "heart.fill"
        static let shareImage: String = "paperplane"
    }
    
}
