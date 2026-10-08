import CoreVideo
import Foundation
import ImageIO

/// ONE 1:1 screen share's link to the broadcast extension (screen share v3, 2026-10-08): the shared
/// memory reader, the extension's started/stopped notifications and both liveness rules. CallService
/// owns the call side (sources, senders, signalling); this owns the extension side.
///
/// The extension writes NV12 frames into a memory-mapped double buffer in the App Group
/// (`ScreenShareIPC.VideoChannel`, seqlock). A timer on our own serial queue polls it at the
/// quality tier's frame rate, copies a new frame into a pool buffer and hands it to `onFrame`. No
/// socket, no JPEG, no decode. The still-screen once-a-second repeat lives in ScreenShareCapturer.
///
/// Liveness, both ways (the reference app's rule): we stamp `appAliveNs` every second while the
/// share is wanted, and the extension finishes itself when that goes 4 s stale. The extension stamps
/// its keepalive every 0.5 s, frames or not, and a keepalive older than 2 s once it has started
/// means it is gone (killed, crashed, ended without its notification).
///
/// Threading: `start`, `stop`, `checkLiveness`, `onStarted`, `onFirstFrame` and `onEnded` are
/// main-queue. `onFrame` is called on the session's reader queue.
final class ScreenShareSession {
    /// Write `appAliveNs` this often (the extension gives up after 4 s).
    private static let appAliveIntervalNs: UInt64 = 1_000_000_000
    /// How often a running share checks the extension's keepalive from the main queue.
    private static let livenessInterval: TimeInterval = 2
    /// "Started" was posted but no frame followed: give up instead of sharing nothing forever.
    private static let firstFrameTimeout: TimeInterval = 10

    /// Main. The broadcast is really running: the first frame arrived or the extension said so.
    var onStarted: (() -> Void)?
    /// Main. The first frame went to `onFrame`: the share is really on the far side's screen.
    var onFirstFrame: (() -> Void)?
    /// Main. The broadcast ended on the extension's side. Not called after `stop()`.
    var onEnded: ((EndReason) -> Void)?

    /// Why the extension's side ended, so the call screen can say something true about it.
    enum EndReason {
        /// The extension posted "stopped": the red pill, Control Centre, its own error.
        case extensionEnded
        /// The extension's keepalive went stale: killed for memory, crashed, or gone silently.
        case extensionGone
        /// "Started" was posted and no frame followed in time.
        case noFirstFrame
    }

    /// Frame in, clockwise rotation in degrees (0, 90, 180, 270). Reader queue.
    private let onFrame: (CVPixelBuffer, Int) -> Void
    private let queue = DispatchQueue(label: "kulan.screenshare.reader", qos: .userInitiated)

    // Reader queue only.
    private var video: ScreenShareIPC.VideoChannel?
    private var control: ScreenShareIPC.Control?
    private var timer: DispatchSourceTimer?
    private var fps = 30
    private var lastSeq: UInt64 = 0
    private var lastAliveWriteNs: UInt64 = 0
    private var pool: CVPixelBufferPool?
    private var poolWidth = 0
    private var poolHeight = 0
    private var poolFullRange = false
    private var readerStopped = false

    // Main only.
    private var observers: [ScreenShareIPC.DarwinObserver] = []
    private var finished = false
    private var started = false
    private var startedFired = false
    private var gotFrame = false
    private var livenessTimer: Timer?

    init(onFrame: @escaping (CVPixelBuffer, Int) -> Void) {
        self.onFrame = onFrame
    }

    /// Maps the shared files and begins polling. False when the App Group container is unavailable
    /// (not provisioned), in which case nothing was started. Main.
    func start() -> Bool {
        guard !finished, observers.isEmpty,
              let video = ScreenShareIPC.VideoChannel(),
              let control = ScreenShareIPC.Control() else { return false }
        // Clears a stale stop from the last share and stamps alive BEFORE the picker shows, so the
        // extension never starts into "the call has ended".
        control.markShareWanted()
        observers = [
            ScreenShareIPC.DarwinObserver(name: ScreenShareIPC.Notify.started) { [weak self] in
                DispatchQueue.main.async { self?.extensionSaidStarted() }
            },
            ScreenShareIPC.DarwinObserver(name: ScreenShareIPC.Notify.stopped) { [weak self] in
                DispatchQueue.main.async { self?.finish(.extensionEnded) }
            },
        ]
        let baseline = video.seq   // the seq continues across broadcasts: old frames stay unread
        queue.async { [weak self] in
            guard let self, !self.readerStopped else { return }
            self.video = video
            self.control = control
            self.lastSeq = baseline
            self.lastAliveWriteNs = ScreenShareIPC.nowNs()
            self.startTimer()
        }
        NSLog("[ScreenShare] session: listening (seq %llu)", baseline)
        return true
    }

    /// The quality tier's frame-rate ceiling: the poll rate. Any thread.
    func setMaxFramerate(_ fps: Int) {
        let value = min(60, max(1, fps))
        queue.async { [weak self] in
            guard let self, self.fps != value else { return }
            self.fps = value
            if self.timer != nil { self.startTimer() }
        }
    }

