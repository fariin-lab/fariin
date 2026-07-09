import SwiftUI
import UIKit

// Bridges a SwiftUI view into the navigation bar as the native `UINavigationItem.titleView` — the
// exact approach Signal uses. A titleView is a subview of the UINavigationBar, so it renders ON TOP
// of the bar's native blur (never covered), left-aligns after the back button, slides with the
// native swipe-back, and its tap is a native gesture — no custom overlay/blur.
//
// Usage: `.background(NavTitleView(onTap: { ... }) { avatarNameView })` in the pushed view.
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

    static func dismantleUIView(_ marker: UIView, coordinator: Coordinator) {
        coordinator.remove()   // clear our title view so nothing dangles when the chat is popped
    }

    final class Coordinator: NSObject {
        var onTap: () -> Void
        let host = UIHostingController(rootView: AnyView(EmptyView()))
        private let container = TitleContainerView()
        private weak var target: UIViewController?

        init(onTap: @escaping () -> Void) {
            self.onTap = onTap
            super.init()
            host.view.backgroundColor = .clear
            host.sizingOptions = [.intrinsicContentSize]
            host.view.translatesAutoresizingMaskIntoConstraints = false
            container.backgroundColor = .clear
            container.addSubview(host.view)
            NSLayoutConstraint.activate([
                // Left-align the avatar+name; top/bottom pinned so the container gets a real height.
                host.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                host.view.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
                host.view.topAnchor.constraint(equalTo: container.topAnchor),
                host.view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
            container.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        }

        @objc private func tapped() { onTap() }

        func install(from marker: UIView) {
            // The nav bar reads the navigation controller's TOP view controller's navigationItem —
            // target that one, not whatever intermediate host controller owns the marker.
            guard let owner = marker.owningViewController else { return }
            let vc = owner.navigationController?.topViewController ?? owner
            target = vc
            if vc.navigationItem.titleView !== container {
                vc.navigationItem.titleView = container
            }
        }

        func remove() {
            if target?.navigationItem.titleView === container { target?.navigationItem.titleView = nil }
        }
    }
}

// Full-width title container (Signal's trick): a large finite intrinsic width so the nav bar hands
// the title view the whole title area, letting its content left-align. A finite value (not
// .greatestFiniteMagnitude) avoids Auto Layout blowing up.
final class TitleContainerView: UIView {
    override var intrinsicContentSize: CGSize {
        CGSize(width: 10_000, height: UIView.noIntrinsicMetric)
    }
}

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
