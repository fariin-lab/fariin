import AVFoundation
import CoreMedia
import CoreVideo
import ReplayKit
import VideoToolbox

/// The screen sharing extension, v3 (2026-10-08). iOS runs it in its own process once the person
/// taps Start in the system broadcast sheet; it is the only way an app can see the whole screen.
///
/// It no longer uses LiveKit's handler (JPEG over a socket). Following the reference app's design,
/// frames and app audio go through memory-mapped files in the App Group container
/// (`Shared/ScreenShareIPC.swift`), and the app feeds them into the call:
/// - Video: scaled to fit 1920 on the long edge (never up, even sizes), NV12, at most 30 fps, into
///   the free slot of a double buffer, then the seq is bumped.
/// - Audio: the app audio only (never the microphone; the call already has it), converted to
///   48 kHz mono Int16 into a 2 s ring.
/// - Liveness: a keepalive stamp every 0.5 s even when the screen is still. The broadcast finishes
///   by itself when the app stops stamping `appAliveNs` for 4 s ("The call has ended") or asks
///   to stop (`stopRequested` + the Darwin stop notification).
///
/// Group calls (LiveKit) are switched off (CallFeatures.groupCalls = false). When they come back,
/// they need a LiveKit BufferCapturer fed from this same IPC, since this extension no longer talks
/// LiveKit's socket protocol.
///
/// Memory: the extension cap is about 50 MB. Everything here is allocated once: one VT transfer
/// session, one output pixel buffer pool (recreated only when the size changes), reused audio
/// buffers. The two mapped slots touch ~2.6 MB each for a typical phone screen.
final class SampleHandler: RPBroadcastSampleHandler {
    private let video = ScreenShareIPC.VideoChannel()
    private let audioRing = ScreenShareIPC.AudioRing()
    private let control = ScreenShareIPC.Control()

    // Lifecycle state, touched only on `lifeQueue`.
    private let lifeQueue = DispatchQueue(label: "com.kulan.ss3.life")
    private var keepaliveTimer: DispatchSourceTimer?
    private var stopObserver: ScreenShareIPC.DarwinObserver?
    private var running = false
    private var ended = false

    // Video state, touched only on ReplayKit's sample callback.
    private static let minFrameInterval = 1.0 / 31.0
    private var lastFrameTime: Double = -1
    private var transferSession: VTPixelTransferSession?
    private var outputPool: CVPixelBufferPool?
    private var poolWidth = 0
    private var poolHeight = 0
    private var transferFailures = 0

