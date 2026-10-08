import CoreVideo
import Foundation
import QuartzCore
import WebRTC

/// Feeds screen frames from the broadcast extension into a GIVEN video source. CallService picks the
/// source: the camera's own source in fallback mode (screen replaces camera, same sender), or a
/// dedicated screen source on the second video transceiver in dual mode (camera keeps running).
///
/// Frames pushed before `setLive(true)` are only remembered, so the camera capturer can finish
/// stopping first and the share's first frame is then sent at once (no black gap, no camera frame
/// interleaved with screen frames). While live, the last frame is re-sent about once a second when
/// nothing new arrives: ReplayKit delivers nothing for a static screen, and without a fresh frame the
/// far side's decoder and our bandwidth estimate both stall.
///
/// All state lives on one serial queue; `push`, `setLive` and `stop` may be called from any thread.
final class ScreenShareCapturer: RTCVideoCapturer {
    /// Ceiling on frames handed to WebRTC. The session's timer already reads at the tier's rate; this
    /// is the backstop, a little looser (x0.75 of the frame time) so timer jitter does not halve the
    /// rate. Follows the share's quality tier (`setMaxFramerate`).
    private static func pushInterval(fps: Int) -> CFTimeInterval { 0.75 / Double(max(1, fps)) }
    /// Re-send the last frame when the screen has been static this long.
    private static let repeatInterval: CFTimeInterval = 1.0

    private let queue = DispatchQueue(label: "kulan.screenshare.capturer", qos: .userInitiated)
    private var lastBuffer: RTCCVPixelBuffer?
    private var lastRotation: RTCVideoRotation = ._0
    private var lastPushAt: CFTimeInterval = 0
    private var lastStampNs: Int64 = 0
    private var minPushInterval: CFTimeInterval = ScreenShareCapturer.pushInterval(fps: 30)
    private var live = false
    private var stopped = false
    private var repeatTimer: DispatchSourceTimer?

    /// Pushes into `source` (an RTCVideoSource is the capturer's delegate). Same as `init(delegate:)`.
    convenience init(source: RTCVideoSource) {
        self.init(delegate: source)
    }

    /// Clockwise rotation in degrees (0, 90, 180, 270) to WebRTC's rotation. Anything else is 0.
    static func rotation(degrees: Int) -> RTCVideoRotation {
        switch degrees {
        case 90: return ._90
        case 180: return ._180
        case 270: return ._270
        default: return ._0
        }
    }

    /// A screen frame. Kept as "the last frame" always; sent only while live. The buffer must not be
    /// written to afterwards (the session hands over a fresh pool buffer each time).
    func push(_ pixelBuffer: CVPixelBuffer, rotationDegrees: Int) {
        let buffer = RTCCVPixelBuffer(pixelBuffer: pixelBuffer)
        let rotation = Self.rotation(degrees: rotationDegrees)
        queue.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.lastBuffer = buffer
            self.lastRotation = rotation
            guard self.live else { return }
            let now = CACurrentMediaTime()
            guard now - self.lastPushAt >= self.minPushInterval else { return }
            self.emit(buffer, rotation: rotation, at: now)
        }
    }

    /// The quality tier's frame-rate ceiling (CallService's ladder). The once-a-second repeat for a
    /// still screen is not affected.
    func setMaxFramerate(_ fps: Int) {
        let interval = Self.pushInterval(fps: fps)
        queue.async { [weak self] in self?.minPushInterval = interval }
    }

    /// Start (or pause) handing frames to the video source. Going live sends the newest frame at
    /// once and starts the static-screen repeat.
    func setLive(_ on: Bool) {
        queue.async { [weak self] in
            guard let self, !self.stopped, self.live != on else { return }
            self.live = on
            if on {
                if let buffer = self.lastBuffer {
                    self.emit(buffer, rotation: self.lastRotation, at: CACurrentMediaTime())
                }
                self.startRepeatTimer()
            } else {
                self.repeatTimer?.cancel()
                self.repeatTimer = nil
            }
        }
    }

    /// Final: no frame is sent after this, and the remembered frame is released.
    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopped = true
            self.live = false
            self.repeatTimer?.cancel()
            self.repeatTimer = nil
            self.lastBuffer = nil
        }
    }

    // MARK: - Private (queue only)

    private func startRepeatTimer() {
        repeatTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.repeatInterval, repeating: Self.repeatInterval / 2)
        timer.setEventHandler { [weak self] in
            guard let self, self.live, !self.stopped, let buffer = self.lastBuffer else { return }
            let now = CACurrentMediaTime()
            guard now - self.lastPushAt >= Self.repeatInterval else { return }
            self.emit(buffer, rotation: self.lastRotation, at: now)
        }
        repeatTimer = timer
        timer.resume()
    }

    private func emit(_ buffer: RTCCVPixelBuffer, rotation: RTCVideoRotation, at now: CFTimeInterval) {
        lastPushAt = now
        // Host-clock stamp at send time, always increasing: a repeated frame must carry a NEW
        // timestamp or the encoder drops it as a duplicate. The session delivers each frame within a
        // timer tick of its capture, so this is within ~33 ms of the extension's capture time.
        let stamp = max(Int64(now * 1_000_000_000), lastStampNs + 1)
        lastStampNs = stamp
        let frame = RTCVideoFrame(buffer: buffer, rotation: rotation, timeStampNs: stamp)
        delegate?.capturer(self, didCapture: frame)
    }
}
