import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass
import Photos

// Direction-locked pan (Signal's DirectionalPanGestureRecognizer, AGPL-3.0). Kulan-local copy so the
// app target can use it (the StoryUI package has its own). Only begins in the allowed direction.
final class DirectionalPanGestureRecognizer: UIPanGestureRecognizer {
    enum Dir { case up, down, left, right }
    let dir: Dir
    init(direction: Dir, target: AnyObject, action: Selector) {
        self.dir = direction
        super.init(target: target, action: action)
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        if state == .possible {
            guard let touch = touches.first else { return }
            let prev = touch.previousLocation(in: view)
            let loc = touch.location(in: view)
            // Movement deltas: positive dy = finger moving DOWN, positive dx = finger moving RIGHT.
            // (The old prev-minus-loc form had every direction INVERTED — the .down dismiss pan only
            // engaged on an UP drag, so drag-down-to-close never began.)
            let dy = loc.y - prev.y
            let dx = loc.x - prev.x
            let ok: Bool = {
                if abs(dy) > abs(dx) {
                    if dir == .up, dy < 0 { return true }
                    if dir == .down, dy > 0 { return true }
                } else {
                    if dir == .left, dx < 0 { return true }
                    if dir == .right, dx > 0 { return true }
                }
                return false
            }()
            guard ok else { return }
        }
        super.touchesMoved(touches, with: event)
        if state == .began {
            let v = velocity(in: view)
            switch dir {
            case .left, .right: if abs(v.y) > abs(v.x) { state = .cancelled }
            case .up, .down: if abs(v.x) > abs(v.y) { state = .cancelled }
            }
        }
    }
}

// Full-screen photo viewer. Zoom/pan is Signal's exact ZoomableMediaView (UIScrollView), cloned 1:1.
// Drag down at rest dismisses; when opened with a gallery, swipe horizontally to page between photos
// (Photos/Signal). Chrome follows the current page.
struct ImageViewerView: View {
    let gallery: [Message]              // all images in this context (chat / media grid), oldest→newest
    let cid: String
    let suppressDismissPan: Bool        // true when a native zoom transition owns the drag-down close
    @State private var current: String  // id of the page being shown
    @Environment(\.dismiss) private var dismiss

    // Single-image entry (existing call sites): a one-page gallery.
    init(message: Message, cid: String, suppressDismissPan: Bool = false) {
        self.gallery = [message]; self.cid = cid
        self.suppressDismissPan = suppressDismissPan
        _current = State(initialValue: message.id)
    }
    // Gallery entry: swipe between all the images, starting at `message`.
    init(message: Message, in gallery: [Message], cid: String, suppressDismissPan: Bool = false) {
        self.gallery = gallery.isEmpty ? [message] : gallery
        self.cid = cid
        self.suppressDismissPan = suppressDismissPan
        _current = State(initialValue: message.id)
    }

    @State private var dim: Double = 1
    @State private var chromeHidden = false     // single-tap toggles header + toolbar (Apple Photos)
    @State private var saved = false
    @State private var saveError = false
    @State private var confirmDelete = false
    @State private var shareItems: [Any]?
    @State private var loaded: [String: UIImage] = [:]   // page id -> decrypted image

    private var message: Message { gallery.first { $0.id == current } ?? gallery[0] }
    private var isMine: Bool { message.authorId == (AuthService.shared.uid ?? "") }

    // Header title: "You" for my own photo, else the other person's name.
    private var senderName: String {
        let me = AuthService.shared.uid ?? ""
        if message.authorId == me { return "You" }
        return ConversationsRepository.shared.conversations.first { $0.id == cid }?.displayName(me) ?? ""
    }
    private var dateLine: String { message.createdAt.formatted(date: .numeric, time: .shortened) }
    private var chromeVisible: Bool { !chromeHidden && dim > 0.85 }