    // Audio state, touched only on ReplayKit's sample callback.
    private let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48_000, channels: 1, interleaved: true)!
    private var converter: AVAudioConverter?
    private var inFormat: AVAudioFormat?
    private var inASBD = AudioStreamBasicDescription()
    private var inSwapBytes = false
    private var inBuffer: AVAudioPCMBuffer?
    private var outBuffer: AVAudioPCMBuffer?

    // MARK: Broadcast lifecycle

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        guard let video, let audioRing, control != nil else {
            NSLog("[ScreenShare] extension: shared files unavailable")
            finish(message: NSLocalizedString("Screen sharing is not available right now.", comment: "Broadcast error"))
            return
        }
        video.prepareWriter()
        audioRing.prepareWriter()
        lifeQueue.async { [weak self] in
            guard let self, !self.ended else { return }
            self.running = true
            self.startKeepalive()
            self.stopObserver = ScreenShareIPC.DarwinObserver(name: ScreenShareIPC.Notify.stop) { [weak self] in
                self?.lifeQueue.async { _ = self?.checkStop() }
            }
            ScreenShareIPC.post(ScreenShareIPC.Notify.started)
            NSLog("[ScreenShare] extension: started")
        }
    }

    override func broadcastPaused() {
        // The keepalive keeps running: a paused share is still a live share, only the frames stop.
        NSLog("[ScreenShare] extension: paused")
    }

    override func broadcastResumed() {
        lastFrameTime = -1
        NSLog("[ScreenShare] extension: resumed")
    }

    override func broadcastFinished() {
        NSLog("[ScreenShare] extension: finished")
        onLifeQueue { self.teardown() }
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        switch sampleBufferType {
        case .video:
            handleVideo(sampleBuffer)
        case .audioApp:
            handleAudio(sampleBuffer)
        case .audioMic:
            break
        @unknown default:
            break
        }
    }

    // MARK: Liveness (lifeQueue)

    private func startKeepalive() {
        let timer = DispatchSource.makeTimerSource(queue: lifeQueue)
        timer.schedule(deadline: .now(), repeating: ScreenShareIPC.keepaliveInterval, leeway: .milliseconds(50))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        keepaliveTimer = timer
    }

    private func tick() {
        guard running, !ended else { return }
        let now = ScreenShareIPC.nowNs()
        video?.touchKeepalive(now)
        if checkStop() { return }
        let alive = control?.appAliveNs ?? 0
        if alive == 0 || now &- alive > ScreenShareIPC.appAliveTimeoutNs {
            NSLog("[ScreenShare] extension: app not alive for 4 s, finishing")
            finish(message: NSLocalizedString("The call has ended", comment: "Broadcast error"))
        }
    }

    /// True if a stop was requested (and the broadcast is being finished).
    @discardableResult
    private func checkStop() -> Bool {
        guard running, !ended, control?.stopRequested == true else { return false }
        NSLog("[ScreenShare] extension: stop requested by the app")
        finish(message: NSLocalizedString("Screen sharing has stopped", comment: "Broadcast error"))
        return true
    }

    /// Ends the broadcast with a readable message (ReplayKit always shows it in an alert; there is
    /// no silent way for an extension to end its own broadcast).
    private func finish(message: String) {
        // May be called on lifeQueue or (before start) on ReplayKit's thread.
        let error = NSError(domain: "com.kulan.screenshare", code: 1,
                            userInfo: [NSLocalizedDescriptionKey: message])
        let alreadyEnded = onLifeQueue { () -> Bool in
            let was = self.ended
            self.teardown()
            return was
        }
        if !alreadyEnded {
            finishBroadcastWithError(error)
        }
    }

    private static let lifeKey = DispatchSpecificKey<Bool>()

    /// Runs `body` on lifeQueue, inline if already there (finishBroadcastWithError may call back
    /// into broadcastFinished on the calling thread, so a plain sync could deadlock).
    @discardableResult
    private func onLifeQueue<T>(_ body: () -> T) -> T {
        if DispatchQueue.getSpecific(key: Self.lifeKey) == true { return body() }
        return lifeQueue.sync(execute: body)
    }

    override init() {
        super.init()
        lifeQueue.setSpecific(key: Self.lifeKey, value: true)
    }

    /// Idempotent. Stops the timer and observer, zeroes the keepalive, tells the app.
    private func teardown() {
        guard !ended else { return }
        ended = true
        keepaliveTimer?.cancel()
        keepaliveTimer = nil
        stopObserver = nil
        if running {
            video?.touchKeepalive(0)
            ScreenShareIPC.post(ScreenShareIPC.Notify.stopped)
        }
        running = false
    }

    // MARK: Video

    private func handleVideo(_ sampleBuffer: CMSampleBuffer) {
        guard let video, let source = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let t = pts.isValid ? CMTimeGetSeconds(pts) : Double(ScreenShareIPC.nowNs()) / 1e9
        // 30 fps pacing. A backwards jump (clock reset) is accepted as a fresh start.
        if lastFrameTime >= 0, t >= lastFrameTime, t - lastFrameTime < Self.minFrameInterval { return }
        lastFrameTime = t

        var orientation: UInt32 = 1 // CGImagePropertyOrientation.up
        if let value = CMGetAttachment(sampleBuffer, key: RPVideoSampleOrientationKey as CFString, attachmentModeOut: nil) as? NSNumber {
            orientation = value.uint32Value
        }

        let srcW = CVPixelBufferGetWidth(source)
        let srcH = CVPixelBufferGetHeight(source)
        let (w, h) = Self.fitSize(width: srcW, height: srcH)
        let format = CVPixelBufferGetPixelFormatType(source)
        let isNV12 = format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            || format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange

        var frame = source
        var fullRange = format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        if !(isNV12 && w == srcW && h == srcH) {
            guard let session = makeTransferSession(), let out = makeOutputBuffer(width: w, height: h) else { return }
            let status = VTPixelTransferSessionTransferImage(session, from: source, to: out)
            guard status == noErr else {
                transferFailures += 1
                if transferFailures == 1 || transferFailures % 300 == 0 {
                    NSLog("[ScreenShare] extension: pixel transfer failed %d (x%ld)", status, transferFailures)
                }
                return
            }
            frame = out
            fullRange = true
        }

        let timestampNs = UInt64(max(0, t) * 1_000_000_000)
        video.writeFrame(frame, orientation: orientation, fullRange: fullRange, timestampNs: timestampNs)
    }

    /// Fit inside 1920 on both edges, keep the aspect, never upscale, even sizes.
    private static func fitSize(width: Int, height: Int) -> (Int, Int) {
        let longEdge = max(width, height)
        let scale = longEdge > ScreenShareIPC.Video.maxEdge ? Double(ScreenShareIPC.Video.maxEdge) / Double(longEdge) : 1.0
        let w = max(2, Int((Double(width) * scale).rounded(.down)) & ~1)
        let h = max(2, Int((Double(height) * scale).rounded(.down)) & ~1)
        return (w, h)
    }

    private func makeTransferSession() -> VTPixelTransferSession? {
        if let transferSession { return transferSession }
        var session: VTPixelTransferSession?
        let status = VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &session)
        guard status == noErr, let session else {
            NSLog("[ScreenShare] extension: VTPixelTransferSessionCreate failed %d", status)
            return nil
        }
        transferSession = session
        return session
    }

    /// One pool, recreated only when the output size changes (rotation of the shared app, etc.).
    /// The previous buffer is released before the next frame, so the pool keeps reusing one.
    private func makeOutputBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        if outputPool == nil || poolWidth != width || poolHeight != height {
            outputPool = nil
            let poolAttributes: [String: Any] = [kCVPixelBufferPoolMinimumBufferCountKey as String: 1]
            let bufferAttributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
            ]
            var pool: CVPixelBufferPool?
            let status = CVPixelBufferPoolCreate(kCFAllocatorDefault, poolAttributes as CFDictionary,
                                                 bufferAttributes as CFDictionary, &pool)
            guard status == kCVReturnSuccess, let pool else {
                NSLog("[ScreenShare] extension: pool create failed %d", status)
                return nil
            }
            outputPool = pool
            poolWidth = width
            poolHeight = height
            NSLog("[ScreenShare] extension: output %ldx%ld", width, height)
        }
        guard let outputPool else { return nil }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, outputPool, &buffer) == kCVReturnSuccess else { return nil }
        return buffer
    }

    // MARK: Audio

    private func handleAudio(_ sampleBuffer: CMSampleBuffer) {
        guard let audioRing,
              let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(description) else { return }
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0 else { return }

        let asbd = asbdPointer.pointee
        if converter == nil || !Self.sameFormat(asbd, inASBD) {
            guard rebuildConverter(for: asbd) else { return }
        }
        guard let converter, let inFormat else { return }

        if inBuffer == nil || Int(inBuffer!.frameCapacity) < frames {
            inBuffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(max(frames, 4096)))
        }
        guard let input = inBuffer else { return }
        input.frameLength = AVAudioFrameCount(frames)
        let copyStatus = CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(frames),
                                                                      into: input.mutableAudioBufferList)
        guard copyStatus == noErr else { return }
        if inSwapBytes { Self.swapInt16(input) }

        let needed = Int((Double(frames) * outFormat.sampleRate / inFormat.sampleRate).rounded(.up)) + 64
        if outBuffer == nil || Int(outBuffer!.frameCapacity) < needed {
            outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: AVAudioFrameCount(max(needed, 8192)))
        }
        guard let output = outBuffer else { return }
        output.frameLength = 0

        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return input
        }
        if status == .error {
            NSLog("[ScreenShare] extension: audio convert failed %@", error?.localizedDescription ?? "?")
            self.converter = nil
            return
        }
        guard output.frameLength > 0, let samples = output.int16ChannelData?[0] else { return }
        audioRing.write(UnsafePointer(samples), count: Int(output.frameLength))
    }

    private func rebuildConverter(for asbd: AudioStreamBasicDescription) -> Bool {
        inASBD = asbd
        converter = nil
        inFormat = nil
        inBuffer = nil
        // App audio often arrives as big-endian Int16. Present it to AVAudioConverter as native
        // endian and swap the bytes ourselves after the copy.
        var native = asbd
        inSwapBytes = false
        if asbd.mFormatID == kAudioFormatLinearPCM,
           asbd.mFormatFlags & kAudioFormatFlagIsBigEndian != 0,
           asbd.mBitsPerChannel == 16 {
            native.mFormatFlags &= ~kAudioFormatFlagIsBigEndian
            inSwapBytes = true
        }
        guard let format = AVAudioFormat(streamDescription: &native),
              let newConverter = AVAudioConverter(from: format, to: outFormat) else {
            NSLog("[ScreenShare] extension: unsupported app audio format %.0f Hz %d ch flags %u",
                  asbd.mSampleRate, Int32(asbd.mChannelsPerFrame), asbd.mFormatFlags)
            return false
        }
        newConverter.downmix = true
        inFormat = format
        converter = newConverter
        NSLog("[ScreenShare] extension: app audio %.0f Hz %d ch", asbd.mSampleRate, Int32(asbd.mChannelsPerFrame))
        return true
    }

    private static func sameFormat(_ a: AudioStreamBasicDescription, _ b: AudioStreamBasicDescription) -> Bool {
        a.mSampleRate == b.mSampleRate && a.mFormatID == b.mFormatID && a.mFormatFlags == b.mFormatFlags
            && a.mBitsPerChannel == b.mBitsPerChannel && a.mChannelsPerFrame == b.mChannelsPerFrame
            && a.mBytesPerFrame == b.mBytesPerFrame
    }

    /// In-place byte swap of every Int16 in the buffer (all its audio buffers).
    private static func swapInt16(_ buffer: AVAudioPCMBuffer) {
        let list = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        for audioBuffer in list {
            guard let data = audioBuffer.mData else { continue }
            let count = Int(audioBuffer.mDataByteSize) / 2
            let p = data.bindMemory(to: UInt16.self, capacity: count)
            for i in 0..<count { p[i] = p[i].byteSwapped }
        }
    }
}
