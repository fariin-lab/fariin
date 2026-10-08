import SwiftUI
import WebRTC

// Renders a WebRTC video track (local preview or the remote feed) via Metal.
// `mirror` flips horizontally for the local front camera (selfie view).
// `fit` shows the whole frame (letterboxed) instead of filling and cropping: a shared SCREEN must
// never lose its edges. Faces keep the fill.
// `upright` (full-screen 1:1 remote only) keeps the picture right-side up when the phone is turned
// sideways under the portrait-locked call screen (1:1 audit #35, see UprightVideoForwarder).
struct VideoRendererView: UIViewRepresentable {
    let track: RTCVideoTrack?
    var mirror: Bool = false
    var fit: Bool = false
    var upright: Bool = false

    func makeUIView(context: Context) -> RTCMTLVideoView {
        let v = RTCMTLVideoView()
        v.videoContentMode = fit ? .scaleAspectFit : .scaleAspectFill
        v.clipsToBounds = true
        v.transform = mirror ? CGAffineTransform(scaleX: -1, y: 1) : .identity
        context.coordinator.forwarder = UprightVideoForwarder(view: v)
        return v
    }

    func updateUIView(_ uiView: RTCMTLVideoView, context: Context) {
        uiView.transform = mirror ? CGAffineTransform(scaleX: -1, y: 1) : .identity
        let forwarder = context.coordinator.forwarder
        forwarder?.fit = fit
        forwarder?.setUpright(upright)
        // The same mounted view flips between a face and a screen without being rebuilt.
        let mode: UIView.ContentMode = (fit || forwarder?.forcesFit == true) ? .scaleAspectFit : .scaleAspectFill
        if uiView.videoContentMode != mode { uiView.videoContentMode = mode }
        // Re-bind only when the track actually changes (attaching twice double-renders).
        if context.coordinator.track !== track {
            let old = context.coordinator.track
            context.coordinator.track = track           // claim synchronously (no double-dispatch)
            // Attach/detach ASYNC (LiveKit pattern): doing it synchronously inside a SwiftUI update
            // can race the WebRTC decode thread delivering frames → garbled/dropped first frames.
            // 1:1 audit #41 (owner, 2026-10-08): only while this view is still mounted and still wants
            // this track. A dismantle in the same turn ran first, and the late `add` then pinned a dead
            // Metal view to the track (drawing) until the call ended.
            let coordinator = context.coordinator
            DispatchQueue.main.async {
                if let renderer = coordinator.forwarder { old?.remove(renderer) }
                guard !coordinator.dismantled, coordinator.track === track,
                      let renderer = coordinator.forwarder else { return }
                track?.add(renderer)
            }
        }
    }

    static func dismantleUIView(_ uiView: RTCMTLVideoView, coordinator: Coordinator) {
        coordinator.dismantled = true
        if let renderer = coordinator.forwarder { coordinator.track?.remove(renderer) }
        coordinator.track = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator {
        var track: RTCVideoTrack?
        var dismantled = false
        var forwarder: UprightVideoForwarder?
    }
}

/// 1:1 audit #35 (owner, 2026-10-08). Sits between the track and the Metal view and passes every
/// frame straight through. While `upright` is on (the full-screen remote video of a 1:1 call, on an
/// iPhone, in a portrait-shaped view) and the phone is held sideways, it turns the picture with
/// `rotationOverride` so it stays right-side up, and fits it when its shape does not match the
/// phone's (the reference app's RemoteVideoView rule). Face-up / face-down keep the last turn.
final class UprightVideoForwarder: NSObject, RTCVideoRenderer {
    private weak var view: RTCMTLVideoView?
    private let lock = NSLock()
    // Under `lock` (written on main, read on the decode thread).
    private var uprightFlag = false
    private var orientation: UIDeviceOrientation = .portrait
    private var lastKey = Int.min
    private var lastRotation: RTCVideoRotation = ._0
    // Main only.
    var fit = false
    private(set) var forcesFit = false
    private var observer: NSObjectProtocol?

    init(view: RTCMTLVideoView) {
        self.view = view
        super.init()
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        let now = UIDevice.current.orientation
        if now.isLandscape || now.isPortrait { orientation = now }
        observer = NotificationCenter.default.addObserver(
            forName: UIDevice.orientationDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                let o = UIDevice.current.orientation
                guard o.isLandscape || o.isPortrait else { return }   // flat: keep the last turn
                self.lock.lock(); self.orientation = o; let r = self.lastRotation; self.lastKey = Int.min; self.lock.unlock()
                self.apply(rotation: r)
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        // 1:1 audit check, 2026-10-08: the last release can come from the WebRTC thread.
        if Thread.isMainThread {
            UIDevice.current.endGeneratingDeviceOrientationNotifications()
        } else {
            DispatchQueue.main.async { UIDevice.current.endGeneratingDeviceOrientationNotifications() }
        }
    }

    /// Main only.
    func setUpright(_ on: Bool) {
        lock.lock()
        let changed = uprightFlag != on
        uprightFlag = on
        if changed { lastKey = Int.min }
        let r = lastRotation
        lock.unlock()
        if changed { apply(rotation: r) }
    }

    func setSize(_ size: CGSize) {
        view?.setSize(size)   // RTCMTLVideoView hops to main itself
    }

    func renderFrame(_ frame: RTCVideoFrame?) {
        view?.renderFrame(frame)
        guard let frame else { return }
        lock.lock()
        let key = uprightFlag ? orientation.rawValue * 1000 + frame.rotation.rawValue : -1
        let changed = key != lastKey
        lastKey = key
        lastRotation = frame.rotation
        lock.unlock()
        guard changed else { return }
        let rotation = frame.rotation
        DispatchQueue.main.async { [weak self] in self?.apply(rotation: rotation) }
    }

    /// Main only.
    private func apply(rotation: RTCVideoRotation) {
        guard let view else { return }
        lock.lock(); let on = uprightFlag; let o = orientation; lock.unlock()
        var rot: RTCVideoRotation?   // 1:1 audit check, 2026-10-08: not a keyword name
        let portraitView = view.bounds.height >= view.bounds.width
        if on, UIDevice.current.userInterfaceIdiom == .phone, portraitView, o.isLandscape {
            // landscapeLeft turns the frame a further 90°, landscapeRight 270° (the reference app's table).
            let extra = o == .landscapeLeft ? 90 : 270
            rot = RTCVideoRotation(rawValue: (rotation.rawValue + extra) % 360)
        }
        view.rotationOverride = rot.map { NSNumber(value: $0.rawValue) }
        // Sideways phone, upright picture: fill when both are landscape, fit when the sender is portrait.
        let remoteLandscape = rotation == ._0 || rotation == ._180
        forcesFit = rot != nil && !remoteLandscape
        let mode: UIView.ContentMode = (fit || forcesFit) ? .scaleAspectFit : .scaleAspectFill
        if view.videoContentMode != mode { view.videoContentMode = mode }
    }
}