    var body: some View {
        ZStack {
            Color.black.opacity(dim).ignoresSafeArea()

            // Horizontal paging between photos; each page zooms/dismisses independently.
            TabView(selection: $current) {
                ForEach(gallery) { m in
                    Group {
                        if let img = loaded[m.id] {
                            ZoomImageView(image: img,
                                          onSingleTap: { withAnimation(.easeInOut(duration: 0.25)) { chromeHidden.toggle() } },
                                          onDim: { dim = $0 }, onDismiss: { dismiss() },
                                          allowsDismissPan: !suppressDismissPan)
                        } else {
                            ProgressView().tint(.white)
                                .task { await load(m) }
                        }
                    }
                    .tag(m.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()

            VStack {
                header
                Spacer()
                bottomBar
            }
            .opacity(chromeVisible ? 1 : 0)
            .allowsHitTesting(chromeVisible)
            .animation(.easeInOut(duration: 0.25), value: chromeVisible)
        }
        .alert("Couldn't save photo", isPresented: $saveError) {
            Button("OK", role: .cancel) {}
        } message: { Text("Check Photos permission and try again.") }
        .alert("Delete this photo?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                Task { await ChatService.deleteMessage(cid: cid, messageId: message.id); await MainActor.run { dismiss() } }
            }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: Binding(get: { shareItems != nil }, set: { if !$0 { shareItems = nil } })) {
            if let items = shareItems { ActivityView(items: items) }
        }
    }

    // Floating Liquid Glass header: back · You/name + date · "…" menu (Go to Chat / Save Image / Delete).
    private var header: some View {
        HStack(alignment: .center) {
            glassButton("chevron.left") { dismiss() }
            Spacer()
            VStack(spacing: 1) {
                Text(senderName).font(.subheadline.weight(.semibold))
                Text(dateLine).font(.caption2)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16).padding(.vertical, 7)
            .liquidGlass(Capsule(), interactive: false)
            Spacer()
            Menu {
                Button { save() } label: { Label("Save Image", systemImage: "square.and.arrow.down") }
                Button(role: .destructive) { confirmDelete = true } label: { Label("Delete", systemImage: "trash") }
            } label: {
                Image(systemName: "ellipsis").font(.title3.weight(.semibold)).foregroundStyle(.white)
                    .frame(width: 44, height: 44).liquidGlass(Circle(), interactive: true)
            }
        }
        .padding(.horizontal, 12).padding(.top, 4)
    }

    // Bottom toolbar: 48px real Liquid Glass circle buttons — Share · Reply · (Delete, own photos only).
    private var bottomBar: some View {
        HStack {
            barButton("square.and.arrow.up") { share() }
            Spacer()
            barButton("arrowshape.turn.up.left") { dismiss() }   // Reply: return to the chat to reply
            Spacer()
            if isMine {
                barButton("trash", tint: .red) { confirmDelete = true }
            } else {
                barButton("square.and.arrow.down") { save() }   // received photo → Save instead of Delete
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 6)
    }

    private func barButton(_ icon: String, tint: Color = .white, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 48, height: 48)
                .liquidGlass(Circle(), interactive: true)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }

    private func glassButton(_ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.title3.weight(.semibold)).foregroundStyle(.white)
                .frame(width: 44, height: 44).liquidGlass(Circle(), interactive: true)
        }
    }

    // Load order: optimistic local bytes → cached decrypted → decrypt-on-demand (per page).
    private func load(_ m: Message) async {
        if let data = m.localImageData, let ui = UIImage(data: data) { loaded[m.id] = ui; return }
        guard let u = m.imageUrl else { return }
        if let mem = DiskImageCache.shared.memoryImage(u) { loaded[m.id] = mem; return }
        if let cached = await DiskImageCache.shared.image(for: u) { loaded[m.id] = cached; return }
        // Not cached yet → download the ciphertext + decrypt (same path SecureImageView uses).
        if let url = URL(string: u), let meta = m.enc,
           let (cipher, _) = try? await URLSession.shared.data(from: url),
           let dec = await Crypto.shared.decryptBytes(cid, cipher: cipher, meta: meta) {
            loaded[m.id] = UIImage(data: dec)
        }
    }

    private func share() {
        guard let image = loaded[current] else { return }
        shareItems = [image]
    }

    private func save() {
        Task {
            guard let image = loaded[current] else { await MainActor.run { saveError = true }; return }
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else { await MainActor.run { saveError = true }; return }
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.creationRequestForAsset(from: image)
                }
                await MainActor.run {
                    withAnimation { saved = true }
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                }
            } catch { await MainActor.run { saveError = true } }
        }
    }
}

// Host VC that drives Signal's ZoomableMediaView + a drag-down-to-dismiss pan (only at min zoom).
struct ZoomImageView: UIViewControllerRepresentable {
    let image: UIImage
    var onSingleTap: () -> Void = {}
    var onDim: (Double) -> Void
    var onDismiss: () -> Void
    var allowsDismissPan: Bool = true   // false in the media editor: zoom only, no drag-to-close

