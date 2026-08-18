//
//  KeyboardManager.swift
//  
//
//  Created by Tolga İskender on 4.06.2023.
//

import Foundation
import SwiftUI
import UIKit

final class KeyboardManager: ObservableObject {
    
    @Published private(set) var currentHeight: CGFloat = 0
    @Published private(set) var isKeyboardOpen = false
    @Published private(set) var animationDuration: Double = 0.25   // ride the keyboard's own timing (no lag)
    /// The keyboard's own curve id, straight off the notification. 7 is the private one it actually
    /// travels on and is what it reports nearly every time.
    @Published private(set) var animationCurve: Int = 7

    /// ⛔ THE KEYBOARD'S CLOCK, AS THE REFERENCE APP READS IT — port of the same expression the story
    /// editor's `KeyboardWatcher` already uses. Read that one's notes before changing either.
    ///
    /// His report: tapping Reply, the bar arrives LATE and the keyboard slides up over the top of it.
    ///
    /// What the bar had was `.spring(response: animationDuration, dampingFraction: 1.0)`, and a
    /// spring's `response` is its NATURAL PERIOD, not the time it takes to arrive. A critically
    /// damped spring given the keyboard's 0.25 is still visibly moving well after the keyboard has
    /// stopped, so the keyboard wins the race every time and the pill is left underneath it. It was
    /// never a late START — it was the wrong curve, running longer than the thing it is meant to
    /// travel with.
    ///
    /// Their handler (`Display/Source/WindowContent.swift`) is a two-line dispatcher:
    ///
    ///     if duration > .ulpOfOne { if #available(iOS 26.0, *) {} else { duration = 0.5 } }
    ///     transitionCurve = (curve == 7) ? .spring : .easeInOut
    ///
    /// where their `.spring` is `UIView.AnimationOptions(rawValue: 7 << 16)` — the keyboard's private
    /// curve handed back to UIKit. SwiftUI has no door to `7 << 16`, so this uses the bezier they
    /// write out themselves where they cannot sample it either (`ListViewAnimation.swift`):
    /// `bezierPoint(0.23, 1.0, 0.32, 1.0)`.
    ///
    /// ⚠️ THE `iOS 26` BRANCH IS THEIRS AND IS NOT A TYPO. Below 26 they throw the reported duration
    /// away and force 0.5; from 26 the reported value is honoured. This app is 26, so the number the
    /// keyboard actually gives is the number used.
    var systemAnimation: Animation {
        let d = animationDuration > .ulpOfOne ? animationDuration : 0.25
        return animationCurve == 7 ? .timingCurve(0.23, 1.0, 0.32, 1.0, duration: d)
                                   : .easeInOut(duration: d)
    }

    private var notificationCenter: NotificationCenter
    
    init(center: NotificationCenter = .default) {
        notificationCenter = center
        notificationCenter.addObserver(
            self, 
            selector: #selector(keyBoardWillShow(notification:)),
            name: UIResponder.keyboardWillShowNotification,
            object: nil
        )
        notificationCenter.addObserver(
            self,
            selector: #selector(keyBoardWillHide(notification:)),
            name: UIResponder.keyboardWillHideNotification,
            object: nil
        )
    }
    
    func dismiss() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil, 
            for: nil
        )
    }
    
    deinit {
        notificationCenter.removeObserver(self)
    }
    
    @objc func keyBoardWillShow(notification: Notification) {
        if let keyboardSize = (notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue {
            animationDuration = (notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
            animationCurve = (notification.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? Int) ?? 7
            currentHeight = keyboardSize.height - UIApplication.bottomSafeAreaHeight
            isKeyboardOpen = true
        }
    }

    @objc func keyBoardWillHide(notification: Notification) {
        animationDuration = (notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
        animationCurve = (notification.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? Int) ?? 7
        isKeyboardOpen = false
        currentHeight = 0
    }
}
