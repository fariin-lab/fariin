import SwiftUI
import UIKit

// ⛔ TAP THE TAB YOU ARE ON = BACK TO THE TOP (owner 2026-11-02): halfway down the chat list, a tap
// on Chats did nothing, and the same on Calls, Stories and Settings. The reference apps and Apple's
// own apps do two things on that second tap: a page pushed on the tab goes back to its root first,
// and at the root the list scrolls to the top.
//
// The tab view posts `note` with the tab's number when its selection is set to the tab already
// selected. A tab whose stack has a `path` (Chats, Stories) empties it itself; every tab then calls
// `popOrScrollToTop()`, which works on the UIKit views under the selected tab, so the UIKit chat
// list and the SwiftUI lists are handled the same way.
@MainActor enum TabReselect {
    static let note = Notification.Name("TabReselect")

    static func post(_ tab: Int) {
        NotificationCenter.default.post(name: note, object: tab)
    }

    /// Pops the selected tab's navigation stack to its root if a page is pushed on it; otherwise
    /// scrolls that tab's main list to the top.
    static func popOrScrollToTop() {
        guard let tabs = tabBarController(), let selected = tabs.selectedViewController else { return }
        if let nav = firstNav(in: selected), nav.viewControllers.count > 1 {
            nav.popToRootViewController(animated: true)
            return
        }
        guard let scroll = mainScrollView(in: selected.view) else { return }
        let top = CGPoint(x: scroll.contentOffset.x, y: -scroll.adjustedContentInset.top)
        if scroll.contentOffset.y > top.y { scroll.setContentOffset(top, animated: true) }
    }

    private static func tabBarController() -> UITabBarController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        guard let root = scene?.windows.first(where: { $0.isKeyWindow })?.rootViewController else { return nil }
        return find(UITabBarController.self, from: root)
    }

    private static func firstNav(in vc: UIViewController) -> UINavigationController? {
        find(UINavigationController.self, from: vc)
    }

    /// Breadth-first through children, so the outermost match wins.
    private static func find<T: UIViewController>(_ type: T.Type, from root: UIViewController) -> T? {
        var queue = [root]
        while !queue.isEmpty {
            let vc = queue.removeFirst()
            if let hit = vc as? T { return hit }
            queue.append(contentsOf: vc.children)
            if let p = vc.presentedViewController, !(p is UIAlertController) { queue.append(p) }
        }
        return nil
    }

    /// The tallest visible vertical scroll view under the tab: the page's list, not a story row or
    /// a chip strip, which are short or scroll sideways.
    private static func mainScrollView(in view: UIView) -> UIScrollView? {
        var best: UIScrollView?
        var queue = [view]
        while !queue.isEmpty {
            let v = queue.removeFirst()
            if let s = v as? UIScrollView, !s.isHidden, s.window != nil,
               s.bounds.height > (best?.bounds.height ?? 0),
               s.contentSize.width <= s.bounds.width + 1 {
                best = s
            }
            queue.append(contentsOf: v.subviews)
        }
        return best
    }
}
