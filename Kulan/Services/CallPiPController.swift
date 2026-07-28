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

    var isSupported: Bool { AVPictureInPictureController.isPictureInPictureSupported() }

    // Idempotent: builds the controller once for a given source view, then just (re)binds the feeds.
    func configure(sourceView: UIView, feeds: CallService.PiPFeeds) {
        guard isSupported else { return }
        if controller == nil || self.sourceView !== sourceView {
            buildController(sourceView: sourceView)
        }
        bigView.mirrored = feeds.mirrorBig
        tileView.mirrored = feeds.mirrorTile
        // A switched-off camera shows that person's photo, not a black rectangle, and the tile keeps
        // its place for the whole call — the same rule the call screen follows.
        bigView.setPlaceholder(name: feeds.bigName, photoUrl: feeds.bigPhotoUrl, visible: feeds.big == nil)
        tileView.setPlaceholder(name: feeds.tileName, photoUrl: feeds.tilePhotoUrl, visible: feeds.tile == nil)
        tileView.isHidden = !feeds.showsTile
        bind(feeds.big, to: bigView, renderer: &bigRenderer, attached: &bigTrack)
        bind(feeds.tile, to: tileView, renderer: &tileRenderer, attached: &tileTrack)
    }

    private func buildController(sourceView: UIView) {
        let vc = PiPCallViewController(bigView: bigView, tileView: tileView)
        vc.preferredContentSize = CGSize(width: 9, height: 16)
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
    var isSystemPiPActive: Bool { controller?.isPictureInPictureActive ?? false }

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
        stopSystemPiP()
        if let t = bigTrack, let r = bigRenderer { t.remove(r) }
        if let t = tileTrack, let r = tileRenderer { t.remove(r) }
        bigRenderer = nil; tileRenderer = nil
        bigTrack = nil; tileTrack = nil
        controller = nil
        callVC = nil
        sourceView = nil
        bigView.displayLayer.flushAndRemoveImage()
        tileView.displayLayer.flushAndRemoveImage()
    }
}

// The PiP window's content: the big feed filling it, the small tile in the top-right corner —
// the same arrangement as the call screen.
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
        tileView.frame = CGRect(x: b.maxX - w - inset, y: b.minY + inset, width: w, height: h)
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
        placeholderView.addSubview(initialLabel)
        placeholderView.addSubview(photoView)
        addSubview(placeholderView)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Camera off: show that person instead of an empty black box. Their cached photo if we have it,
    /// their initial on the same colour the avatars use everywhere else if we do not.
    func setPlaceholder(name: String, photoUrl: String?, visible: Bool) {
        placeholderView.isHidden = !visible
        sampleView.isHidden = visible
        guard visible else { return }
        let image = photoUrl.flatMap { $0.isEmpty ? nil : DiskImageCache.shared.memoryImage($0) }
        photoView.image = image
        photoView.isHidden = image == nil
        initialLabel.text = String(name.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased()
        placeholderView.backgroundColor = UIColor(AvatarPalette.gradient(for: name).first ?? .gray)
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
        photoView.frame = b
        initialLabel.frame = b
        initialLabel.font = .systemFont(ofSize: max(12, b.height * 0.28), weight: .semibold)
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
    func pictureInPictureController(_ controller: AVPictureInPictureController,
                                    failedToStartPictureInPictureWithError error: Error) {
        print("[PiP] failed to start: \(error.localizedDescription)")
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
        completionHandler(true)
    }

    /// Only now is the system window genuinely gone. Ours is the single floating window from here.
    func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        // Nothing to tear down: the renderers stay bound for the life of the call so a re-background can
        // start PiP again instantly. This exists so the state is observable and the lifecycle is closed
        // rather than assumed.
    }
}

// Converts decoded WebRTC frames (the CVPixelBuffer / hardware-decoded path) into CMSampleBuffers
// and feeds them to the PiP display layer, carrying the frame's rotation across to the view.
// (I420-only frames are skipped — most remote streams hardware-decode to a CVPixelBuffer.)
final class PiPFrameRenderer: NSObject, RTCVideoRenderer {
    private weak var view: PiPVideoView?
    init(view: PiPVideoView) { self.view = view; super.init() }

    func setSize(_ size: CGSize) {}

    func renderFrame(_ frame: RTCVideoFrame?) {
        guard let frame,
              let pixelBuffer = (frame.buffer as? RTCCVPixelBuffer)?.pixelBuffer,
              let sample = Self.sampleBuffer(from: pixelBuffer) else { return }
        // Normalise to 0/90/180/270 — the enum is bridged as its degree value.
        let degrees = ((frame.rotation.rawValue % 360) + 360) % 360
        DispatchQueue.main.async { [weak self] in
            guard let view = self?.view else { return }
            view.apply(rotationDegrees: degrees)
            let layer = view.displayLayer
            if layer.status == .failed { layer.flush() }
            layer.enqueue(sample)
        }
    }

    private static func sampleBuffer(from pixelBuffer: CVPixelBuffer) -> CMSampleBuffer? {
        var formatDesc: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescriptionOut: &formatDesc
        ) == noErr, let formatDesc else { return nil }

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