    /// Main. Ends the share now if the extension's keepalive is stale. Called on a timer while
    /// running, and by CallService on return to the foreground.
    ///
    /// ⚠️ A still screen is healthy: ReplayKit sends no frames for it, but the extension keeps
    /// stamping its keepalive, so only a dead extension trips this.
    func checkLiveness() {
        guard !finished, started else { return }
        queue.async { [weak self] in
            guard let self, let video = self.video else { return }
            let keepalive = video.keepaliveNs
            let now = ScreenShareIPC.nowNs()
            let stale = keepalive == 0 || (now > keepalive && now - keepalive > ScreenShareIPC.keepaliveTimeoutNs)
            guard stale else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.finished else { return }
                NSLog("[ScreenShare] session: extension keepalive stale")
                self.finish(.extensionGone)
            }
        }
    }

    /// Asks the extension to finish (flag + notification) and stops reading. Idempotent; `onEnded`
    /// is NOT called. Main.
    func stop() {
        guard !finished else { return }
        finished = true
        tearDown(requestStop: true)
    }

    // MARK: - Reader queue

    private func startTimer() {
        timer?.cancel()
        let interval = DispatchTimeInterval.nanoseconds(1_000_000_000 / fps)
        let t = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        t.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(2))
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        t.resume()
    }

    private func tick() {
        guard !readerStopped, let video else { return }
        let now = ScreenShareIPC.nowNs()
        if now &- lastAliveWriteNs >= Self.appAliveIntervalNs {
            control?.appAliveNs = now
            lastAliveWriteNs = now
        }
        guard let frame = video.readFrame(newerThan: lastSeq, makeBuffer: { info in self.makeBuffer(info) }) else {
            return
        }
        lastSeq = frame.0.seq
        onFrame(frame.1, Self.degrees(orientation: frame.0.orientation))
        DispatchQueue.main.async { [weak self] in self?.frameArrived() }
    }

    /// A fresh NV12 buffer of the frame's size and range, from a pool rebuilt when either changes.
    private func makeBuffer(_ info: ScreenShareIPC.FrameInfo) -> CVPixelBuffer? {
        if pool == nil || poolWidth != info.width || poolHeight != info.height || poolFullRange != info.fullRange {
            pool = nil
            let format = info.fullRange ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                                        : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: format,
                kCVPixelBufferWidthKey as String: info.width,
                kCVPixelBufferHeightKey as String: info.height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            ]
            let poolAttrs: [String: Any] = [kCVPixelBufferPoolMinimumBufferCountKey as String: 3]
            var created: CVPixelBufferPool?
            guard CVPixelBufferPoolCreate(kCFAllocatorDefault, poolAttrs as CFDictionary,
                                          attrs as CFDictionary, &created) == kCVReturnSuccess,
                  let created else {
                NSLog("[ScreenShare] session: pool create failed %dx%d", info.width, info.height)
                return nil
            }
            pool = created
            poolWidth = info.width
            poolHeight = info.height
            poolFullRange = info.fullRange
        }
        guard let pool else { return nil }
        var out: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &out) == kCVReturnSuccess else {
            return nil
        }
        return out
    }

    /// CGImagePropertyOrientation (from RPVideoSampleOrientationKey) to clockwise degrees. The
    /// mirrored values never come from ReplayKit; they get their unmirrored rotation.
    static func degrees(orientation raw: UInt32) -> Int {
        switch CGImagePropertyOrientation(rawValue: raw) {
        case .down?, .downMirrored?: return 180
        case .left?, .leftMirrored?: return 90
        case .right?, .rightMirrored?: return 270
        default: return 0
        }
    }

    // MARK: - Main

    private func frameArrived() {
        guard !finished else { return }
        fireStarted()
        // onStarted can stop us (a share that began into a held call): no timer for a dead session.
        guard !finished, !gotFrame else { return }
        gotFrame = true
        NSLog("[ScreenShare] session: first frame")
        onFirstFrame?()
    }

    private func extensionSaidStarted() {
        guard !finished else { return }
        NSLog("[ScreenShare] session: extension started")
        fireStarted()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.firstFrameTimeout) { [weak self] in
            guard let self, !self.finished, !self.gotFrame else { return }
            self.finish(.noFirstFrame)
        }
    }

    private func fireStarted() {
        guard !startedFired else { return }
        startedFired = true
        started = true
        livenessTimer?.invalidate()
        livenessTimer = Timer.scheduledTimer(withTimeInterval: Self.livenessInterval, repeats: true) { [weak self] _ in
            self?.checkLiveness()
        }
        onStarted?()
    }

    /// The extension's side ended.
    private func finish(_ reason: EndReason) {
        guard !finished else { return }
        finished = true
        NSLog("[ScreenShare] session: ended (%@)", String(describing: reason))
        // Ask anyway: a stale keepalive may be a stuck extension, and a stop costs nothing.
        tearDown(requestStop: reason != .extensionEnded)
        onEnded?(reason)
    }

    private func tearDown(requestStop: Bool) {
        livenessTimer?.invalidate(); livenessTimer = nil
        observers.removeAll()
        // Strong on purpose: CallService drops the session right after stop(), and the stop request
        // to the extension must still go out.
        queue.async {
            self.readerStopped = true
            self.timer?.cancel(); self.timer = nil
            if requestStop { self.control?.requestStop() }
            self.control = nil
            self.video = nil
            self.pool = nil
        }
    }
}
