import SwiftUI
import UIKit

/// ⛔ THE TAB BAR COMES BACK WITH THE BACK SLIDE (owner 2026-11-12, screen recording: after leaving a
/// chat the chat list slid in with no tab bar, then the bar popped in about 0.4 s later and pushed
/// the "Things you can do" card up). The chat hides the bar with `.toolbar(.hidden, for: .tabBar)`,
/// and SwiftUI shows it again only once the pop has finished. This tells the tab bar controller to
/// show it as the pop starts, riding the same transition, and hides it again if a Back swipe is
/// cancelled. Only on the way back to the stack's root (the chat list), where the bar belongs.
struct TabBarReturnsWithPop: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Watcher { Watcher() }
    func updateUIViewController(_ vc: Watcher, context: Context) {}

    final class Watcher: UIViewController {
        override func loadView() {
            view = UIView()
            view.isUserInteractionEnabled = false
            view.backgroundColor = .clear
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            // The page this sits in: the controller directly inside the navigation controller.
            var page: UIViewController = self
            while let up = page.parent, !(up is UINavigationController) { page = up }
            guard let nav = page.navigationController, page.isMovingFromParent,
                  let tabs = page.tabBarController, tabs.isTabBarHidden,
                  let coordinator = page.transitionCoordinator,
                  let root = nav.viewControllers.first,
                  coordinator.viewController(forKey: .to) === root else { return }
            coordinator.animate(alongsideTransition: { _ in
                tabs.setTabBarHidden(false, animated: false)
            })
            coordinator.notifyWhenInteractionChanges { ctx in
                if ctx.isCancelled { tabs.setTabBarHidden(true, animated: true) }
            }
        }
    }
}
