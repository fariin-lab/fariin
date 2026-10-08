import CoreVideo
import Foundation
import QuartzCore
import WebRTC

/// Feeds screen frames from the broadcast extension into the 1:1 call's EXISTING video source, in
/// place of the camera capturer. Same source, same track, same sender: no renegotiation, and the
/// other side keeps its one remote video view.
///
/// Frames pushed before `setLive(true)` are only remembered, so the camera capturer can finish
/// stopping first and the share's first frame is then sent at once (no black gap, no camera frame
/// interleaved with screen frames). While live, the last frame is re-sent about once a second when
/// nothing new arrives: ReplayKit delivers nothing for a static screen, and without a fresh frame the
/// far side's decoder and our bandwidth estimate both stall.
///
/// All state lives on one serial queue; `push`, `setLive` and `stop` may be called from any thread.
final class ScreenShareCapturer: RTCVideoCapturer {
    /// Ceiling on frames handed to WebRTC. The receive loop already throttles to the tier's rate
    /// before it decodes; this is the backstop, a little looser (x0.75 of the frame time) so decode
    /// jitter there does not halve the rate. Follows the share's quality tier (`setMaxFramerate`).
    private static func pushInterval(fps: Int) -> CFTimeInterval { 0.75 / Double(max(1, fps)) }
    /// Re-send the last frame when the screen has been static this long.
    private static let repeatInterval: CFTimeInterval = 1.0

    private let queue = DispatchQueue(label: "kulan.screenshare.capturer", qos: .userInitiated)
    private var lastBuffer: RTCCVPixelBuffer?
    private var lastRotation: RTCVideoRotation = ._0
    private var lastPushAt: CFTimeInterval = 0
    private var minPushInterval: CFTimeInterval = ScreenShareCapturer.pushInterval(fps: 20)
    private var live = false
    private var stopped = false
    private var repeatTimer: DispatchSourceTimer?

    /// ReplayKit orientation, already turned into degrees by the extension: up 0, left 90,
    /// down 180, right 270, anything else (the mirrored ones) 0.
    static func rotation(degrees: Int) -> RTCVideoRotation {
        switch degrees {
        case 90: return ._90
        case 180: return ._180
        case 270: return ._270
        default: return ._0
        }
    }

    /// A decoded screen frame. Kept as "the last frame" always; sent only while live.
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
        // Wall-clock stamp, not the capture time: a repeated frame must carry a NEW timestamp or the
        // encoder drops it as a duplicate.
        let frame = RTCVideoFrame(buffer: buffer, rotation: rotation, timeStampNs: Int64(now * 1_000_000_000))
        delegate?.capturer(self, didCapture: frame)
    }
}
