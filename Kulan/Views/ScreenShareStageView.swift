import SwiftUI
import UIKit
import WebRTC

// Viewer for the OTHER person's shared screen in a 1:1 call. The picture is always shown whole
// (aspect-fit), can be pinch/double-tap zoomed, and the letterbox areas show a soft blurred copy
// of the screen (like the reference app) instead of hard black. Never blacks out on its own.
struct ScreenShareStageView: UIViewRepresentable {
    let track: RTCVideoTrack?
    var onSingleTap: () -> Void = {}

    func makeUIView(context: Context) -> ScreenShareStageUIView {
        let v = ScreenShareStageUIView()
        v.onSingleTap = onSingleTap
        context.coordinator.stage = v
        return v
    }

    func updateUIView(_ uiView: ScreenShareStageUIView, context: Context) {
        uiView.onSingleTap = onSingleTap
        // Re-bind only when the track actually changes (attaching twice double-renders).
        if context.coordinator.track !== track {
            let old = context.coordinator.track
            context.coordinator.track = track           // claim synchronously (no double-dispatch)
            // Attach/detach ASYNC, same rule as VideoRendererView: a synchronous attach inside a
            // SwiftUI update can race the decode thread and garble the first frames.
            DispatchQueue.main.async {
                uiView.bind(old: old, new: track)
            }
        }
    }

    static func dismantleUIView(_ uiView: ScreenShareStageUIView, coordinator: Coordinator) {
        uiView.bind(old: coordinator.track, new: nil)
        coordinator.track = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator {
        var track: RTCVideoTrack?
        weak var stage: ScreenShareStageUIView?
    }
}

// Hierarchy: backdrop video (fill) > blur > dim > scrollView > container (fitted rect) > video (fit).
final class ScreenShareStageUIView: UIView, UIScrollViewDelegate, RTCVideoViewDelegate {
    var onSingleTap: () -> Void = {}

    private let backdropVideo = RTCMTLVideoView()
    private let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
    private let dim = UIView()
    private let scrollView = UIScrollView()
    private let container = UIView()
    private let video = RTCMTLVideoView()

    private var videoSize: CGSize = .zero
    private var lastFitBounds: CGSize = .zero
    private var lastFitVideo: CGSize = .zero
    private var boundTrack: RTCVideoTrack?
    private var backdropAttached = false

    private var backdropWanted: Bool { !ProcessInfo.processInfo.isLowPowerModeEnabled }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        clipsToBounds = true

        backdropVideo.videoContentMode = .scaleAspectFill
        backdropVideo.clipsToBounds = true
        backdropVideo.isUserInteractionEnabled = false
        addSubview(backdropVideo)
        addSubview(blur)
        dim.backgroundColor = UIColor.black.withAlphaComponent(0.35)
        addSubview(dim)
        blur.isUserInteractionEnabled = false
        dim.isUserInteractionEnabled = false

        scrollView.delegate = self
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 4
        scrollView.bouncesZoom = true
        scrollView.decelerationRate = .normal
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.backgroundColor = .clear
        addSubview(scrollView)

        container.backgroundColor = .clear
        scrollView.addSubview(container)

        video.videoContentMode = .scaleAspectFit
        video.clipsToBounds = true
        video.delegate = self
        container.addSubview(video)

        container.isAccessibilityElement = true
        container.accessibilityLabel = "Shared screen"
        container.accessibilityHint = "Double-tap to zoom"

