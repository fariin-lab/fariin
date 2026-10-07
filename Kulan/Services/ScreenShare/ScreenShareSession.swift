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
    /// The extension's frames are cut to this rate BEFORE decoding (the decode is the expensive part).
    /// Slightly under 1/15 s so arrival jitter does not halve 15 fps to 7.5.
    private static let minFrameInterval: CFTimeInterval = 0.06
    /// "Started" was posted but no frame followed: the extension could not reach us (App Group not
    /// provisioned on one side, or it died at once). Give up instead of sharing nothing forever.
    private static let firstFrameTimeout: TimeInterval = 10

    /// Main. The broadcast is really running: the first frame arrived or the extension said so.
    var onStarted: (() -> Void)?
    /// Main. The broadcast ended on the extension's side: socket closed, "stopped" posted, error.
    /// Not called after `stop()`.
    var onEnded: (() -> Void)?

    private let onFrame: (CVPixelBuffer, Int) -> Void
    private var task: Task<Void, Never>?
    private var notes = Set<AnyCancellable>()
    private let lock = NSLock()
    private var receiver: KSBroadcastReceiver?   // under `lock`
    private var cancelled = false                // under `lock`, mirrors `finished` for the task
    // Main only.
    private var finished = false
    private var startedFired = false
    private var gotFrame = false

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
            .sink { [weak self] _ in DispatchQueue.main.async { self?.finish() } }
            .store(in: &notes)
        task = Task.detached(priority: .userInitiated) { [weak self] in
            await self?.receiveLoop(path)
        }
        return true
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
            var lastAccepted: CFTimeInterval = 0
            while let image = try await receiver.nextImage() {
                if Task.isCancelled { break }
                let now = CACurrentMediaTime()
                guard now - lastAccepted >= Self.minFrameInterval else { continue }
                lastAccepted = now
                guard let buffer = try? decoder.decode(image.jpeg) else { continue }
                onFrame(buffer, image.rotation)
                DispatchQueue.main.async { [weak self] in self?.frameArrived() }
            }
        } catch {
            // Cancelled by stop(), or the socket failed. Either way the share is over.
        }
        DispatchQueue.main.async { [weak self] in self?.finish() }
    }

    private func frameArrived() {
        guard !finished else { return }
        gotFrame = true
        fireStarted()
    }

    private func extensionSaidStarted() {
        guard !finished else { return }
        fireStarted()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.firstFrameTimeout) { [weak self] in
            guard let self, !self.finished, !self.gotFrame else { return }
            self.finish()
        }
    }

    private func fireStarted() {
        guard !startedFired else { return }
        startedFired = true
        onStarted?()
    }

    /// The extension's side ended.
    private func finish() {
        guard !finished else { return }
        finished = true
        tearDown()
        onEnded?()
    }

    private func tearDown() {
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
