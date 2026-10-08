import AVKit
import SwiftUI   // AvatarPalette's colours, bridged to UIColor for the camera-off placeholder
import WebRTC

// Native iOS video-call Picture-in-Picture. Detaches the call into a system PiP window when the app
// is backgrounded, so it keeps showing over the Home Screen / other apps.
//
// The floating window carries the WHOLE call layout, like FaceTime: the big feed plus the small
// corner tile, and it follows the same big/small choice the call screen uses. It used to hold a
// single AVSampleBufferDisplayLayer, so only one person was ever in the floating window.
//
// IMPORTANT (honesty): this is structurally complete, but the floating window actually showing
// video can only be confirmed on a PHYSICAL device in a live 2-party call. The WebRTC frame ->
// CMSampleBuffer path and the PiP lifecycle cannot be verified by a compile alone.
final class CallPiPController: NSObject {
    static let shared = CallPiPController()

    private var controller: AVPictureInPictureController?
    private var callVC: PiPCallViewController?
    private let bigView = PiPVideoView()
    private let tileView = PiPVideoView()
    private var bigRenderer: PiPFrameRenderer?
    private var tileRenderer: PiPFrameRenderer?
    private weak var bigTrack: RTCVideoTrack?
    private weak var tileTrack: RTCVideoTrack?
    private weak var sourceView: UIView?
    /// Audit M-054, 2026-10-07: the feeds the window WOULD show, and whether frames are flowing into
    /// it. Both feeds used to be converted to sample buffers and queued on the main thread for the
    /// whole call, in the foreground too, where nobody can see the PiP window. Frames are now attached
    /// only when picture-in-picture can be about to start (the app is resigning active, or PiP says it
    /// is starting) and detached again once the app is back and no PiP window is up.
    private weak var wantedBig: RTCVideoTrack?
    private weak var wantedTile: RTCVideoTrack?
    private var framesLive = false
    /// r2 I7: between willStart and didStart/failed.
    private var pipStarting = false
    /// r2 I2/I9: a host that appeared while a PiP window was up; it becomes the source once it is down.
    private weak var pendingSource: UIView?
    /// r2 I4: re-reads the call's feeds while the window is up (SwiftUI may not update in the background).
    private var refreshTimer: Timer?
    /// r2 I8: a controller asked to stop at teardown, kept alive until its window is really gone.
    private var retiring: AVPictureInPictureController?

