import SwiftUI
import UIKit
import Photos

// MARK: - Feature-flagged interactive media viewer (Settings → Developer → alternate media-viewer toggle)
//
// A media viewer that reproduces the standard interactive-dismiss + paging INTERACTION,
// adapted to our app. It is NOT a visual reskin — it copies the mechanism:
//   • UIPageViewController paging between the gallery's images (interPageSpacing 20).
//   • Per-page zoom via the existing `ZoomableMediaView`:
//     aspect-fit → 8×, double-tap 2×, centered by constraint constants.
//   • ONE vertical `DirectionalPanGestureRecognizer` drives the dismiss:
//       - progress = clamp01( hypot(offset.x, offset.y) / 88 )                 (88pt distanceToCompletion)
//       - the media FINGER-LOCKS 1:1: center = originalCenter + raw translation (no rubber-band on move)
//       - a single constant scale toward 0.8 + a backdrop fade, both interpolated by progress
//       - on release: FINISH (dismiss) on any progress (percent complete > 0, no velocity gate),
//         else CANCEL with a 0.25s critically-damped spring (dampingRatio 1) back home.
//   • The dismiss pan only engages at minimum zoom; a horizontal intent falls through to the pager
//     (DirectionalPan self-cancels when the cross-axis velocity dominates).
//
// ADAPTATION: the reference approach flies the media back to its thumbnail via a UIKit view-controller
// transition. Our chat is SwiftUI and presents through `.fullScreenCover`, which owns its own
// present/dismiss animation, so there is no thumbnail-hero flyback here; the finished drag glides the
// media the rest of the way out and fades. Everything else (the drag feel itself) matches the reference.
// OFF keeps the existing `ImageViewerView`.

struct SignalMediaViewer: UIViewControllerRepresentable {
    let gallery: [Message]
    let startId: String
    let cid: String
    @Environment(\.dismiss) private var dismiss

    init(message: Message, in gallery: [Message] = [], cid: String) {
        let g = gallery.isEmpty ? [message] : gallery
        self.gallery = g.isEmpty ? [message] : g
        self.startId = message.id
        self.cid = cid
    }

    func makeUIViewController(context: Context) -> SignalMediaPageController {
        SignalMediaPageController(gallery: gallery, startId: startId, cid: cid, onClose: { dismiss() })
    }
    func updateUIViewController(_ vc: SignalMediaPageController, context: Context) {}
}

// MARK: - Page controller

