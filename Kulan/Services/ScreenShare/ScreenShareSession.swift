import Combine
import CoreVideo
import Foundation
import QuartzCore

/// ONE 1:1 screen share's link to the broadcast extension: the socket listener, the extension's
/// started/stopped notifications, the frame-rate gate and the JPEG decode. CallService owns the call
/// side (camera, sender, signalling); this owns the extension side.
///
/// The socket is listened on ONLY while a 1:1 share is wanted. A group call's LiveKit room listens
/// on the same path while it shares, so the two must never overlap (CallService refuses to start
/// this during a group call).
///
/// Threading: `start`, `stop`, `onStarted` and `onEnded` are main-queue. `onFrame` is called on the
/// receive task's thread.
final class ScreenShareSession {
    /// The extension's frames are cut to the quality tier's rate BEFORE decoding (the decode is the
    /// expensive part, and a frame the encoder will drop is not worth decoding). 0.9 of the frame
    /// time, so arrival jitter does not halve 15 fps to 7.5 (15 fps -> 0.06 s, the old fixed gate).
    private static func frameInterval(fps: Int) -> CFTimeInterval { 0.9 / Double(max(1, fps)) }
    /// How often a running share checks that the extension's socket is still there.
    private static let livenessInterval: TimeInterval = 2
    /// "Started" was posted but no frame followed: the extension could not reach us (App Group not
    /// provisioned on one side, or it died at once). Give up instead of sharing nothing forever.
    private static let firstFrameTimeout: TimeInterval = 10

    /// Main. The broadcast is really running: the first frame arrived or the extension said so.
    var onStarted: (() -> Void)?
    /// Main. The first decoded frame went to `onFrame`: the share is really on the far side's screen.
    var onFirstFrame: (() -> Void)?
    /// Main. The broadcast ended on the extension's side. Not called after `stop()`.
    var onEnded: ((EndReason) -> Void)?

    /// Why the extension's side ended, so the call screen can say something true about it.
    enum EndReason {
        /// Socket closed, "stopped" posted, or a socket error: the red pill, Control Centre, the
        /// extension killed for memory.
        case extensionEnded
        /// "Started" was posted and no frame followed in time.
        case noFirstFrame
    }

    private let onFrame: (CVPixelBuffer, Int) -> Void
    private var task: Task<Void, Never>?
    private var notes = Set<AnyCancellable>()
    private let lock = NSLock()
    private var receiver: KSBroadcastReceiver?   // under `lock`
    private var cancelled = false                // under `lock`, mirrors `finished` for the task
    // M-105, the frame-rate gate, shared by the receive loop and the delayed flush.
    private let gateLock = NSLock()
    private var lastAccepted: CFTimeInterval = 0 // under `gateLock`
    private var minFrameInterval: CFTimeInterval = ScreenShareSession.frameInterval(fps: 15)   // under `gateLock`
    private var pendingImage: KSBroadcastReceiver.EncodedImage?   // under `gateLock`
    private let deliverLock = NSLock()           // one decode / onFrame at a time
    // Main only.
    private var finished = false
    private var startedFired = false
    private var gotFrame = false
    private var livenessTimer: Timer?

    init(onFrame: @escaping (CVPixelBuffer, Int) -> Void) {
        self.onFrame = onFrame
    }

    /// Begins listening. False when the App Group container is unavailable (not provisioned), in
    /// which case nothing was started.
    func start() -> Bool {
        guard task == nil, !finished, let path = KSSocketPath.broadcast else { return false }
        // Straight .sink, as LiveKit uses it: the Darwin publisher ignores demand, so no operator
        // sits in between. The hop to main is explicit.
        let center = KSDarwinNotificationCenter.shared
        center.publisher(for: .broadcastStarted)
            .sink { [weak self] _ in DispatchQueue.main.async { self?.extensionSaidStarted() } }
            .store(in: &notes)
        center.publisher(for: .broadcastStopped)
            .sink { [weak self] _ in DispatchQueue.main.async { self?.finish(.extensionEnded) } }
            .store(in: &notes)
        task = Task.detached(priority: .userInitiated) { [weak self] in
            await self?.receiveLoop(path)
        }
        return true
    }

    /// The quality tier's frame-rate ceiling. Any thread.
    func setMaxFramerate(_ fps: Int) {
        let interval = Self.frameInterval(fps: fps)
        gateLock.lock()
        minFrameInterval = interval
        gateLock.unlock()
    }