    override init() {
        super.init()
        let nc = NotificationCenter.default
        nc.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.controller != nil else { return }
            self.attachFrames()
        }
        nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.detachFramesIfIdle()
        }
        // 1:1 audit r2 I7/J6, 2026-10-08: in the background with no PiP window up or starting (screen
        // locked, PiP off in Settings), nobody can see these frames; stop converting them.
        nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, !self.isSystemPiPActive, !self.pipStarting else { return }
            self.detachFrames()
        }
    }

    var isSupported: Bool { AVPictureInPictureController.isPictureInPictureSupported() }

    // Idempotent: builds the controller once for a given source view, then just (re)binds the feeds.
    func configure(sourceView: UIView, feeds: CallService.PiPFeeds) {
        guard isSupported else { return }
        // A call that is over must not grow a new controller: the screen stays up for the 1-2s end
        // label, any re-render lands here, and a new auto-PiP controller would start picture-in-
        // picture for a dead call if the app went to the background in that second (owner audit
        // 2026-10-06, CallKit/PiP section).
        let state = CallService.shared.state
        guard state != .ended, state != .idle else { return }
        if controller == nil {
            buildController(sourceView: sourceView)
        } else if self.sourceView !== sourceView {
            rebindSource(sourceView)
        }
        applyFeeds(feeds)
    }

    /// The window's content for `feeds` (r3 H4: split from `configure` for the refresh tick).
    private func applyFeeds(_ feeds: CallService.PiPFeeds) {
        bigView.mirrored = feeds.mirrorBig
        tileView.mirrored = feeds.mirrorTile
        // A switched-off camera shows that person's photo, not a black rectangle, and the tile keeps
        // its place for the whole call — the same rule the call screen follows.
        bigView.setPlaceholder(name: feeds.bigName, photoUrl: feeds.bigPhotoUrl, visible: feeds.big == nil)
        tileView.setPlaceholder(name: feeds.tileName, photoUrl: feeds.tilePhotoUrl, visible: feeds.tile == nil)
        tileView.isHidden = !feeds.showsTile
        // M-054: remembered always, bound only while frames are wanted (see `framesLive`).
        wantedBig = feeds.big
        // 1:1 audit r3 H8, 2026-10-08: a hidden tile (ringing) converts no frames.
        let tile = feeds.showsTile ? feeds.tile : nil
        wantedTile = tile
        if framesLive {
            bind(feeds.big, to: bigView, renderer: &bigRenderer, attached: &bigTrack)
            bind(tile, to: tileView, renderer: &tileRenderer, attached: &tileTrack)
        }
    }

    /// M-054: start feeding the window. Idempotent; `bind` skips a track that is already attached.
    private func attachFrames() {
        framesLive = true
        bind(wantedBig, to: bigView, renderer: &bigRenderer, attached: &bigTrack)
        bind(wantedTile, to: tileView, renderer: &tileRenderer, attached: &tileTrack)
    }

    /// M-054: stop feeding it, but never while a PiP window (normal or stashed) is still up, and never
    /// while the app is not in front (PiP may be about to start).
    private func detachFramesIfIdle() {
        guard framesLive, !isSystemPiPActive,
              UIApplication.shared.applicationState == .active else { return }
        detachFrames()
    }

    /// r2 I7/J6: stop feeding the window now, whatever the app state (the caller has checked that no
    /// window is up). Frames come back at the next resign-active or willStart.
    private func detachFrames() {
        guard framesLive else { return }
        framesLive = false
        bind(nil, to: bigView, renderer: &bigRenderer, attached: &bigTrack)
        bind(nil, to: tileView, renderer: &tileRenderer, attached: &tileTrack)
    }

    /// 1:1 audit r2 I2/I9, 2026-10-08: ONE controller for the call. A new host (card, tab, call
    /// screen) only becomes its source view; the controller is never rebuilt, and a PiP window that
    /// is up is never stopped for it (that closed the window the user was watching). While a window
    /// is up the new host waits and takes over when it is gone.
    private func rebindSource(_ view: UIView) {
        guard let controller, let callVC else { buildController(sourceView: view); return }
        if controller.isPictureInPictureActive {
            pendingSource = view
            return
        }
        pendingSource = nil
        controller.contentSource = AVPictureInPictureController.ContentSource(
            activeVideoCallSourceView: view,
            contentViewController: callVC
        )
        sourceView = view
    }

    /// r2 I4: while the window is up, read the feeds from the call itself once a second.
    /// 1:1 audit r3 H4, 2026-10-08: the feeds are applied without needing a live host. The weak
    /// source view can be gone while the window is up (its replacement waits in `pendingSource`), and
    /// the tick used to stop updating the window then.
    private func startRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            let state = CallService.shared.state
            guard state != .ended, state != .idle else { return }
            self.applyFeeds(CallService.shared.pipFeeds)
        }
    }

    private func stopRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    private func buildController(sourceView: UIView) {
        // NEVER replace the controller while its Apple-owned window is up. Returning to the app can
        // hand configure() a RECREATED source view (SwiftUI rebuilds its views freely), and this used
        // to drop the old controller with its PiP still active — orphaning a system window nothing
        // could ever close: stopSystemPiP talks to the NEW controller, whose PiP is not active, and
        // no-ops forever. That is the half of the two-PiP report the foreground stop call cannot fix,
        // and the exact hazard teardown() already documents. Stop the OLD window first, then rebuild.
        stopSystemPiP()
        let vc = PiPCallViewController(bigView: bigView, tileView: tileView)
        // 3:5, not 9:16 (owner's side-by-side, 2026-08-12): the full portrait aspect made iOS hand
        // us a taller, bigger window than the reference's — a squarer ask comes back smaller, and
        // Apple's own corner rounding reads stronger on it. The feeds inside aspect-fill either way.
        vc.preferredContentSize = CGSize(width: 3, height: 5)
        callVC = vc

        let source = AVPictureInPictureController.ContentSource(
            activeVideoCallSourceView: sourceView,
            contentViewController: vc
        )
        let c = AVPictureInPictureController(contentSource: source)
        c.canStartPictureInPictureAutomaticallyFromInline = true   // auto-detaches on background
        c.delegate = self
        controller = c
        self.sourceView = sourceView
    }

    private func bind(_ track: RTCVideoTrack?,
                      to view: PiPVideoView,
                      renderer: inout PiPFrameRenderer?,
                      attached: inout RTCVideoTrack?) {
        if attached === track { return }
        if let old = attached, let r = renderer { old.remove(r) }
        renderer = nil
        attached = track
        view.displayLayer.flushAndRemoveImage()   // don't leave the previous person frozen in the tile
        guard let track else { return }
        let r = PiPFrameRenderer(view: view)
        track.add(r)
        renderer = r
    }

    /// TRUE while the system PiP window exists in ANY state, INCLUDING stashed at the screen edge.
    /// `isPictureInPictureActive` stays true for a stashed window — that is the whole bug below.
    /// 1:1 audit r3 H5, 2026-10-08: also the ended call's window while it is still closing (`retiring`),
    /// so a call started in that gap does not read "no PiP" with Apple's window still on screen.
    var isSystemPiPActive: Bool {
        controller?.isPictureInPictureActive == true || retiring?.isPictureInPictureActive == true
    }

    /// 1:1 audit r3 I1/H2, 2026-10-08: up, or still opening (between willStart and didStart).
    var isPiPStartingOrActive: Bool { isSystemPiPActive || pipStarting }

    /// Take the system PiP down. Call this when the app returns to the foreground with a call still up.
    ///
    /// THE TWO-PiP BUG (user report 2026-07-27): background a video call so the system PiP appears, fling
    /// it to the screen edge so iOS STASHES it, then return to the app — and there are two floating
    /// windows, one of them Apple's.
    ///
    /// Cause: nothing in this app ever stopped the system PiP. The whole design leaned on iOS ending it
    /// by itself when the app came forward, which it does for a NORMAL PiP window. A stashed window is a
    /// different lifecycle: it is parked, not dismissed, and iOS keeps it alive. Our own
    /// `FloatingCallWindow` then appears because the call is minimised, and now both exist.
    ///
    /// Idempotent, and safe to call when no PiP is up.
    func stopSystemPiP() {
        guard let controller, controller.isPictureInPictureActive else { return }
        controller.stopPictureInPicture()
    }

    func teardown() {
        // Stop BEFORE dropping the controller. Releasing it while its window is still up (stashed or not)
        // orphans an Apple-owned window with nothing left to close it — the same two-window state, only
        // now with no way back because our reference is gone.
        stopRefresh()   // r2 I4
        // 1:1 audit r2 I8, 2026-10-08: the stop is asynchronous, so the controller is kept until its
        // window has really gone (didStop), with a 2s fallback, instead of being dropped mid-close.
        // 1:1 audit r3 H5, 2026-10-08: a window still opening is retired too (its didStart stops it).
        if let c = controller, c.isPictureInPictureActive || pipStarting {
            retiring = c
            stopSystemPiP()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self, weak c] in
                guard let self, let c, self.retiring === c else { return }
                self.retiring = nil
            }
        }
        pendingSource = nil
        pipStarting = false
        if let t = bigTrack, let r = bigRenderer { t.remove(r) }
        if let t = tileTrack, let r = tileRenderer { t.remove(r) }
        bigRenderer = nil; tileRenderer = nil
        bigTrack = nil; tileTrack = nil
        wantedBig = nil; wantedTile = nil; framesLive = false   // M-054
        controller = nil
        callVC = nil
        sourceView = nil
        bigView.displayLayer.flushAndRemoveImage()
        tileView.displayLayer.flushAndRemoveImage()
    }
}

