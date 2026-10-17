import SwiftUI
import UIKit

/// ⛔ THE CHAT'S BAR FOLLOWS A LIGHT/DARK SWITCH BOTH WAYS — owner 2026-10-17, iOS 26 only: phone
/// dark, then set to light with a chat open, and Back and the call capsule stayed dark glass until
/// the chat was reopened. `.toolbarColorScheme(scheme)` (ThreadView, 2026-09-29) fixed light -> dark,
/// but on iOS 26 a change back is not re-applied to the UIKit bar. This sets the bar's own style
/// from the page's traits while the chat is on screen, and hands it back when the chat goes.
struct NavBarStyleSync: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ vc: Controller, context: Context) { vc.apply() }

    final class Controller: UIViewController {
        override func viewDidLoad() {
            super.viewDidLoad()
            view.isUserInteractionEnabled = false
            registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Controller, _) in
                self.apply()
            }
        }
        override func viewWillAppear(_ animated: Bool) { super.viewWillAppear(animated); apply() }
        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            navigationController?.navigationBar.overrideUserInterfaceStyle = .unspecified
        }
        func apply() {
            guard let bar = navigationController?.navigationBar else { return }
            // The window's style, not this controller's: the bar override itself must not feed back.
            let style = view.window?.traitCollection.userInterfaceStyle ?? traitCollection.userInterfaceStyle
            if bar.overrideUserInterfaceStyle != style { bar.overrideUserInterfaceStyle = style }
        }
    }
}
