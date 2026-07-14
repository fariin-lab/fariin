import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass
import Photos

// Direction-locked pan gesture recognizer. Kulan-local copy so the
// app target can use it (the StoryUI package has its own). Only begins in the allowed direction.
final class DirectionalPanGestureRecognizer: UIPanGestureRecognizer {
    enum Dir { case up, down, left, right, vertical }   // .vertical = the dismiss config (up AND down engage)
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
                    if dir == .vertical { return true }   // any predominantly-vertical move engages
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
            case .up, .down, .vertical: if abs(v.x) > abs(v.y) { state = .cancelled }
            }
        }
    }
}

// Full-screen photo viewer. Zoom/pan uses ZoomableMediaView (UIScrollView).
// Drag down at rest dismisses; when opened with a gallery, swipe horizontally to page between photos
// (like the native photo viewer). Chrome follows the current page.
struct ImageViewerView: View {
    let gallery: [Message]              // all images in this context (chat / media grid), oldest→newest
    let cid: String
    let suppressDismissPan: Bool        // true when a native zoom transition owns the drag-down close
    @State private var current: String  // id of the page being shown
    @Environment(\.dismiss) private var dismiss

    // Pen edit → full editor → SEND: wired by the conversation (nil in profile/gallery contexts, where
    // there's no send pipeline — the pen button hides there). (data, caption, viewOnce).
    var onSendEdited: ((Data, String, Bool) -> Void)? = nil
    private struct PenEditWrap: Identifiable { let id = UUID(); let image: UIImage }
    @State private var penEdit: PenEditWrap?

    // Single-image entry (existing call sites): a one-page gallery.
    init(message: Message, cid: String, suppressDismissPan: Bool = false,
         onSendEdited: ((Data, String, Bool) -> Void)? = nil) {
        self.gallery = [message]; self.cid = cid
        self.suppressDismissPan = suppressDismissPan
        self.onSendEdited = onSendEdited
        _current = State(initialValue: message.id)
    }
    // Gallery entry: swipe between all the images, starting at `message`.
    init(message: Message, in gallery: [Message], cid: String, suppressDismissPan: Bool = false,
         onSendEdited: ((Data, String, Bool) -> Void)? = nil) {
        self.gallery = gallery.isEmpty ? [message] : gallery
        self.cid = cid
        self.suppressDismissPan = suppressDismissPan
        self.onSendEdited = onSendEdited
        _current = State(initialValue: message.id)
    }

    @State private var chromeHidden = false     // single-tap toggles header + toolbar (Apple Photos)
    @State private var saved = false
    @State private var saveError = false
    @State private var confirmDelete = false
    @State private var shareItems: [Any]?
    @State private var loaded: [String: UIImage] = [:]   // page id -> decrypted image
    @State private var pageZoom: CGFloat = 1              // current page's zoom (1 == fit); gates drag-close
    @State private var dismissing = false                 // dismiss in flight → live content hidden ONCE

    private var message: Message { gallery.first { $0.id == current } ?? gallery[0] }
    private var isMine: Bool { message.authorId == (AuthService.shared.uid ?? "") }

    // Header title: "You" for my own photo, else the other person's name.
    private var senderName: String {
        let me = AuthService.shared.uid ?? ""
        if message.authorId == me { return "You" }
        return ConversationsRepository.shared.conversations.first { $0.id == cid }?.displayName(me) ?? ""
    }
    private var dateLine: String { message.createdAt.formatted(date: .numeric, time: .shortened) }
    private var chromeVisible: Bool { !chromeHidden && !dismissing }

    var body: some View {
        // Split into pagerLayer/chromeLayer — the inline body blew the type-checker budget.
        ZStack {
            Color.black.ignoresSafeArea()
            pagerLayer
            chromeLayer
        }
        // The interactive dismiss (SignalMediaDismiss.swift): one UIKit vertical pan on the
        // presented root; on begin this live content hides ONCE and a lightweight image copy moves 1:1
        // with the finger (constant 0.8 scale cock, direct backdrop alpha, finish-on-any-progress,
        // 0.25s critically-damped spring). Replaces the old per-frame SwiftUI drag entirely.
        .opacity(dismissing ? 0 : 1)
        .overlay {
            // When a native .zoom transition owns the drag-down close (suppressDismissPan) the photo
            // shrinks back into its source bubble via matched geometry — no custom pan, exactly like the
            // story close. Otherwise the in-viewer SignalDismissHost drag is used.
            if !suppressDismissPan {
                SignalDismissHost(
                    canBegin: { pageZoom <= 1.02 },
                    media: {
                        guard let img = loaded[current] else { return nil }
                        return (mediaFitRect(img.size, in: UIScreen.main.bounds), img)
                    },
                    onHideContent: { dismissing = $0 },
                    onDismiss: { dismiss() })
            }
        }
        // Transparent presentation so the fading backdrop reveals the CONVERSATION behind.
        .presentationBackground(.clear)
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
        // Pen flow (user spec): opens straight into DRAW mode; tapping Done there lands in the SAME full
        // image editor used for fresh photos (crop, pen, HD, filters, caption — no new flow), and Send
        // delivers the edited image with everything baked in. X backs out to this viewer.
        .fullScreenCover(item: $penEdit) { wrap in
            ChatImageEditor(source: wrap.image,
                            onSend: { data, caption, _, viewOnce in
                                onSendEdited?(data, caption, viewOnce)
                                dismiss()   // back to the conversation, where the edited copy is sending
                            },
                            startDrawing: true)
        }
    }