    func makeUIViewController(context: Context) -> ZoomImageController {
        let vc = ZoomImageController()
        vc.image = image
        vc.onSingleTap = onSingleTap
        vc.onDim = onDim
        vc.onDismiss = onDismiss
        vc.allowsDismissPan = allowsDismissPan
        return vc
    }
    func updateUIViewController(_ uiViewController: ZoomImageController, context: Context) {
        if uiViewController.image !== image {
            uiViewController.image = image
            uiViewController.reloadImage()
        }
    }
}

final class ZoomImageController: UIViewController, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    var image: UIImage!
    var onSingleTap: (() -> Void)?
    var onDim: ((Double) -> Void)?
    var onDismiss: (() -> Void)?
    var allowsDismissPan = true

    private var scrollView: ZoomableMediaView!
    private var imageView: UIImageView!

    // Editor swaps the image (filter/crop applied) — refresh in place, keeping the zoom view.
    func reloadImage() {
        guard let imageView else { return }
        imageView.image = image
        imageView.sizeToFit()
        scrollView?.updateZoomScaleForLayout()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true
        imageView.clipsToBounds = true
        imageView.layer.allowsEdgeAntialiasing = true
        imageView.layer.minificationFilter = .trilinear
        imageView.layer.magnificationFilter = .trilinear

        scrollView = ZoomableMediaView(mediaView: imageView, onSingleTap: { [weak self] in self?.onSingleTap?() })
        scrollView.delegate = self
        view.addSubview(scrollView)
        scrollView.frame = view.bounds
        scrollView.autoresizingMask = [.flexibleWidth, .flexibleHeight]

        if allowsDismissPan {
            let dismissPan = DirectionalPanGestureRecognizer(direction: .down, target: self, action: #selector(handleDismiss(_:)))
            dismissPan.delegate = self
            scrollView.addGestureRecognizer(dismissPan)
            // NO require(toFail:) — DirectionalPan never explicitly FAILS on a non-downward move (it just
            // stays .possible), so the scroll pan waiting for its failure deadlocked and the drag-to-close
            // (and scrolling) died. Instead both run SIMULTANEOUSLY (delegate below); handleDismiss ignores
            // anything that isn't an at-rest downward drag.
        }
    }

    // Coexist with the zoom scroll pan and the horizontal page-swipe: recognize together, act only
    // when the drag is downward at minimum zoom.
    func gestureRecognizer(_ g: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        scrollView.frame = view.bounds
        scrollView.updateZoomScaleForLayout()
    }

    // MARK: UIScrollViewDelegate
    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        (scrollView as? ZoomableMediaView)?.updateZoomScaleForLayout()
        view.layoutIfNeeded()
    }

    // MARK: drag-down dismiss (only when not zoomed)
    func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        scrollView.zoomScale <= scrollView.minimumZoomScale + 0.01
    }
    // Flick-to-dismiss copied from YBImageBrowser (indulgeIn/YBImageBrowser, YBIBImageCell +
    // YBIBInteractionProfile). Only the interaction is copied: the image follows the finger and
    // shrinks toward center over height*1.2 (floor 0.35), the backdrop fades over height*0.7, and
    // release dismisses on a flick (|v.y| > 800) OR a drag past height*0.22 — else it snaps back
    // in 0.15s. Down-locked here (Signal DirectionalPan) since Kulan only closes downward.
    @objc private func handleDismiss(_ g: UIPanGestureRecognizer) {
        guard scrollView.zoomScale <= scrollView.minimumZoomScale + 0.01 else { return }
        let t = g.translation(in: view)
        let h = max(1, view.bounds.height)
        switch g.state {
        case .changed:
            // Telegram photo dismiss: the image FOLLOWS the finger 1:1 in BOTH axes (translationX/Y are
            // the raw finger delta) and shrinks only gently as it travels down, while the black backdrop
            // fades — it feels like you're physically dragging the photo away, not watching it scale off.
            let progress = min(1.0, max(0, t.y) / h)
            let scale = 1.0 - progress * 0.2                 // subtle shrink so it stays under the finger
            scrollView.transform = CGAffineTransform(translationX: t.x, y: t.y).scaledBy(x: scale, y: scale)
            onDim?(1.0 - Double(progress) * 0.85)
        case .ended, .cancelled:
            // Commit on a flick or once dragged ~18% of the height; otherwise spring back.
            if g.velocity(in: view).y > 700 || t.y > h * 0.18 {
                onDismiss?()
            } else {
                UIView.animate(withDuration: 0.28, delay: 0, usingSpringWithDamping: 0.86, initialSpringVelocity: 0) {
                    self.scrollView.transform = .identity
                }
                onDim?(1)
            }
        default: break
        }
    }
}