// The PiP window's content: the big feed filling it, the small tile in the bottom-right corner —
// the same arrangement as the call screen (owner's side-by-side reference, 2026-08-12: the
// self-tile's home is the BOTTOM corner everywhere, in the window as on the call screen).
final class PiPCallViewController: AVPictureInPictureVideoCallViewController {
    private let bigView: PiPVideoView
    private let tileView: PiPVideoView

    init(bigView: PiPVideoView, tileView: PiPVideoView) {
        self.bigView = bigView
        self.tileView = tileView
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        view.clipsToBounds = true
        tileView.layer.borderColor = UIColor.white.withAlphaComponent(0.35).cgColor
        tileView.layer.borderWidth = 1
        view.addSubview(bigView)
        view.addSubview(tileView)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let b = view.bounds
        bigView.frame = b
        // Same proportions as the call screen's corner tile (~30% of the width, 9:16, inset).
        let w = max(36, b.width * 0.30)
        let h = w * 16.0 / 9.0
        let inset = max(4, b.width * 0.045)
        tileView.frame = CGRect(x: b.maxX - w - inset, y: b.maxY - h - inset, width: w, height: h)
        tileView.layer.cornerRadius = min(10, w * 0.16)
        tileView.layer.cornerCurve = .continuous
    }
}

