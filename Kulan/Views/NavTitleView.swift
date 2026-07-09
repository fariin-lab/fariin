import SwiftUI
import UIKit

// Bridges a SwiftUI view into the navigation bar as the native `UINavigationItem.titleView` — the
// exact approach Signal uses. Because a titleView is a subview of the UINavigationBar, it renders ON
// TOP of the bar's native blur (so the blur never covers it), left-aligns after the back button, and
// slides with the native swipe-back transition — all for free, no custom overlay/blur.
//
// Usage: `.background(NavTitleView(onTap: { ... }) { avatarNameView })` anywhere in the pushed view.
// It's a zero-size marker in the SwiftUI layout; on appear it finds the owning view controller and
// installs the title view, re-asserting it if SwiftUI later clears it.
struct NavTitleView<Content: View>: UIViewRepresentable {
    var onTap: () -> Void
    @ViewBuilder var content: () -> Content

    func makeCoordinator() -> Coordinator { Coordinator(onTap: onTap) }

    func makeUIView(context: Context) -> UIView {
        let marker = UIView()
        marker.isUserInteractionEnabled = false
        marker.isHidden = true
        return marker
    }

    func updateUIView(_ marker: UIView, context: Context) {
        context.coordinator.onTap = onTap
        context.coordinator.host.rootView = AnyView(content())
        DispatchQueue.main.async { context.coordinator.install(from: marker) }
    }

    final class Coordinator: NSObject {
        var onTap: () -> Void
        let host = UIHostingController(rootView: AnyView(EmptyView()))
        private let container = FullWidthTitleView()

        init(onTap: @escaping () -> Void) {
            self.onTap = onTap
            super.init()
            host.view.backgroundColor = .clear
            host.sizingOptions = [.intrinsicContentSize]
            host.view.translatesAutoresizingMaskIntoConstraints = false
            container.backgroundColor = .clear
            container.isUserInteractionEnabled = true
            container.addSubview(host.view)
            NSLayoutConstraint.activate([
                // Left-align the avatar+name in the full-width title area (like Signal's titleView).
                host.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                host.view.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
                host.view.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            ])
            container.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        }

        @objc private func tapped() { onTap() }

        func install(from marker: UIView) {
            guard let vc = marker.owningViewController else { return }
            if host.parent == nil {
                vc.addChild(host)
                host.didMove(toParent: vc)
            }
            // Re-assert if SwiftUI cleared/replaced the title view on one of its updates.
            if vc.navigationItem.titleView !== container {
                vc.navigationItem.titleView = container
            }
        }
    }
}

// Signal's trick: a huge intrinsic width so the navigation bar hands the title view the whole title
// area (between the back button and the trailing items), letting its content left-align.
final class FullWidthTitleView: UIView {
    override var intrinsicContentSize: CGSize {
        CGSize(width: .greatestFiniteMagnitude, height: UIView.noIntrinsicMetric)
    }
}

extension UIView {
    // Walk the responder chain to the UIViewController that owns this view (the pushed hosting
    // controller), whose navigationItem is the one the nav bar renders.
    var owningViewController: UIViewController? {
        var responder: UIResponder? = self
        while let current = responder {
            if let vc = current as? UIViewController { return vc }
            responder = current.next
        }
        return nil
    }
}