final class SignalMediaPageController: UIPageViewController, UIPageViewControllerDataSource,
                                       UIPageViewControllerDelegate, UIGestureRecognizerDelegate {
    private let gallery: [Message]
    private let cid: String
    private let onClose: () -> Void
    private var index: Int

    private let backdrop = UIView()
    private var dismissPan: DirectionalPanGestureRecognizer!
    private var dragStartCenter: CGPoint = .zero

    // Chrome (kept OUT of the moving media so it stays put and only fades).
    private let topBar = UIView()
    private let bottomBar = UIView()
    private var chromeHidden = false

    init(gallery: [Message], startId: String, cid: String, onClose: @escaping () -> Void) {
        self.gallery = gallery
        self.cid = cid
        self.onClose = onClose
        self.index = gallery.firstIndex { $0.id == startId } ?? 0
        super.init(transitionStyle: .scroll, navigationOrientation: .horizontal,
                   options: [.interPageSpacing: 20])
    }
    required init?(coder: NSCoder) { fatalError("Not implemented") }

    override var prefersStatusBarHidden: Bool { true }

    private var currentItem: SignalMediaItemController? { viewControllers?.first as? SignalMediaItemController }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        backdrop.backgroundColor = .black
        backdrop.frame = view.bounds
        backdrop.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.insertSubview(backdrop, at: 0)

        dataSource = self
        delegate = self
        setViewControllers([makeItem(at: index)], direction: .forward, animated: false)

        // Interactive dismiss: one vertical directional pan on the page view's own view.
        dismissPan = DirectionalPanGestureRecognizer(direction: .down, target: self, action: #selector(handleDismiss(_:)))
        dismissPan.delegate = self
        view.addGestureRecognizer(dismissPan)

        buildChrome()
    }

    private func makeItem(at i: Int) -> SignalMediaItemController {
        let vc = SignalMediaItemController(message: gallery[i], cid: cid)
        vc.onSingleTap = { [weak self] in self?.toggleChrome() }
        return vc
    }

    // MARK: Paging (pages between all images in the context)

    func pageViewController(_ pv: UIPageViewController, viewControllerBefore vc: UIViewController) -> UIViewController? {
        guard let cur = vc as? SignalMediaItemController,
              let i = gallery.firstIndex(where: { $0.id == cur.message.id }), i - 1 >= 0 else { return nil }
        return makeItem(at: i - 1)
    }
    func pageViewController(_ pv: UIPageViewController, viewControllerAfter vc: UIViewController) -> UIViewController? {
        guard let cur = vc as? SignalMediaItemController,
              let i = gallery.firstIndex(where: { $0.id == cur.message.id }), i + 1 < gallery.count else { return nil }
        return makeItem(at: i + 1)
    }
    func pageViewController(_ pv: UIPageViewController, didFinishAnimating finished: Bool,
                            previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
        if completed, let cur = currentItem, let i = gallery.firstIndex(where: { $0.id == cur.message.id }) {
            index = i
        }
    }

    // MARK: Interactive dismiss — the exact math

    @objc private func handleDismiss(_ g: UIPanGestureRecognizer) {
        guard let item = currentItem, item.isAtMinZoom else { return }
        let offset = g.translation(in: view)
        let progress = max(0, min(1, hypot(offset.x, offset.y) / 88))   // clamp01(length / distanceToCompletion)

        switch g.state {
        case .began:
            dragStartCenter = item.mediaContainer.center
            setChrome(hidden: true, animated: true)

        case .changed:
            // Finger-lock 1:1: center follows the raw translation (center = fromMediaFrame.offsetBy(offset).center).
            item.mediaContainer.center = CGPoint(x: dragStartCenter.x + offset.x, y: dragStartCenter.y + offset.y)
            let scale = 1 - progress * 0.2                              // interpolate toward the constant 0.8
            item.mediaContainer.transform = CGAffineTransform(scaleX: scale, y: scale)
            backdrop.alpha = 1 - progress * 0.85

        case .ended, .cancelled:
            // Finishes on ANY progress (percent complete > 0), no velocity threshold; else cancels.
            if g.state == .ended, progress > 0 {
                let target = CGPoint(x: dragStartCenter.x + offset.x,
                                     y: view.bounds.height + item.mediaContainer.bounds.height)
                UIView.animate(withDuration: 0.25, delay: 0, usingSpringWithDamping: 1, initialSpringVelocity: 0,
                               options: [.curveEaseOut], animations: {
                    item.mediaContainer.center = target
                    self.backdrop.alpha = 0
                }, completion: { _ in self.onClose() })
            } else {
                UIView.animate(withDuration: 0.25, delay: 0, usingSpringWithDamping: 1, initialSpringVelocity: 0,
                               options: [.curveEaseOut], animations: {
                    item.mediaContainer.center = self.dragStartCenter
                    item.mediaContainer.transform = .identity
                    self.backdrop.alpha = 1
                }, completion: { _ in self.setChrome(hidden: false, animated: true) })
            }

        default: break
        }
    }

    // Only begin the dismiss pan at minimum zoom (zoomed → the scroll view pans instead).
    func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        (currentItem?.isAtMinZoom ?? true)
    }
    func gestureRecognizer(_ g: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

    // MARK: Chrome

    private func buildChrome() {
        topBar.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: view.safeAreaInsets.top + 56)
        topBar.autoresizingMask = [.flexibleWidth]
        bottomBar.frame = CGRect(x: 0, y: view.bounds.height - (view.safeAreaInsets.bottom + 64),
                                 width: view.bounds.width, height: view.safeAreaInsets.bottom + 64)
        bottomBar.autoresizingMask = [.flexibleWidth, .flexibleTopMargin]

        let back = glassButton("chevron.left"); back.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        back.frame = CGRect(x: 12, y: view.safeAreaInsets.top + 4, width: 44, height: 44)
        back.autoresizingMask = [.flexibleBottomMargin]
        topBar.addSubview(back)

        let share = glassButton("square.and.arrow.up"); share.addTarget(self, action: #selector(shareTapped), for: .touchUpInside)
        let trash = glassButton("trash"); trash.tintColor = .systemRed; trash.addTarget(self, action: #selector(deleteTapped), for: .touchUpInside)
        let bw = view.bounds.width
        share.frame = CGRect(x: 20, y: 8, width: 48, height: 48)
        trash.frame = CGRect(x: bw - 68, y: 8, width: 48, height: 48); trash.autoresizingMask = [.flexibleLeftMargin]
        bottomBar.addSubview(share); bottomBar.addSubview(trash)

        view.addSubview(topBar); view.addSubview(bottomBar)
    }

    private func glassButton(_ symbol: String) -> UIButton {
        let b = UIButton(type: .system)
        b.setImage(UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)), for: .normal)
        b.tintColor = .white
        b.backgroundColor = UIColor.white.withAlphaComponent(0.14)
        b.layer.cornerRadius = 24
        return b
    }

    private func toggleChrome() { setChrome(hidden: !chromeHidden, animated: true) }
    private func setChrome(hidden: Bool, animated: Bool) {
        chromeHidden = hidden
        let work = { self.topBar.alpha = hidden ? 0 : 1; self.bottomBar.alpha = hidden ? 0 : 1 }
        animated ? UIView.animate(withDuration: 0.25, animations: work) : work()
    }

    @objc private func closeTapped() { onClose() }
    @objc private func shareTapped() {
        guard let img = currentItem?.image else { return }
        let av = UIActivityViewController(activityItems: [img], applicationActivities: nil)
        av.popoverPresentationController?.sourceView = bottomBar
        present(av, animated: true)
    }
    @objc private func deleteTapped() {
        guard let m = currentItem?.message else { return }
        let a = UIAlertController(title: "Delete this photo?", message: nil, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
            guard let self else { return }
            Task { await ChatService.deleteMessage(cid: self.cid, messageId: m.id); await MainActor.run { self.onClose() } }
        })
        a.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(a, animated: true)
    }
}