// A rotation-aware host for one WebRTC feed. WebRTC frames carry the camera's sensor orientation as
// a rotation flag instead of rotating the pixels; RTCMTLVideoView honours it, and this hand-rolled
// sample-buffer path never read it — which is why everyone in the floating window lay on their side.
final class PiPVideoView: UIView {
    private let sampleView = SampleBufferView()
    private let placeholderView = UIView()
    private let photoView = UIImageView()
    private let initialLabel = UILabel()
    private var rotationDegrees = 0
    var mirrored = false { didSet { if mirrored != oldValue { setNeedsLayout() } } }

    var displayLayer: AVSampleBufferDisplayLayer { sampleView.displayLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        clipsToBounds = true
        isUserInteractionEnabled = false
        sampleView.displayLayer.videoGravity = .resizeAspectFill
        sampleView.backgroundColor = .black
        addSubview(sampleView)

        placeholderView.isHidden = true
        photoView.contentMode = .scaleAspectFill
        photoView.clipsToBounds = true
        initialLabel.textAlignment = .center
        initialLabel.textColor = .white
        initialLabel.clipsToBounds = true
        placeholderView.addSubview(initialLabel)
        placeholderView.addSubview(photoView)
        addSubview(placeholderView)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Camera off: a plain dark window with that person's small ROUND avatar in the middle (owner's
    /// 2026-08-12 side-by-side reference) — never their photo blown up to fill the window, which is
    /// what ours did. No photo cached → their initial on the avatar palette colour, same circle.
    func setPlaceholder(name: String, photoUrl: String?, visible: Bool) {
        placeholderView.isHidden = !visible
        sampleView.isHidden = visible
        guard visible else { return }
        // 1:1 audit r2 I5, 2026-10-08: the same loader as the avatar on the card and the call screen
        // (memory, then disk), and a download when neither has it, drawn when it lands. A memory-only
        // peek showed the silhouette after a memory warning or a cold launch from a call.
        let url = photoUrl.flatMap { $0.isEmpty ? nil : $0 }
        // 1:1 audit r3 H7, 2026-10-08: a failed download is tried again, at most every 10 s (the
        // refresh tick calls this every second), instead of leaving the silhouette for the call.
        let retryDue = placeholderFailedAt.map { Date().timeIntervalSince($0) >= 10 } ?? false
        if placeholderReady, url == placeholderUrl, !retryDue { return }   // drawn, or its photo is on the way
        placeholderReady = true
        placeholderUrl = url
        placeholderFailedAt = nil
        let image = url.flatMap { ProfilePhotoLoader.shared.cachedAvatar($0) }
        showPlaceholderPhoto(image)
        if image == nil, let url {
            Task { @MainActor [weak self] in
                let loaded = await ProfilePhotoLoader.shared.avatar(url)
                guard let self, self.placeholderUrl == url else { return }
                guard let loaded else { self.placeholderFailedAt = Date(); return }
                self.showPlaceholderPhoto(loaded)   // drawn even while hidden, ready for the next show
            }
        }
    }

    private var placeholderUrl: String?
    private var placeholderReady = false
    private var placeholderFailedAt: Date?   // r3 H7

    private func showPlaceholderPhoto(_ image: UIImage?) {
        photoView.image = image
        photoView.isHidden = image == nil
        // ⛔ ONE SILHOUETTE, NOT A COLOURED INITIAL — owner, 2026-09-16, "make one type".
        // `AvatarPalette` is the single place that decides how a faceless account looks, so the
        // camera-off placeholder in a call matches the same person's face everywhere else.
        initialLabel.isHidden = image != nil
        initialLabel.text = nil
        initialLabel.backgroundColor = AvatarPalette.placeholderFillUI
        placeholderView.backgroundColor = UIColor(white: 0.10, alpha: 1)
        setNeedsLayout()
    }

    func apply(rotationDegrees deg: Int) {
        guard deg != rotationDegrees else { return }
        rotationDegrees = deg
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let b = bounds
        placeholderView.frame = b
        // The round avatar, centered — ~42% of the window's short side, measured off the reference.
        let d = min(b.width, b.height) * 0.42
        let circle = CGRect(x: b.midX - d / 2, y: b.midY - d / 2, width: d, height: d)
        photoView.frame = circle
        photoView.layer.cornerRadius = d / 2
        initialLabel.frame = circle
        initialLabel.layer.cornerRadius = d / 2
        // ⚠️ THE GLYPH IS AN ATTACHMENT, because this placeholder has always been a `UILabel` acting
        // as a coloured disc and a label cannot hold an image any other way. Sized here rather than
        // in `configure` for the reason the font was: `d` is only known once the window has a size.
        if !initialLabel.isHidden, let g = AvatarPalette.placeholderImage(size: d) {
            let a = NSTextAttachment()
            a.image = g
            a.bounds = CGRect(x: 0, y: -g.size.height * 0.28, width: g.size.width, height: g.size.height)
            initialLabel.attributedText = NSAttributedString(attachment: a)
        }
        // At 90/270 the decoded buffer is landscape but must be shown portrait, so the child is sized
        // with its axes swapped and then rotated into place — the layer keeps filling its own bounds,
        // which still match the buffer's shape, so aspect-fill stays correct.
        let swapped = rotationDegrees == 90 || rotationDegrees == 270
        sampleView.transform = .identity
        sampleView.bounds = CGRect(origin: .zero,
                                   size: swapped ? CGSize(width: b.height, height: b.width) : b.size)
        sampleView.center = CGPoint(x: b.midX, y: b.midY)
        // Mirror in SCREEN space (flip applied after the rotation), so the selfie feed reads correctly
        // whichever way the frames arrive.
        var t = mirrored ? CGAffineTransform(scaleX: -1, y: 1) : .identity
        t = t.rotated(by: CGFloat(rotationDegrees) * .pi / 180)
        sampleView.transform = t
    }
}

// UIView whose backing layer is the sample-buffer display layer (resizes via UIView autoresizing).
final class SampleBufferView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }
}