    // Horizontal paging between photos; each page zooms/dismisses independently. EVERY page is
    // pinned to the exact full screen size (GeometryReader) so a portrait (9:16) and a landscape
    // (16:9) photo page identically — mixed aspect ratios were paging with inconsistent geometry
    // (offset/jank at the page seam). The image aspect-fits + centers WITHIN each uniform page.
    private var pagerLayer: some View {
        GeometryReader { geo in
            TabView(selection: $current) {
                ForEach(gallery) { m in
                    pagerPage(m)
                        .frame(width: geo.size.width, height: geo.size.height)   // uniform page size
                        .tag(m.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
        }
        .ignoresSafeArea()
        // Gallery prefetch: decrypt+decode the ADJACENT pages while you look at this one,
        // so swiping to the next photo is instant instead of showing a spinner.
        .onChange(of: current) { _, _ in
            prefetchNeighbors()
            pageZoom = 1   // fresh page
        }
        .task { prefetchNeighbors() }
    }

    @ViewBuilder private func pagerPage(_ m: Message) -> some View {
        if let img = loaded[m.id] {
            // Inner UIKit dismiss-pan DISABLED here — the drag-to-close is driven at the CONTAINER level
            // so it can't fight the TabView pager (the 2-day bug). ZoomImageView keeps only pinch-zoom.
            ZoomImageView(image: img,
                          onSingleTap: { withAnimation(.easeInOut(duration: 0.25)) { chromeHidden.toggle() } },
                          onDim: { _ in }, onDismiss: {},
                          allowsDismissPan: false,
                          onZoom: { pageZoom = $0 })
        } else {
            ProgressView().tint(.white)
                .task { await load(m) }
        }
    }

    private var chromeLayer: some View {
        VStack {
            header
            Spacer()
            // Album/group context: thumbnails of EVERY image in the group, current highlighted —
            // tap to jump (reference: centered strip just above the bottom bar).
            if gallery.count > 1 { thumbStrip }
            bottomBar
        }
        .opacity(chromeVisible ? 1 : 0)
        .allowsHitTesting(chromeVisible)
        .animation(.easeInOut(duration: 0.25), value: chromeVisible)
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
            .foregroundStyle(.primary)
            .padding(.horizontal, 16).padding(.vertical, 7)
            .liquidGlass(Capsule(), interactive: false)
            Spacer()
            Menu {
                Button { save() } label: { Label("Save Image", systemImage: "square.and.arrow.down") }
                Button(role: .destructive) { confirmDelete = true } label: { Label("Delete", systemImage: "trash") }
            } label: {
                Image(systemName: "ellipsis").font(.title3.weight(.semibold)).foregroundStyle(.primary)
                    .frame(width: 44, height: 44).liquidGlass(Circle(), interactive: true)
            }
        }
        .padding(.horizontal, 12).padding(.top, 4)
    }

    // Thumbnail strip (group context): small rounded thumbs of every image, the current one framed —
    // tap any to jump to it. Centered above the bottom bar (reference screenshot).
    // Split into small pieces (thumbCell / thumbImage) — the inline version blew the type-checker budget.
    private var thumbStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                ForEach(gallery) { m in thumbCell(m) }
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity)   // few thumbs → centered; many → scrolls
        }
        .frame(height: 44)
        .padding(.bottom, 8)
        .animation(.easeInOut(duration: 0.2), value: current)
    }

    private func thumbCell(_ m: Message) -> some View {
        let isCurrent: Bool = m.id == current
        let side: CGFloat = isCurrent ? 38 : 32
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        return Button {
            withAnimation(.easeInOut(duration: 0.2)) { current = m.id }
        } label: {
            thumbImage(m)
                .frame(width: side, height: side)
                .clipShape(shape)
                .overlay { if isCurrent { shape.strokeBorder(Color.white, lineWidth: 1.5) } }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private func thumbImage(_ m: Message) -> some View {
        if let img = loaded[m.id] {
            Image(uiImage: img).resizable().scaledToFill()
        } else {
            Color.white.opacity(0.15)
                .task { await load(m) }   // strip thumbs load lazily like pages
        }
    }

    // Bottom toolbar: 48px real Liquid Glass circle buttons — Share · Pen (draw on it + re-send) ·
    // (Delete own / Save received).
    private var bottomBar: some View {
        HStack {
            barButton("square.and.arrow.up") { share() }
            Spacer()
            // PEN (replaces Reply, user spec): opens the pen editor on THIS image; Done lands in the
            // FULL image editor (crop/pen/HD/…) — the same editor as a fresh photo — and Send delivers
            // the edited copy with every modification baked in. Hidden where no send pipeline exists.
            if onSendEdited != nil {
                barButton("scribble.variable") {
                    if let img = loaded[current] { penEdit = PenEditWrap(image: img) }
                }
            }
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

    // NATIVE glyph contrast (user spec): .primary adapts to the glass — black glyphs when the material
    // renders light, white when it renders dark (the hardcoded .white vanished on light glass).
    private func barButton(_ icon: String, tint: Color = .primary, _ action: @escaping () -> Void) -> some View {
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
            Image(systemName: icon).font(.title3.weight(.semibold)).foregroundStyle(.primary)
                .frame(width: 44, height: 44).liquidGlass(Circle(), interactive: true)
        }
    }

    // Pre-load the pages either side of the current one (idempotent — load() no-ops on cache hits).
    private func prefetchNeighbors() {
        guard let idx = gallery.firstIndex(where: { $0.id == current }) else { return }
        for off in [-1, 1] {
            let i = idx + off
            guard gallery.indices.contains(i) else { continue }
            let m = gallery[i]
            if loaded[m.id] == nil { Task { await load(m) } }
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

// Host VC that drives ZoomableMediaView + a drag-down-to-dismiss pan (only at min zoom).
struct ZoomImageView: UIViewControllerRepresentable {
    let image: UIImage
    var onSingleTap: () -> Void = {}
    var onDim: (Double) -> Void
    var onDismiss: () -> Void
    var allowsDismissPan: Bool = true   // false in the media editor: zoom only, no drag-to-close
    var onZoom: (CGFloat) -> Void = { _ in }   // reports live zoom scale so the container can gate drag-dismiss
    var cornerRadius: CGFloat = 0       // >0 rounds the IMAGE itself (tall media), scaled to stay visually constant
    // false in the single-image EDITOR: the zoomed photo may overflow its letterboxed canvas and cover
    // the full screen (the chrome floats over it) — the same unclipped growth as the video editor's
    // scaleEffect zoom, so at full zoom there are no top/bottom borders. Viewers keep the default clip.
    var clipsZoomOverflow: Bool = true

    func makeUIViewController(context: Context) -> ZoomImageController {
        let vc = ZoomImageController()
        vc.image = image
        vc.onSingleTap = onSingleTap
        vc.onDim = onDim
        vc.onDismiss = onDismiss
        vc.allowsDismissPan = allowsDismissPan
        vc.onZoom = onZoom
        vc.mediaCornerRadius = cornerRadius
        vc.clipsZoomOverflow = clipsZoomOverflow
        return vc
    }
    func updateUIViewController(_ uiViewController: ZoomImageController, context: Context) {
        if uiViewController.image !== image {
            uiViewController.image = image
            uiViewController.reloadImage()
        }
        uiViewController.setCornerRadius(cornerRadius)
    }
}

final class ZoomImageController: UIViewController, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    var image: UIImage!
    var onSingleTap: (() -> Void)?
    var onDim: ((Double) -> Void)?
    var onDismiss: (() -> Void)?
    var allowsDismissPan = true
    var onZoom: ((CGFloat) -> Void)?
    var clipsZoomOverflow = true   // editor sets false → zoom grows past the canvas like the video editor

    private var scrollView: ZoomableMediaView!
    private var imageView: UIImageView!
    var mediaCornerRadius: CGFloat = 0

    func setCornerRadius(_ r: CGFloat) {
        guard r != mediaCornerRadius else { return }
        mediaCornerRadius = r
        scrollView?.mediaCornerRadius = r
        scrollView?.updateZoomScaleForLayout()
    }

    // Editor swaps the image (filter/crop applied) — refresh in place, keeping the zoom view.
    func reloadImage() {
        guard let imageView else { return }
        imageView.image = image
        imageView.sizeToFit()
        scrollView?.updateZoomScaleForLayout()
        // A swapped image starts at FIT. The zoom RANGE is recomputed above, but the old absolute
        // zoomScale survived the swap — when a pen bake had changed the image's pixel size, the stale
        // scale no longer meant "fit", so finishing a crop landed visibly zoomed in (user report).
        // setZoomScale fires scrollViewDidZoom → re-centers + reports onZoom, same as a manual zoom-out.
        if let sv = scrollView, sv.zoomScale != sv.minimumZoomScale {
            sv.setZoomScale(sv.minimumZoomScale, animated: false)
        }
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
        scrollView.mediaCornerRadius = mediaCornerRadius
        scrollView.clipsToBounds = clipsZoomOverflow   // editor: overflow the canvas while zooming (video parity)
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
        onZoom?(scrollView.zoomScale / scrollView.minimumZoomScale)   // 1.0 == fit (not zoomed)
    }

    // MARK: drag-down dismiss (only when not zoomed)
    func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        scrollView.zoomScale <= scrollView.minimumZoomScale + 0.01
    }
    // Flick-to-dismiss copied from YBImageBrowser (indulgeIn/YBImageBrowser, YBIBImageCell +
    // YBIBInteractionProfile). Only the interaction is copied: the image follows the finger and
    // shrinks toward center over height*1.2 (floor 0.35), the backdrop fades over height*0.7, and
    // release dismisses on a flick (|v.y| > 800) OR a drag past height*0.22 — else it snaps back
    // in 0.15s. Down-locked here (DirectionalPan) since Kulan only closes downward.
    @objc private func handleDismiss(_ g: UIPanGestureRecognizer) {
        guard scrollView.zoomScale <= scrollView.minimumZoomScale + 0.01 else { return }
        let t = g.translation(in: view)
        let h = max(1, view.bounds.height)
        switch g.state {
        case .changed:
            // PURE 1:1 translation — the image is locked to the finger (the media dismiss moves the
            // media by raw translation). The scale shrinks GENTLY with vertical progress but is folded
            // into the SAME transform (translate THEN scale about the top so the touched point stays put),
            // never a separate UIView.animate — the old animated 0.2s "lift" overrode the presentation
            // layer for the first 0.2s and swallowed the finger movement (the "doesn't follow" bug).
            let progress = min(1.0, max(0, t.y) / h)
            let scale = 1.0 - progress * 0.12                 // barely shrinks; keeps the finger locked
            // Scale about the CENTER but add the drift-correction so the point under the finger stays
            // exactly under it: translate by t, then compensate the center-anchored scale.
            var tf = CGAffineTransform(translationX: t.x, y: t.y)
            tf = tf.scaledBy(x: scale, y: scale)
            scrollView.transform = tf
            // Background fades against the vertical drag distance.
            onDim?(1.0 - Double(progress) * 0.85)
        case .ended, .cancelled:
            // Commit on a flick or once dragged ~18% of the height; otherwise a critically-damped
            // spring back (response ~0.25, damping 1 — no overshoot).
            if g.velocity(in: view).y > 700 || t.y > h * 0.18 {
                onDismiss?()
            } else {
                UIView.animate(withDuration: 0.25, delay: 0, usingSpringWithDamping: 1, initialSpringVelocity: 0) {
                    self.scrollView.transform = .identity
                }
                onDim?(1)
            }
        default: break
        }
    }
}

// Zoomable media view backed by a UIScrollView. min zoom = fit, max = fit*8, double-tap to 2x at the
// tap point, constraint-based centering, safe-area change resets zoom.
final class ZoomableMediaView: UIScrollView {
    private let mediaView: UIView
    private let singleTapBlock: () -> Void
    private var topC: NSLayoutConstraint!
    private var bottomC: NSLayoutConstraint!
    private var leadingC: NSLayoutConstraint!
    private var trailingC: NSLayoutConstraint!
    private var lastSafeAreaSize: CGSize = .zero
    var mediaCornerRadius: CGFloat = 0   // rounds the mediaView; kept visually constant (divided by minScale)

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
        // Round the media itself. The mediaView is at its FULL pixel size (the scroll view scales it by
        // zoomScale), so to show a constant ~cornerRadius pt at the fitted (min) zoom, the layer radius
        // must be divided by minScale. Corners grow when zoomed in — but they're off-screen by then.
        if mediaCornerRadius > 0, minScale > 0 {
            mediaView.layer.cornerRadius = mediaCornerRadius / minScale
            mediaView.layer.masksToBounds = true
        } else {
            mediaView.layer.cornerRadius = 0
        }
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
