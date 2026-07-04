import SwiftUI
import UIKit

// Installs the chat header onto the UIKit UINavigationController backing SwiftUI's NavigationStack:
// a PLAIN-UIKit avatar+name placed as a LEFT bar item (right after the back chevron → left-aligned
// like Signal), voice/video as rightBarButtonItems. UIKit slides the whole bar off with the page on
// swipe-back — the effect SwiftUI's `.toolbar` can't do (it cross-fades = the "abChats" overlap).
// Same Apple API Signal uses; no AGPL code.
//
// PLAIN UIKit (not a UIHostingController) on purpose: a hosting controller in the nav bar crashes
// (SIGABRT) via _UINavigationBarTitleControl's appearance-forwarding hierarchy check.
struct ChatNavHeader: UIViewControllerRepresentable {
    var name: String
    var photoURL: String?
    var showCalls: Bool
    var onTapHeader: () -> Void
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
        private var titleView: ChatTitleView?
        init(_ parent: ChatNavHeader) { self.parent = parent }

        func install(on nav: UINavigationController) {
            guard let top = nav.topViewController else { return }

            if titleView == nil {
                let tv = ChatTitleView()
                tv.onTap = { [weak self] in self?.parent.onTapHeader() }
                titleView = tv
            }
            titleView?.configure(name: parent.name, photoURL: parent.photoURL)

            // Left-aligned avatar+name AFTER the back chevron (leftItemsSupplementBackButton keeps
            // the native back button + its edge-swipe). Bar items slide with the page in UIKit.
            if top.navigationItem.leftBarButtonItems?.isEmpty ?? true, let tv = titleView {
                top.navigationItem.leftItemsSupplementBackButton = true
                top.navigationItem.leftBarButtonItems = [UIBarButtonItem(customView: tv)]
            }

            if parent.showCalls, top.navigationItem.rightBarButtonItems?.isEmpty ?? true {
                // First item sits nearest the edge → [video, phone] renders phone innermost.
                let phone = UIBarButtonItem(image: UIImage(systemName: "phone.fill"),
                                            primaryAction: UIAction { [weak self] _ in self?.parent.onPhone() })
                let video = UIBarButtonItem(image: UIImage(systemName: "video.fill"),
                                            primaryAction: UIAction { [weak self] _ in self?.parent.onVideo() })
                phone.tintColor = .label
                video.tintColor = .label
                top.navigationItem.rightBarButtonItems = [video, phone]
            }
        }
    }
}

// A zero-size probe that reports the UINavigationController it lands inside.
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

// Plain UIKit avatar + name for the nav bar (no SwiftUI hosting → no crash). Tap opens the profile.
final class ChatTitleView: UIView {
    var onTap: (() -> Void)?
    private let avatar = UIImageView()
    private let initials = UILabel()
    private let nameLabel = UILabel()
    private var currentURL: String?
    private var loadTask: Task<Void, Never>?

    override init(frame: CGRect) {
        super.init(frame: frame)
        avatar.translatesAutoresizingMaskIntoConstraints = false
        avatar.contentMode = .scaleAspectFill
        avatar.clipsToBounds = true
        avatar.layer.cornerRadius = 17
        avatar.backgroundColor = .secondarySystemFill

        initials.translatesAutoresizingMaskIntoConstraints = false
        initials.font = .systemFont(ofSize: 14, weight: .semibold)
        initials.textColor = .secondaryLabel
        initials.textAlignment = .center

        nameLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        nameLabel.textColor = .label
        nameLabel.setContentHuggingPriority(.required, for: .horizontal)

        let stack = UIStackView(arrangedSubviews: [avatar, nameLabel])
        stack.axis = .horizontal
        stack.spacing = 8
        stack.alignment = .center
        stack.isUserInteractionEnabled = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        avatar.addSubview(initials)

        NSLayoutConstraint.activate([
            avatar.widthAnchor.constraint(equalToConstant: 34),
            avatar.heightAnchor.constraint(equalToConstant: 34),
            initials.centerXAnchor.constraint(equalTo: avatar.centerXAnchor),
            initials.centerYAnchor.constraint(equalTo: avatar.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    @objc private func tapped() { onTap?() }

    func configure(name: String, photoURL: String?) {
        nameLabel.text = name
        initials.text = String(name.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased()
        guard currentURL != photoURL else { return }
        currentURL = photoURL
        loadTask?.cancel()

        guard let url = photoURL, !url.isEmpty else { avatar.image = nil; initials.isHidden = false; return }
        if let img = DiskImageCache.shared.memoryImage(url) {
            avatar.image = img; initials.isHidden = true; return
        }
        avatar.image = nil; initials.isHidden = false
        loadTask = Task { [weak self] in
            let img = await DiskImageCache.shared.image(for: url)
            await MainActor.run {
                guard let self, self.currentURL == url, let img else { return }
                self.avatar.image = img
                self.initials.isHidden = true
            }
        }
    }
}