extension CallPiPController: AVPictureInPictureControllerDelegate {
    /// M-054: the window is about to open; make sure its frames are flowing (normally already done at
    /// resign-active, this covers a start that comes some other way).
    func pictureInPictureControllerWillStartPictureInPicture(_ controller: AVPictureInPictureController) {
        guard controller === self.controller else { return }   // 1:1 audit r3 H5: an ended call's
        pipStarting = true   // r2 I7
        attachFrames()
    }

    func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        // 1:1 audit r3 H5, 2026-10-08: a window that finished opening after its call ended goes.
        guard controller === self.controller else { controller.stopPictureInPicture(); return }
        pipStarting = false
        startRefresh()   // r2 I4
        CallService.shared.pipWindowChanged()   // r3 I1/H2: the freeze watch runs while it is up
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController,
                                    failedToStartPictureInPictureWithError error: Error) {
        print("[PiP] failed to start: \(error.localizedDescription)")
        guard controller === self.controller else {   // r3 H5
            if controller === retiring { retiring = nil }
            return
        }
        // 1:1 audit r2 I7, 2026-10-08: no window will show these frames; stop converting them.
        pipStarting = false
        detachFrames()
        CallService.shared.pipWindowChanged()   // r3 I1
    }

    /// Apple's designated hook for "the user is coming back to your app". It was never implemented, which
    /// is half of why a stashed PiP survived the return: iOS asks whether to restore our UI, gets no
    /// answer, and leaves its window where it is.
    ///
    /// The contract is strict — the completion handler MUST be called, exactly once, and iOS only takes
    /// its window down after it fires. `true` means we restored successfully.
    func pictureInPictureController(_ controller: AVPictureInPictureController,
                                    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler
                                    completionHandler: @escaping (Bool) -> Void) {
        // The call UI is a root-level container that never went anywhere, so there is nothing to rebuild:
        // returning to the app IS the restore. Answer immediately rather than deferring to an animation —
        // a late or missed completion is what leaves Apple's window on screen.
        // 1:1 audit r2 I1, 2026-10-08: the expand button means "back to the call", so a minimized call
        // comes back full screen (the reference app's in-app window restores the call on tap).
        // 1:1 audit r3 H1, 2026-10-08: decided here alone. Guessing who asked for the stop (a flag
        // set at willEnterForeground) lost the expand tap whenever the foreground came first. Any
        // return from a PiP window now lands on the full call, as FaceTime's does.
        let call = CallService.shared
        if controller === self.controller, call.minimized,
           call.state == .active || call.state == .reconnecting || call.state == .outgoing {
            call.minimized = false
        }
        completionHandler(true)
    }

    /// Only now is the system window genuinely gone. Ours is the single floating window from here.
    func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        if controller === retiring { retiring = nil; return }   // r2 I8: the ended call's window is gone
        // 1:1 audit r3 H5, 2026-10-08: a late stop from an older window (its 2 s fallback already
        // passed) must not detach the current call's frames.
        guard controller === self.controller else { return }
        // r3 H3: a start cancelled before didStart (the user came straight back) ends here too, and a
        // stale `pipStarting` kept frames converting in the background with no window.
        pipStarting = false
        defer { CallService.shared.pipWindowChanged() }   // r3 I1: closed in the background, watch stops
        stopRefresh()   // r2 I4
        // Audit M-054, 2026-10-07: this used to keep the renderers bound for the life of the call so a
        // re-background could start PiP instantly. They are re-attached at resign-active now, which
        // comes before any automatic start, so they are let go here.
        // 1:1 audit r2 J6/I7, 2026-10-08: in the background too (the window closed with its X from
        // another app), not only once the app is back in front.
        detachFrames()
        // r2 I2/I9: a host that appeared while the window was up becomes the source now.
        if let next = pendingSource, next !== sourceView { rebindSource(next) }
        pendingSource = nil
    }
}