// MARK: - Per-page controller: zoom + the media the dismiss moves

final class SignalMediaItemController: UIViewController, UIScrollViewDelegate {
    let message: Message
    let cid: String
    var onSingleTap: (() -> Void)?

    // The view the interactive dismiss translates/scales (holds the zoom scroll view + centered image).
    let mediaContainer = UIView()
    private var scrollView: ZoomableMediaView?
    private let imageView = UIImageView()
    private(set) var image: UIImage?

    var isAtMinZoom: Bool { scrollView.map { $0.zoomScale <= $0.minimumZoomScale + 0.01 } ?? true }

    init(message: Message, cid: String) {
        self.message = message; self.cid = cid
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("Not implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        mediaContainer.frame = view.bounds
        mediaContainer.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(mediaContainer)

        imageView.contentMode = .scaleAspectFit
        imageView.clipsToBounds = true
        imageView.layer.allowsEdgeAntialiasing = true
        imageView.layer.minificationFilter = .trilinear
        imageView.layer.magnificationFilter = .trilinear

        let sv = ZoomableMediaView(mediaView: imageView, onSingleTap: { [weak self] in self?.onSingleTap?() })
        sv.delegate = self
        sv.frame = mediaContainer.bounds
        sv.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        mediaContainer.addSubview(sv)
        scrollView = sv

        Task { await load() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        scrollView?.updateZoomScaleForLayout()
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        (scrollView as? ZoomableMediaView)?.updateZoomScaleForLayout()
    }

    // Load order matches ImageViewerView: optimistic local bytes → cached decrypted → decrypt on demand.
    private func load() async {
        if let data = message.localImageData, let ui = UIImage(data: data) { set(ui); return }
        guard let u = message.imageUrl else { return }
        if let mem = DiskImageCache.shared.memoryImage(u) { set(mem); return }
        if let cached = await DiskImageCache.shared.image(for: u) { set(cached); return }
        if let url = URL(string: u), let meta = message.enc,
           let (cipher, _) = try? await URLSession.shared.data(from: url),
           let dec = await Crypto.shared.decryptBytes(cid, cipher: cipher, meta: meta),
           let ui = UIImage(data: dec) {
            set(ui)
        }
    }

    private func set(_ ui: UIImage) {
        image = ui
        imageView.image = ui
        imageView.sizeToFit()
        scrollView?.updateZoomScaleForLayout()
    }
}
