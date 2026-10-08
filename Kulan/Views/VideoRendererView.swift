import SwiftUI
import WebRTC

// Renders a WebRTC video track (local preview or the remote feed) via Metal.
// `mirror` flips horizontally for the local front camera (selfie view).
// `fit` shows the whole frame (letterboxed) instead of filling and cropping: a shared SCREEN must
// never lose its edges. Faces keep the fill.
// `upright` keeps the picture right-side up when the phone is turned sideways under the
// portrait-locked call screen (1:1 audit #35, see UprightVideoForwarder). Since r2 E3 (2026-10-08)
// my own preview uses it too, as the reference app turns its local preview.
struct VideoRendererView: UIViewRepresentable {
    let track: RTCVideoTrack?
    var mirror: Bool = false
    var fit: Bool = false
    var upright: Bool = false

    func makeUIView(context: Context) -> RTCMTLVideoView {
        let v = RTCMTLVideoView()
        v.videoContentMode = fit ? .scaleAspectFit : .scaleAspectFill
        v.clipsToBounds = true
        let forwarder = UprightVideoForwarder(view: v)
        forwarder.mirror = mirror   // 1:1 audit r2 E3, 2026-10-08: the forwarder owns the transform
        context.coordinator.forwarder = forwarder
        return v
    }