// Converts decoded WebRTC frames into CMSampleBuffers and feeds them to the PiP display layer,
// carrying the frame's rotation across to the view.
// 1:1 audit #14 (owner, 2026-10-08): frames that are not a plain CVPixelBuffer (a software decode
// gives I420) or that carry a crop are converted through I420 into an NV12 buffer instead of being
// dropped, which left the PiP on the placeholder or a stale picture.
// 1:1 audit #22 (owner, 2026-10-08): the format description is reused while the size and format stay
// the same, and a frame is dropped while the previous one still waits for main, so a busy main
// thread cannot queue up decoded buffers (and pin the decoder's pool).
final class PiPFrameRenderer: NSObject, RTCVideoRenderer {
    private weak var view: PiPVideoView?
    init(view: PiPVideoView) { self.view = view; super.init() }

    private let lock = NSLock()
    // Under `lock`.
    private var pending = false
    private var formatDesc: CMVideoFormatDescription?
    private var pool: CVPixelBufferPool?
    private var poolSize = (w: 0, h: 0)
    private var poolFormat: OSType = 0   // r3 H8

    func setSize(_ size: CGSize) {}

    func renderFrame(_ frame: RTCVideoFrame?) {
        guard let frame else { return }
        lock.lock()
        if pending { lock.unlock(); return }   // main has not taken the last one yet: drop this
        pending = true
        lock.unlock()
        let pixelBuffer: CVPixelBuffer?
        if let cv = frame.buffer as? RTCCVPixelBuffer, !cv.requiresCropping() {
            pixelBuffer = cv.pixelBuffer
        } else if let cv = frame.buffer as? RTCCVPixelBuffer, let out = cropped(cv) {
            // 1:1 audit r3 H8, 2026-10-08: a cropped camera frame is cut in one SIMD pass into a
            // buffer of its own format, not through I420 and a byte-by-byte interleave.
            pixelBuffer = out
        } else {
            pixelBuffer = nv12(from: frame.buffer)
        }
        guard let pixelBuffer, let sample = sampleBuffer(from: pixelBuffer) else {
            lock.lock(); pending = false; lock.unlock()
            return
        }
        // Normalise to 0/90/180/270 — the enum is bridged as its degree value.
        let degrees = ((frame.rotation.rawValue % 360) + 360) % 360
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock(); self.pending = false; self.lock.unlock()
            guard let view = self.view else { return }
            view.apply(rotationDegrees: degrees)
            let layer = view.displayLayer
            if layer.status == .failed { layer.flush() }
            layer.enqueue(sample)
        }
    }

    /// Any frame buffer (cropped CVPixelBuffer, I420) as a video-range NV12 CVPixelBuffer.
    /// Runs on the frame's thread; `toI420` applies the crop.
    private func nv12(from buffer: RTCVideoFrameBuffer) -> CVPixelBuffer? {
        let i420 = buffer.toI420()
        let w = Int(i420.width), h = Int(i420.height)
        guard w > 0, h > 0,
              let out = pooledBuffer(width: w, height: h, format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        else { return nil }
        CVPixelBufferLockBaseAddress(out, [])
        defer { CVPixelBufferUnlockBaseAddress(out, []) }
        guard let yDst = CVPixelBufferGetBaseAddressOfPlane(out, 0)?.assumingMemoryBound(to: UInt8.self),
              let uvDst = CVPixelBufferGetBaseAddressOfPlane(out, 1)?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let yDstStride = CVPixelBufferGetBytesPerRowOfPlane(out, 0)
        let uvDstStride = CVPixelBufferGetBytesPerRowOfPlane(out, 1)
        let ySrc = i420.dataY, uSrc = i420.dataU, vSrc = i420.dataV
        let yStride = Int(i420.strideY), uStride = Int(i420.strideU), vStride = Int(i420.strideV)
        for row in 0..<h {
            (yDst + row * yDstStride).update(from: ySrc + row * yStride, count: w)
        }
        let cw = Int(i420.chromaWidth), ch = Int(i420.chromaHeight)
        for row in 0..<ch {
            let dst = uvDst + row * uvDstStride
            let u = uSrc + row * uStride
            let v = vSrc + row * vStride
            for col in 0..<cw {
                dst[2 * col] = u[col]
                dst[2 * col + 1] = v[col]
            }
        }
        return out
    }

    /// A buffer from the pool for this size and format (rebuilt when either changes). Frame thread.
    private func pooledBuffer(width w: Int, height h: Int, format: OSType) -> CVPixelBuffer? {
        lock.lock()
        if pool == nil || poolSize.w != w || poolSize.h != h || poolFormat != format {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: format,
                kCVPixelBufferWidthKey as String: w,
                kCVPixelBufferHeightKey as String: h,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            ]
            var newPool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs as CFDictionary, &newPool)
            pool = newPool
            poolSize = (w, h)
            poolFormat = format
        }
        let currentPool = pool
        lock.unlock()
        guard let currentPool else { return nil }
        var out: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, currentPool, &out) == kCVReturnSuccess
        else { return nil }
        return out
    }

    /// r3 H8: the crop of a camera frame, in the source's own format (WebRTC's libyuv crop). Nil for
    /// a format it does not take, which then goes the I420 way. Frame thread.
    private func cropped(_ cv: RTCCVPixelBuffer) -> CVPixelBuffer? {
        let format = CVPixelBufferGetPixelFormatType(cv.pixelBuffer)
        guard format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                || format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                || format == kCVPixelFormatType_32BGRA else { return nil }
        let w = Int(cv.cropWidth), h = Int(cv.cropHeight)
        guard w > 0, h > 0, let out = pooledBuffer(width: w, height: h, format: format) else { return nil }
        let tmpSize = Int(cv.bufferSizeForCroppingAndScaling(toWidth: Int32(w), height: Int32(h)))
        let tmp: UnsafeMutablePointer<UInt8>? = tmpSize > 0 ? .allocate(capacity: tmpSize) : nil
        defer { tmp?.deallocate() }
        return cv.cropAndScale(to: out, withTempBuffer: tmp) ? out : nil
    }

    private func sampleBuffer(from pixelBuffer: CVPixelBuffer) -> CMSampleBuffer? {
        lock.lock()
        var desc = formatDesc
        lock.unlock()
        if desc == nil || !CMVideoFormatDescriptionMatchesImageBuffer(desc!, imageBuffer: pixelBuffer) {
            var fresh: CMVideoFormatDescription?
            guard CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescriptionOut: &fresh
            ) == noErr, let fresh else { return nil }
            desc = fresh
            lock.lock(); formatDesc = fresh; lock.unlock()
        }
        guard let formatDesc = desc else { return nil }

        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
            formatDescription: formatDesc, sampleTiming: &timing, sampleBufferOut: &sample
        ) == noErr, let sample else { return nil }

        // Tell the layer to show each frame immediately (live video, not a timed playlist).
        if let arr = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(arr) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(arr, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }
}