// Cloned from Signal-iOS SignalUI/Media/ZoomableMediaView.swift (AGPL-3.0). PureLayout + Signal CG
// helpers swapped for plain UIKit. min zoom = fit, max = fit*8, double-tap to 2x at the tap point,
// constraint-based centering, safe-area change resets zoom. Signal's exact behaviour.
final class ZoomableMediaView: UIScrollView {
    private let mediaView: UIView
    private let singleTapBlock: () -> Void
    private var topC: NSLayoutConstraint!
    private var bottomC: NSLayoutConstraint!
    private var leadingC: NSLayoutConstraint!
    private var trailingC: NSLayoutConstraint!
    private var lastSafeAreaSize: CGSize = .zero

    init(mediaView: UIView, onSingleTap: @escaping () -> Void = {}) {
        self.mediaView = mediaView
        self.singleTapBlock = onSingleTap
        super.init(frame: .zero)
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        decelerationRate = .fast
        contentInsetAdjustmentBehavior = .never
        backgroundColor = .clear

        addSubview(mediaView)
        mediaView.translatesAutoresizingMaskIntoConstraints = false
        leadingC = mediaView.leadingAnchor.constraint(equalTo: leadingAnchor)
        topC = mediaView.topAnchor.constraint(equalTo: topAnchor)
        trailingC = mediaView.trailingAnchor.constraint(equalTo: trailingAnchor)
        bottomC = mediaView.bottomAnchor.constraint(equalTo: bottomAnchor)
        NSLayoutConstraint.activate([leadingC, topC, trailingC, bottomC])

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
        let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap))
        singleTap.require(toFail: doubleTap)
        addGestureRecognizer(singleTap)
    }
    required init?(coder: NSCoder) { fatalError("Not implemented") }

    @objc private func handleDoubleTap(_ g: UIGestureRecognizer) {
        guard zoomScale == minimumZoomScale else { zoomOut(animated: true); return }
        let doubleTapZoomScale: CGFloat = 2
        let zoomWidth = bounds.width / doubleTapZoomScale
        let zoomHeight = bounds.height / doubleTapZoomScale
        let tap = g.location(in: self)
        let zoomX = max(0, tap.x - zoomWidth / doubleTapZoomScale)
        let zoomY = max(0, tap.y - zoomHeight / doubleTapZoomScale)
        let rect = CGRect(x: zoomX, y: zoomY, width: zoomWidth, height: zoomHeight)
        zoom(to: mediaView.convert(rect, from: self), animated: true)
    }
    @objc private func handleSingleTap() { singleTapBlock() }

    func updateZoomScaleForLayout() {
        let svSize = bounds.size
        let mediaSize: CGSize
        let intrinsic = mediaView.intrinsicContentSize
        if intrinsic.width > 0, intrinsic.height > 0 {
            mediaSize = intrinsic
        } else if let iv = mediaView as? UIImageView, let img = iv.image, img.size.width > 0, img.size.height > 0 {
            mediaSize = img.size
        } else {
            mediaSize = svSize
        }

        let mvSize = mediaView.frame.size
        let yOffset = max(0, (bounds.height - mvSize.height) / 2)
        let xOffset = max(0, (bounds.width - mvSize.width) / 2)
        topC.constant = yOffset
        bottomC.constant = yOffset
        leadingC.constant = xOffset
        trailingC.constant = -xOffset

        let scaleWidth = svSize.width / mediaSize.width
        let scaleHeight = svSize.height / mediaSize.height
        let minScale = min(scaleWidth, scaleHeight)
        let maxScale = minScale * 8
        minimumZoomScale = minScale
        maximumZoomScale = maxScale
        if zoomScale < minScale { zoomScale = minScale }
        else if zoomScale > maxScale { zoomScale = maxScale }

        let safe = safeAreaLayoutGuide.layoutFrame.size
        if abs(safe.width - lastSafeAreaSize.width) > 0.001 || abs(safe.height - lastSafeAreaSize.height) > 0.001 {
            zoomScale = minimumZoomScale
        }
        lastSafeAreaSize = safe
    }

    func zoomOut(animated: Bool) {
        guard zoomScale != minimumZoomScale else { return }
        setZoomScale(minimumZoomScale, animated: animated)
    }
}