        let double = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        double.numberOfTapsRequired = 2
        let single = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap))
        single.require(toFail: double)
        scrollView.addGestureRecognizer(double)
        scrollView.addGestureRecognizer(single)

        applyBackdropVisibility()
        NotificationCenter.default.addObserver(
            self, selector: #selector(powerStateChanged),
            name: .NSProcessInfoPowerStateDidChange, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    deinit { NotificationCenter.default.removeObserver(self) }

    // MARK: - Track binding

    func bind(old: RTCVideoTrack?, new: RTCVideoTrack?) {
        if let old = old {
            old.remove(video)
            old.remove(backdropVideo)
        }
        boundTrack = new
        backdropAttached = false
        if let new = new {
            new.add(video)
            if backdropWanted {
                new.add(backdropVideo)
                backdropAttached = true
            }
        } else {
            videoSize = .zero
            setNeedsLayout()
        }
    }

    @objc private func powerStateChanged() {
        DispatchQueue.main.async { [weak self] in self?.applyBackdropVisibility() }
    }

    private func applyBackdropVisibility() {
        let on = backdropWanted
        backdropVideo.isHidden = !on
        blur.isHidden = !on
        dim.isHidden = !on
        guard let track = boundTrack else { return }
        if on && !backdropAttached {
            track.add(backdropVideo)
            backdropAttached = true
        } else if !on && backdropAttached {
            track.remove(backdropVideo)
            backdropAttached = false
        }
    }

    // MARK: - RTCVideoViewDelegate

    func videoView(_ videoView: RTCVideoRenderer, didChangeVideoSize size: CGSize) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.videoSize = size
            self.setNeedsLayout()
        }
    }

    // MARK: - Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        backdropVideo.frame = bounds
        blur.frame = bounds
        dim.frame = bounds
        scrollView.frame = bounds
        refitIfNeeded()
        centerContent()
    }

    private func fittedSize() -> CGSize {
        guard bounds.width > 0, bounds.height > 0 else { return .zero }
        // Before the first frame the size is unknown: fill the bounds (the view aspect-fits inside),
        // so the renderer has a real surface and the first frame can arrive and report its size.
        guard videoSize.width > 0, videoSize.height > 0 else { return bounds.size }
        let scale = min(bounds.width / videoSize.width, bounds.height / videoSize.height)
        return CGSize(width: (videoSize.width * scale).rounded(), height: (videoSize.height * scale).rounded())
    }

    private func refitIfNeeded() {
        guard bounds.size != lastFitBounds || videoSize != lastFitVideo else { return }
        let fitted = fittedSize()
        let wasZoomed = scrollView.zoomScale > 1.001
        lastFitBounds = bounds.size
        lastFitVideo = videoSize

        let apply = {
            self.scrollView.zoomScale = 1
            self.container.frame = CGRect(origin: .zero, size: fitted)
            self.video.frame = self.container.bounds
            self.scrollView.contentSize = fitted
            self.centerContent()
            // At rest the picture sits in the middle: the offset that shows the centring inset.
            let inset = self.scrollView.contentInset
            self.scrollView.contentOffset = CGPoint(x: -inset.left, y: -inset.top)
        }
        // The aspect or the bounds changed (sharer rotated / switched app): drop the zoom, re-fit.
        if wasZoomed {
            UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseInOut], animations: apply)
        } else {
            apply()
        }
    }

    private func centerContent() {
        let content = container.frame.size
        // While zoomed, container.frame already includes the zoom scale.
        let x = max(0, (scrollView.bounds.width - content.width) / 2)
        let y = max(0, (scrollView.bounds.height - content.height) / 2)
        let inset = UIEdgeInsets(top: y, left: x, bottom: y, right: x)
        if scrollView.contentInset != inset { scrollView.contentInset = inset }
    }

    // MARK: - UIScrollViewDelegate

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { container }

    func scrollViewDidZoom(_ scrollView: UIScrollView) { centerContent() }

    // MARK: - Gestures

    @objc private func handleSingleTap() { onSingleTap() }

    @objc private func handleDoubleTap(_ g: UITapGestureRecognizer) {
        guard container.bounds.width > 0 else { return }
        if scrollView.zoomScale > 1.05 {
            scrollView.setZoomScale(1, animated: true)
            return
        }
        let target: CGFloat = 2.5
        let p = g.location(in: container)
        let size = CGSize(width: scrollView.bounds.width / target, height: scrollView.bounds.height / target)
        let rect = CGRect(x: p.x - size.width / 2, y: p.y - size.height / 2, width: size.width, height: size.height)
        scrollView.zoom(to: rect, animated: true)
    }
}
