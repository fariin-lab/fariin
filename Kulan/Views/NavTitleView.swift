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
        context.coordinator.install(from: marker)          // synchronous — install as early as possible
        DispatchQueue.main.async { context.coordinator.install(from: marker) }   // retry once laid out
    }

    static func dismantleUIView(_ marker: UIView, coordinator: Coordinator) {
        coordinator.remove()   // clear our title view so nothing dangles when the chat is popped
    }

    final class Coordinator: NSObject {
        var onTap: () -> Void
        let host = UIHostingController(rootView: AnyView(EmptyView()))
        private let container = TitleContainerView()
        private weak var target: UIViewController?
        private var observation: NSKeyValueObservation?

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
            // Target the OWNING (pushed) view controller — NOT navigationController.topViewController,
            // which during a push is still the PREVIOUS screen, so the title only landed after the
            // transition finished (it "came in late"). The owning VC's navigationItem is the one the
            // bar shows for this screen, so setting it here makes the title slide in WITH the page.
            guard let vc = marker.owningViewController else { return }
            if target !== vc {
                observation?.invalidate(); observation = nil
                target = vc
            }
            assertTitleView()
            applyBlurAppearance(to: vc)
            // SwiftUI re-manages the navigationItem on its own update cycles and clears titleView
            // (the "avatar+name sometimes gone" flicker). Observe it and immediately put ours back.
            if observation == nil, let item = target?.navigationItem {
                observation = item.observe(\.titleView, options: [.new]) { [weak self] _, _ in
                    self?.assertTitleView()
                }
            }
        }

        // ALWAYS-ON native blur (the secret): a nav bar has two backgrounds — standardAppearance (once
        // scrolled) and scrollEdgeAppearance (at the top). The scroll-edge one defaults to TRANSPARENT,
        // so the blur only showed after scrolling ("sometimes works"). Set BOTH to the system
        // default-background blur so the native iOS 26 liquid-glass blur is present in every state.
        // Re-apply only when it's been cleared (SwiftUI resets it), to avoid flicker.
        // Be IDENTICAL to the Chats-list header: the list sets no per-item appearance, so the bar uses
        // the system default (transparent at the top, blur when scrolled, no visible border). Any
        // per-navigationItem override we set here — even a "transparent" one — diverges from that and
        // showed the band/border the user kept seeing. So clear every override and inherit the native
        // default, exactly like the list. We only install the titleView (the native way to put an
        // avatar+name in the real nav bar); we never restyle the bar itself.
        private func applyBlurAppearance(to vc: UIViewController) {
            // FULLY TRANSPARENT nav bar — no material band, no separator. In dark mode the system
            // material band (systemChromeMaterial) is lighter than the pure-black chat, so its bottom
            // edge read as a hard "border" the user kept seeing. A transparent background removes the
            // band entirely: the chat scrolls seamlessly under the bar (Telegram/Signal), and the
            // glass back/avatar/name/call buttons stay legible on their own. Same in every state so no
            // border ever appears at the top edge.
            let a = UINavigationBarAppearance()
            a.configureWithTransparentBackground()
            a.backgroundColor = .clear
            a.shadowColor = .clear
            if vc.navigationItem.standardAppearance?.backgroundEffect != nil || vc.navigationItem.standardAppearance == nil {
                vc.navigationItem.standardAppearance = a
            }
            if vc.navigationItem.scrollEdgeAppearance?.backgroundEffect != nil || vc.navigationItem.scrollEdgeAppearance == nil {
                vc.navigationItem.scrollEdgeAppearance = a
            }
            if vc.navigationItem.compactAppearance?.backgroundEffect != nil || vc.navigationItem.compactAppearance == nil {
                vc.navigationItem.compactAppearance = a
            }
        }

        private func assertTitleView() {
            guard let item = target?.navigationItem, item.titleView !== container else { return }
            item.titleView = container
        }

        func remove() {
            observation?.invalidate(); observation = nil
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
