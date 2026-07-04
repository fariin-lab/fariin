import SwiftUI
import UIKit

// Installs the chat header directly onto the UIKit UINavigationController that backs SwiftUI's
// NavigationStack: the avatar+name become `navigationItem.titleView`, the voice/video become
// `rightBarButtonItems`. UIKit then slides the WHOLE bar (title + buttons) off with the page on
// swipe-back — the exact effect SwiftUI's own `.toolbar` can't do (it cross-fades them = the
// "abChats" overlap). This is the SAME standard Apple API Signal uses (navigationItem.titleView);
// it is Apple's, not Signal's — no third-party / AGPL code is copied.
struct ChatNavHeader<Title: View>: UIViewControllerRepresentable {
    var title: Title
    var showCalls: Bool
    var onPhone: () -> Void
    var onVideo: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> ProbeVC {
        let vc = ProbeVC()
        vc.onReady = { [weak c = context.coordinator] nav in c?.install(on: nav) }
        return vc
    }

    func updateUIViewController(_ vc: ProbeVC, context: Context) {
        context.coordinator.parent = self
        if let nav = vc.enclosingNav() { context.coordinator.install(on: nav) }
    }

    final class Coordinator {
        var parent: ChatNavHeader
        private var titleHost: UIHostingController<AnyView>?
        init(_ parent: ChatNavHeader) { self.parent = parent }

        func install(on nav: UINavigationController) {
            guard let top = nav.topViewController else { return }

            // Left-aligned header: a full-width host with the content pinned leading, so it sits right
            // after the back button (like Signal) even though titleViews are centered by default.
            let content = AnyView(HStack(spacing: 0) { parent.title; Spacer(minLength: 0) })

            if let host = titleHost {
                host.rootView = content   // refresh name / presence / typing
                // Re-assert if SwiftUI cleared it on a nav-item update.
                if top.navigationItem.titleView !== host.view { top.navigationItem.titleView = host.view }
            } else {
                let host = UIHostingController(rootView: content)
                host.view.backgroundColor = .clear
                top.addChild(host)                 // child so SwiftUI keeps updating it
                host.didMove(toParent: top)
                titleHost = host
                top.navigationItem.titleView = host.view
            }

            // Voice + video as bar buttons (rightBarButtonItems put the first item nearest the edge,
            // so [video, phone] renders phone innermost — matching the old capsule order).
            if parent.showCalls, top.navigationItem.rightBarButtonItems?.isEmpty ?? true {
                let phone = UIBarButtonItem(image: UIImage(systemName: "phone.fill"),
                                            primaryAction: UIAction { [weak self] _ in self?.parent.onPhone() })
                let video = UIBarButtonItem(image: UIImage(systemName: "video.fill"),
                                            primaryAction: UIAction { [weak self] _ in self?.parent.onVideo() })
                phone.tintColor = .label
                video.tintColor = .label
                top.navigationItem.rightBarButtonItems = [phone, video]
            }
        }
    }
}

// A zero-size probe view controller that reports the UINavigationController it lands inside.
final class ProbeVC: UIViewController {
    var onReady: ((UINavigationController) -> Void)?
    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        if let nav = enclosingNav() { onReady?(nav) }
    }
    func enclosingNav() -> UINavigationController? {
        var p: UIViewController? = self
        while let cur = p {
            if let nav = cur as? UINavigationController { return nav }
            p = cur.parent
        }
        return navigationController
    }
}
