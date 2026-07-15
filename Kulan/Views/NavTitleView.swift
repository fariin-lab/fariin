import SwiftUI
import UIKit

// NOTE: the old `NavTitleView` UIViewRepresentable (which installed the avatar+name as the UIKit
// `navigationItem.titleView`) was REMOVED. Mutating the navigation item externally fought SwiftUI's
// NavigationStack reconciler in an unbounded loop — SwiftUI cleared the titleView on every nav update, a
// KVO re-added it, each re-add forced `-[UINavigationBar _redisplayItems]` → SwiftUI re-ran its nav update
// → repeat. That loop burned ~71% CPU for 126s and hung the app on exit (0x8BADF00D). The chat header is
// now a NATIVE `.topBarLeading` toolbar item (see ThreadView.chatToolbar), which SwiftUI owns — no fight.
//
// Only the small helper below survives, because SignalMediaDismiss still uses it.

extension UIView {
    var owningViewController: UIViewController? {
        var responder: UIResponder? = self
        while let current = responder {
            if let vc = current as? UIViewController { return vc }
            responder = current.next
        }
        return nil
    }
}
