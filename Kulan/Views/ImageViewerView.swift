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
            let dy = prev.y - loc.y
            let dx = prev.x - loc.x
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
// Drag down at rest dismisses.
struct ImageViewerView: View {
    let message: Message
    let cid: String
    @Environment(\.dismiss) private var dismiss

    @State private var uiImage: UIImage?
    @State private var dim: Double = 1
    @State private var chromeHidden = false     // single-tap toggles header + toolbar (Apple Photos)
    @State private var saved = false
    @State private var saveError = false
    @State private var confirmDelete = false
    @State private var shareItems: [Any]?

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

            if let img = uiImage {
                ZoomImageView(image: img,
                              onSingleTap: { withAnimation(.easeInOut(duration: 0.25)) { chromeHidden.toggle() } },
                              onDim: { dim = $0 }, onDismiss: { dismiss() })
                    .ignoresSafeArea()
            } else {
                ProgressView().tint(.white)
            }

            VStack {
                header
                Spacer()
                bottomBar
            }
            .opacity(chromeVisible ? 1 : 0)
            .allowsHitTesting(chromeVisible)
            .animation(.easeInOut(duration: 0.25), value: chromeVisible)
        }
        .task { await loadImage() }
        .alert("Couldn't save photo", isPresented: $saveError) {
            Button("OK", role: .cancel) {}
        } message: { Text("Check Photos permission and try again.") }
        .confirmationDialog("Delete this photo?", isPresented: $confirmDelete, titleVisibility: .visible) {
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
                Button { dismiss() } label: { Label("Go to Chat", systemImage: "bubble.left") }
                Button { save() } label: { Label("Save Image", systemImage: "square.and.arrow.down") }
                Button(role: .destructive) { confirmDelete = true } label: { Label("Delete", systemImage: "trash") }
            } label: {
                Image(systemName: "ellipsis").font(.title3.weight(.semibold)).foregroundStyle(.white)
                    .frame(width: 44, height: 44).liquidGlass(Circle(), interactive: true)
            }
        }
        .padding(.horizontal, 12).padding(.top, 4)
    }

    // Floating Liquid Glass bottom toolbar: Share · Reply · Delete.
    private var bottomBar: some View {
        HStack(spacing: 26) {
            glassButton("square.and.arrow.up") { share() }
            glassButton("arrowshape.turn.up.left") { dismiss() }   // Reply: return to the chat to reply
            glassButton("trash") { confirmDelete = true }
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
        .liquidGlass(Capsule(), interactive: false)
        .padding(.bottom, 6)
    }

    private func glassButton(_ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.title3.weight(.semibold)).foregroundStyle(.white)
                .frame(width: 44, height: 44).liquidGlass(Circle(), interactive: true)
        }
    }

    // Load order: optimistic local bytes → cached decrypted → decrypt-on-demand. This is why the
    // photo was black: the old code ONLY read imageUrl via the cache, so local (demo/optimistic)
    // images and un-cached ones never appeared.
    private func loadImage() async {
        if let data = message.localImageData, let ui = UIImage(data: data) { uiImage = ui; return }
        guard let u = message.imageUrl else { return }
        if let m = DiskImageCache.shared.memoryImage(u) { uiImage = m; return }
        if let cached = await DiskImageCache.shared.image(for: u) { uiImage = cached; return }
        // Not cached yet → download the ciphertext + decrypt (same path SecureImageView uses).
        if let url = URL(string: u), let meta = message.enc,
           let (cipher, _) = try? await URLSession.shared.data(from: url),
           let dec = await Crypto.shared.decryptBytes(cid, cipher: cipher, meta: meta) {
            uiImage = UIImage(data: dec)
        }
    }

    private func share() {
        guard let image = uiImage else { return }
        shareItems = [image]
    }

    private func save() {
        Task {
            guard let image = uiImage else { await MainActor.run { saveError = true }; return }
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

    func makeUIViewController(context: Context) -> ZoomImageController {
        let vc = ZoomImageController()
        vc.image = image
        vc.onSingleTap = onSingleTap
        vc.onDim = onDim
        vc.onDismiss = onDismiss
        return vc
    }
    func updateUIViewController(_ uiViewController: ZoomImageController, context: Context) {}
}

final class ZoomImageController: UIViewController, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    var image: UIImage!
    var onSingleTap: (() -> Void)?
    var onDim: ((Double) -> Void)?
    var onDismiss: (() -> Void)?

    private var scrollView: ZoomableMediaView!
    private var imageView: UIImageView!

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

        let dismissPan = DirectionalPanGestureRecognizer(direction: .down, target: self, action: #selector(handleDismiss(_:)))
        dismissPan.delegate = self
        scrollView.addGestureRecognizer(dismissPan)
        scrollView.panGestureRecognizer.require(toFail: dismissPan)
    }

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
    @objc private func handleDismiss(_ g: UIPanGestureRecognizer) {
        guard scrollView.zoomScale <= scrollView.minimumZoomScale + 0.01 else { return }
        let t = g.translation(in: view)
        switch g.state {
        case .changed:
            let ty: CGFloat = max(0, t.y)
            scrollView.transform = CGAffineTransform(translationX: t.x * CGFloat(0.4), y: ty)
            let progress: Double = min(1.0, Double(ty) / 400.0)
            onDim?(1.0 - progress * 0.7)
        case .ended, .cancelled:
            if t.y > 120 || g.velocity(in: view).y > 800 {
                onDismiss?()
            } else {
                UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.8, initialSpringVelocity: 0) {
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