    func updateUIView(_ uiView: RTCMTLVideoView, context: Context) {
        let forwarder = context.coordinator.forwarder
        // 1:1 audit r2 H6, 2026-10-08: while a new track is being bound, the mirror waits for the
        // rebind (below), so the old picture is never shown with the new picture's mirror.
        if !context.coordinator.rebindPending { forwarder?.mirror = mirror }
        forwarder?.fit = fit
        forwarder?.setUpright(upright)
        forwarder?.refresh()   // r2 E2: the view's shape is part of the fill/fit rule
        // The same mounted view flips between a face and a screen without being rebuilt.
        let mode: UIView.ContentMode = (fit || forwarder?.forcesFit == true) ? .scaleAspectFit : .scaleAspectFill
        if uiView.videoContentMode != mode { uiView.videoContentMode = mode }
        // Re-bind only when the track actually changes (attaching twice double-renders).
        if context.coordinator.track !== track {
            let old = context.coordinator.track
            context.coordinator.track = track           // claim synchronously (no double-dispatch)
            context.coordinator.rebindPending = true
            // Attach/detach ASYNC (LiveKit pattern): doing it synchronously inside a SwiftUI update
            // can race the WebRTC decode thread delivering frames → garbled/dropped first frames.
            // 1:1 audit #41 (owner, 2026-10-08): only while this view is still mounted and still wants
            // this track. A dismantle in the same turn ran first, and the late `add` then pinned a dead
            // Metal view to the track (drawing) until the call ended.
            let coordinator = context.coordinator
            let wantedMirror = mirror
            DispatchQueue.main.async {
                if let renderer = coordinator.forwarder { old?.remove(renderer) }
                guard !coordinator.dismantled, coordinator.track === track,
                      let renderer = coordinator.forwarder else { return }
                coordinator.rebindPending = false
                // r2 H6: the old track's last frame stays hidden until the new one draws.
                if track != nil, old != nil { renderer.beginRebind() }
                renderer.mirror = wantedMirror
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
        var rebindPending = false
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
    private var awaitingFrame = false   // r2 H6, under `lock`
    private var rebindGeneration = 0    // r2 H6, under `lock`
    private var seenFrame = false       // r2 E2, under `lock`
    // Main only.
    var fit = false
    private(set) var forcesFit = false
    /// Selfie mirror, in the picture's own space (1:1 audit r2 E3, 2026-10-08): while the picture is
    /// turned a quarter by `rotationOverride`, its left-right is the screen's up-down.
    var mirror = false { didSet { if mirror != oldValue { applyTransform() } } }
    private var quarterTurned = false
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

    /// Main only. 1:1 audit r2 H6, 2026-10-08: the view is being moved to another track. Its Metal
    /// view still holds the old track's last frame, so it stays hidden until the new track's first
    /// frame is drawn (0.5s fallback, so a track that sends nothing cannot leave it hidden).
    func beginRebind() {
        lock.lock(); awaitingFrame = true; rebindGeneration &+= 1; let generation = rebindGeneration; lock.unlock()
        view?.alpha = 0
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let reveal = self.awaitingFrame && self.rebindGeneration == generation
            if reveal { self.awaitingFrame = false }
            self.lock.unlock()
            if reveal { self.view?.alpha = 1 }
        }
    }

    func renderFrame(_ frame: RTCVideoFrame?) {
        view?.renderFrame(frame)
        guard let frame else { return }
        lock.lock()
        // r2 E2: the rotation is always part of the key (the fill/fit rule needs it on every view).
        let key = uprightFlag ? (orientation.rawValue + 1) * 1000 + frame.rotation.rawValue : frame.rotation.rawValue
        let changed = key != lastKey
        lastKey = key
        lastRotation = frame.rotation
        seenFrame = true
        let reveal = awaitingFrame
        awaitingFrame = false
        lock.unlock()
        if reveal { DispatchQueue.main.async { [weak self] in self?.view?.alpha = 1 } }
        guard changed else { return }
        let rotation = frame.rotation
        DispatchQueue.main.async { [weak self] in self?.apply(rotation: rotation) }
    }

    /// Main only. Re-runs the rule for the last frame (the view's shape may have changed).
    func refresh() {
        lock.lock(); let r = lastRotation; let seen = seenFrame; lock.unlock()
        if seen { apply(rotation: r) }
    }

    /// Main only.
    private func apply(rotation: RTCVideoRotation) {
        guard let view else { return }
        lock.lock(); let on = uprightFlag; let o = orientation; lock.unlock()
        var rot: RTCVideoRotation?   // 1:1 audit check, 2026-10-08: not a keyword name
        let bounds = view.bounds
        let portraitView = bounds.height >= bounds.width
        if on, UIDevice.current.userInterfaceIdiom == .phone, portraitView, o.isLandscape {
            // landscapeLeft turns the frame a further 90°, landscapeRight 270° (the reference app's table).
            let extra = o == .landscapeLeft ? 90 : 270
            rot = RTCVideoRotation(rawValue: (rotation.rawValue + extra) % 360)
        }
        let override = rot.map { NSNumber(value: $0.rawValue) }
        if (view.rotationOverride as? NSNumber)?.intValue != override?.intValue { view.rotationOverride = override }
        quarterTurned = rot != nil
        applyTransform()
        // 1:1 audit r2 E2, 2026-10-08, the reference app's RemoteVideoView rule: fill only when the
        // picture and the screen have the same shape (or the screen is near square), else fit. A
        // sideways phone counts as landscape; an upright one goes by the view's own shape.
        let remoteLandscape = rotation == ._0 || rotation == ._180
        let isLandscape = rot != nil ? true : bounds.width > bounds.height
        let shortSide = min(bounds.width, bounds.height)
        let squarish = shortSide > 0 && max(bounds.width, bounds.height) / shortSide <= 1.2
        forcesFit = !(isLandscape == remoteLandscape || squarish)
        let mode: UIView.ContentMode = (fit || forcesFit) ? .scaleAspectFit : .scaleAspectFill
        if view.videoContentMode != mode { view.videoContentMode = mode }
    }

    /// Main only. r2 E3: mirror across the picture, which is the screen's vertical axis when the
    /// picture is turned a quarter.
    private func applyTransform() {
        guard let view else { return }
        let t: CGAffineTransform = !mirror ? .identity
            : (quarterTurned ? CGAffineTransform(scaleX: 1, y: -1) : CGAffineTransform(scaleX: -1, y: 1))
        if view.transform != t { view.transform = t }
    }
}