    /// Main. Ends the share now if the extension's socket is gone without the read loop having said
    /// so yet. Called on a timer while running, and by CallService on return to the foreground.
    ///
    /// ⚠️ SILENCE ALONE NEVER ENDS A SHARE. ReplayKit sends nothing at all for a still screen, so a
    /// share of a page someone is reading can go a minute without a frame and is perfectly healthy;
    /// the capturer re-sends the last frame each second meanwhile, so the far side's picture stays
    /// up. The socket is the truth (design note, 2026-10-07): the extension finishing, crashing or
    /// being killed closes it.
    func checkLiveness() {
        guard !finished, gotFrame else { return }
        lock.lock()
        let receiver = self.receiver
        lock.unlock()
        if receiver?.isClosed ?? true { finish(.extensionEnded) }
    }

    /// Stops listening and closes the socket. Idempotent; `onEnded` is NOT called.
    func stop() {
        guard !finished else { return }
        finished = true
        tearDown()
    }

    // MARK: - Private

    private func receiveLoop(_ path: KSSocketPath) async {
        do {
            let receiver = try await KSBroadcastReceiver(socketPath: path)
            lock.lock()
            let alreadyCancelled = cancelled
            if !alreadyCancelled { self.receiver = receiver }
            lock.unlock()
            if alreadyCancelled { receiver.close(); return }

            let decoder = KSBroadcastImageDecoder()
            while let image = try await receiver.nextImage() {
                if Task.isCancelled { break }
                // Audit M-105, 2026-10-07: a frame inside the 60ms gate used to be thrown away. When it
                // was the LAST change before the screen went still, nothing newer ever came (ReplayKit
                // sends nothing for a static screen) and the far side kept the older picture for good,
                // the capturer's once-a-second repeat re-sending that stale frame. The newest gated
                // frame is now kept and sent when the gate opens, still without decoding the skipped ones.
                let now = CACurrentMediaTime()
                gateLock.lock()
                let wait = minFrameInterval - (now - lastAccepted)
                if wait > 0 {
                    let scheduleFlush = pendingImage == nil
                    pendingImage = image
                    gateLock.unlock()
                    if scheduleFlush { flushPending(after: wait, decoder: decoder) }
                    continue
                }
                lastAccepted = now
                pendingImage = nil
                gateLock.unlock()
                deliver(image, decoder: decoder)
            }
        } catch {
            // Cancelled by stop(), or the socket failed. Either way the share is over.
        }
        DispatchQueue.main.async { [weak self] in self?.finish(.extensionEnded) }
    }

    /// M-105: decode and hand on one frame. Serialised, so the loop and a delayed flush never decode
    /// at once (one decoder) and frames reach `onFrame` in order. Nothing goes out after `stop()`.
    private func deliver(_ image: KSBroadcastReceiver.EncodedImage, decoder: KSBroadcastImageDecoder) {
        deliverLock.lock()
        defer { deliverLock.unlock() }
        lock.lock()
        let stopped = cancelled
        lock.unlock()
        guard !stopped, let buffer = try? decoder.decode(image.jpeg) else { return }
        onFrame(buffer, image.rotation)
        DispatchQueue.main.async { [weak self] in self?.frameArrived() }
    }

    /// M-105: once the gate opens, send the newest frame that arrived while it was shut, unless the
    /// loop has already sent a newer one (it clears `pendingImage` when it does).
    private func flushPending(after wait: CFTimeInterval, decoder: KSBroadcastImageDecoder) {
        Task.detached(priority: .userInitiated) { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, wait) * 1_000_000_000))
            guard let self else { return }
            self.gateLock.lock()
            let image = self.pendingImage
            self.pendingImage = nil
            if image != nil { self.lastAccepted = CACurrentMediaTime() }
            self.gateLock.unlock()
            if let image { self.deliver(image, decoder: decoder) }
        }
    }

    private func frameArrived() {
        guard !finished else { return }
        fireStarted()
        // onStarted can stop us (a share that began into a held call): no timer for a dead session.
        guard !finished, !gotFrame else { return }
        gotFrame = true
        startLivenessTimer()
        onFirstFrame?()
    }

    private func startLivenessTimer() {
        livenessTimer?.invalidate()
        livenessTimer = Timer.scheduledTimer(withTimeInterval: Self.livenessInterval, repeats: true) { [weak self] _ in
            self?.checkLiveness()
        }
    }

    private func extensionSaidStarted() {
        guard !finished else { return }
        fireStarted()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.firstFrameTimeout) { [weak self] in
            guard let self, !self.finished, !self.gotFrame else { return }
            self.finish(.noFirstFrame)
        }
    }

    private func fireStarted() {
        guard !startedFired else { return }
        startedFired = true
        onStarted?()
    }

    /// The extension's side ended.
    private func finish(_ reason: EndReason) {
        guard !finished else { return }
        finished = true
        tearDown()
        onEnded?(reason)
    }

    private func tearDown() {
        livenessTimer?.invalidate(); livenessTimer = nil
        notes.removeAll()
        task?.cancel()
        task = nil
        lock.lock()
        cancelled = true
        let receiver = self.receiver
        self.receiver = nil
        lock.unlock()
        receiver?.close()
    }
}
