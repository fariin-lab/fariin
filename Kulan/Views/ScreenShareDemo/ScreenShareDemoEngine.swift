import CoreVideo
import Foundation
import UIKit
import WebRTC

// SCREEN SHARE DEMO (owner, 2026-10-08). Opened from Settings > "Screen Share Demo". The owner has
// nobody to test a 1:1 share with, so this runs the REAL share pipeline inside one phone: the system
// broadcast picker, the broadcast extension, ScreenShareSession reading its frames, ScreenShareCapturer
// feeding a screencast source, a real WebRTC encode, and a real decode on a second peer connection in
// the same process (loopback, host candidates only). What arrives on that second connection is shown
// with the call's own ScreenShareStageView.
//
// ⛔ It never touches the real call system: its own factory (not CallService's), its own two peer
// connections, and it stops itself the moment a real call starts. Nothing is written or sent anywhere.

@MainActor
final class ScreenShareDemoEngine: ObservableObject {
    enum Phase: Equatable { case idle, picking, live }

    /// Auto runs the call's own ladder (ScreenShareQuality) on the loopback's stats; the others pin
    /// one of its tiers, so a bad network can be seen on a good one.
    enum QualityChoice: Int, CaseIterable, Identifiable {
        case auto = -1, good = 0, medium = 1, low = 2, veryLow = 3
        var id: Int { rawValue }
        var title: String {
            switch self {
            case .auto: return "Auto"
            case .good: return "Good"
            case .medium: return "Medium"
            case .low: return "Low"
            case .veryLow: return "Very low"
            }
        }
    }

    @Published private(set) var phase: Phase = .idle
    /// B's received screen: the "remote" picture.
    @Published private(set) var receivedTrack: RTCVideoTrack?
    @Published private(set) var statsLine = ""
    /// One short line after a share ends or cannot start.
    @Published private(set) var note: String?
    @Published private(set) var quality: QualityChoice = .auto
    /// The tier in force (what Auto picked, or the pinned one), for the quality button's label.
    @Published private(set) var tierIndex = 0

    // The loopback. All released in `tearDown`.
    private var factory: RTCPeerConnectionFactory?
    private var source: RTCVideoSource?
    private var track: RTCVideoTrack?
    private var capturer: ScreenShareCapturer?
    private var session: ScreenShareSession?
    private var pcA: RTCPeerConnection?
    private var pcB: RTCPeerConnection?
    private var delegateA: DemoLoopbackDelegate?
    private var delegateB: DemoLoopbackDelegate?
    private var sender: RTCRtpSender?

    private var ladder = ScreenShareQuality()
    private var tickTask: Task<Void, Never>?
    private var ticks = 0
    private var lastBytesReceived: Double?
    private var lastBytesSent: Double?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    // MARK: - Start / stop

    /// Builds the loopback, starts listening to the extension and opens the system picker.
    func start() {
        guard phase == .idle else { return }
        note = nil
        guard CallService.shared.state == .idle else {
            note = "End the call first."
            return
        }
        RTCInitializeSSL()
        let factory = RTCPeerConnectionFactory()
        let source = factory.videoSource(forScreenCast: true)
        let track = factory.videoTrack(with: source, trackId: "screen0")
        let capturer = ScreenShareCapturer(source: source)

        let config = RTCConfiguration()
        config.iceServers = []                 // host candidates only: both ends are this phone
        config.sdpSemantics = .unifiedPlan
        config.bundlePolicy = .maxBundle
        config.rtcpMuxPolicy = .require
        config.continualGatheringPolicy = .gatherOnce
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let dA = DemoLoopbackDelegate()
        let dB = DemoLoopbackDelegate()
        guard let a = factory.peerConnection(with: config, constraints: constraints, delegate: dA),
              let b = factory.peerConnection(with: config, constraints: constraints, delegate: dB) else {
            note = "Could not start the video engine."
            return
        }
        dA.other = b
        dB.other = a

        let ini = RTCRtpTransceiverInit()
        ini.direction = .sendOnly
        ini.streamIds = ["screen0"]
        guard let transceiver = a.addTransceiver(with: track, init: ini) else {
            a.close(); b.close()
            note = "Could not start the video engine."
            return
        }

        let session = Self.makeSession(capturer: capturer)
        session.onStarted = { [weak self] in
            self?.capturer?.setLive(true)
        }
        session.onFirstFrame = { [weak self] in
            guard let self, self.phase == .picking else { return }
            self.phase = .live
        }
        session.onEnded = { [weak self] reason in
            guard let self else { return }
            self.tearDown(stopExtension: false)
            self.note = Self.text(for: reason)
        }

        self.factory = factory
        self.source = source
        self.track = track
        self.capturer = capturer
        self.pcA = a
        self.pcB = b
        self.delegateA = dA
        self.delegateB = dB
        self.sender = transceiver.sender
        self.session = session

        // start() BEFORE the picker: it marks the share wanted, or the extension ends itself.
        guard session.start() else {
            tearDown(stopExtension: false)
            note = "Screen sharing is not set up on this build."
            return
        }
        phase = .picking
        ladder.reset()
        applyQuality()
        Self.negotiate(a: a, b: b, delegateA: dA, delegateB: dB) { [weak self] received in
            guard let self, self.pcB === b else { return }
            self.receivedTrack = received
        }
        startClock()
        if !ScreenSharePicker.show() {
            tearDown(stopExtension: true)
            note = "The system picker is not available."
        }
    }

    /// Stop Sharing / Cancel: asks the extension to finish and releases everything.
    func stopSharing() {
        guard phase != .idle else { return }
        tearDown(stopExtension: true)
    }

    /// The X, a real call, or the screen going away.
    func shutdown() {
        tearDown(stopExtension: true)
        note = nil
    }

    /// A real call started: the demo steps aside at once.
    func callStarted() {
        guard phase != .idle else { return }
        tearDown(stopExtension: true)
        note = "Stopped: a call started."
    }

    func setQuality(_ choice: QualityChoice) {
        quality = choice
        if choice == .auto { ladder.reset() }
        applyQuality()
    }

    // MARK: - Background

    /// Without a call's audio session nothing keeps the app running in the background, and the
    /// extension ends the share ~4 s after the app stops stamping. A background task buys about
    /// half a minute to look at another app and come back.
    func didEnterBackground() {
        guard phase != .idle, backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "screen-share-demo") { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.phase != .idle {
                    self.tearDown(stopExtension: true)
                    self.note = "Stopped: the app was in the background too long."
                }
                self.endBackgroundTask()
            }
        }
    }

    func didBecomeActive() {
        endBackgroundTask()
        session?.checkLiveness()
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        let ending = backgroundTask
        backgroundTask = .invalid
        UIApplication.shared.endBackgroundTask(ending)
    }

    // MARK: - Teardown

    private func tearDown(stopExtension: Bool) {
        tickTask?.cancel(); tickTask = nil
        if stopExtension { session?.stop() }
        session = nil
        capturer?.stop(); capturer = nil
        receivedTrack = nil
        delegateA?.other = nil; delegateB?.other = nil
        pcA?.close(); pcB?.close()
        pcA = nil; pcB = nil
        delegateA = nil; delegateB = nil
        sender = nil
        track = nil
        source = nil
        factory = nil
        phase = .idle
        statsLine = ""
        lastBytesReceived = nil
        lastBytesSent = nil
        ticks = 0
        endBackgroundTask()
    }

    private static func text(for reason: ScreenShareSession.EndReason) -> String {
        switch reason {
        case .extensionEnded: return "Sharing stopped."
        case .extensionGone: return "The broadcast stopped responding."
        case .noFirstFrame: return "The broadcast started but sent no picture."
        }
    }

    // MARK: - Quality

    /// The call's own tier values and rules (CallService.setShareEncoding / shareFramerate).
    private func applyQuality() {
        let index = quality == .auto ? ladder.index : quality.rawValue
        tierIndex = index
        let tier = ScreenShareQuality.tiers[index]
        let fps = index == 0 ? max(30, tier.maxFramerate) : tier.maxFramerate
        session?.setMaxFramerate(fps)
        capturer?.setMaxFramerate(fps)
        guard let sender else { return }
        let params = sender.parameters
        params.degradationPreference = NSNumber(value: RTCDegradationPreference.maintainResolution.rawValue)
        for enc in params.encodings {
            enc.maxBitrateBps = NSNumber(value: tier.maxBitrate)
            enc.maxFramerate = NSNumber(value: fps)
            enc.scaleResolutionDownBy = tier.scaleDown > 1 ? NSNumber(value: tier.scaleDown) : nil
        }
        sender.parameters = params
    }

    // MARK: - Stats clock

    private func startClock() {
        tickTask?.cancel()
        tickTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, !Task.isCancelled else { return }
                self.tick()
            }
        }
    }

    private func tick() {
        if CallService.shared.state != .idle { callStarted(); return }
        ticks += 1
        if let b = pcB {
            b.statistics { [weak self] report in
                let inbound = Self.inbound(report)
                DispatchQueue.main.async {
                    guard let self, self.pcB === b else { return }
                    self.showInbound(inbound)
                }
            }
        }
        // The ladder reads one sample every 2 s, as in a call.
        if quality == .auto, ticks % 2 == 0, let a = pcA {
            a.statistics { [weak self] report in
                let outbound = Self.outbound(report)
                DispatchQueue.main.async {
                    guard let self, self.pcA === a else { return }
                    self.feedLadder(outbound)
                }
            }
        }
    }

    private func showInbound(_ s: InboundSample?) {
        guard let s else { statsLine = ""; return }
        var kbps = 0
        if let last = lastBytesReceived, s.bytes >= last { kbps = Int((s.bytes - last) * 8 / 1000) }
        lastBytesReceived = s.bytes
        statsLine = "\(Int(s.fps.rounded())) fps · \(s.width)×\(s.height) · \(kbps) kbps"
    }

    private func feedLadder(_ o: OutboundSample) {
        guard quality == .auto else { return }
        var sample = ScreenShareQuality.Sample()
        sample.availableBitrate = o.available
        if let bytes = o.bytesSent {
            if let last = lastBytesSent, bytes >= last { sample.sendBitrate = (bytes - last) * 8 / 2 }
            lastBytesSent = bytes
        }
        sample.fractionLost = o.fractionLost
        sample.roundTripTime = o.rtt
        sample.bandwidthLimited = o.bandwidthLimited
        if ladder.evaluate(sample) { applyQuality() }
    }

    // MARK: - Off-main helpers (nothing here touches the engine)

    /// Built outside the main actor: `onFrame` runs on the session's reader queue.
    nonisolated private static func makeSession(capturer: ScreenShareCapturer) -> ScreenShareSession {
        ScreenShareSession { frame, rotation in
            capturer.push(frame, rotationDegrees: rotation)
        }
    }

    /// A.offer -> A.setLocal -> B.setRemote -> B.answer -> B.setLocal -> A.setRemote. `done` gets
    /// B's received video track, on main.
    nonisolated private static func negotiate(a: RTCPeerConnection, b: RTCPeerConnection,
                                              delegateA: DemoLoopbackDelegate, delegateB: DemoLoopbackDelegate,
                                              done: @escaping (RTCVideoTrack?) -> Void) {
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        a.offer(for: constraints) { offer, error in
            guard let offer else { NSLog("[ScreenShareDemo] offer failed: %@", String(describing: error)); return }
            a.setLocalDescription(offer) { _ in
                b.setRemoteDescription(offer) { error in
                    if let error { NSLog("[ScreenShareDemo] B remote failed: %@", String(describing: error)); return }
                    delegateA.flush()   // A's candidates go to B, which can take them now
                    let received = b.transceivers.first { $0.mediaType == .video }?.receiver.track as? RTCVideoTrack
                    b.answer(for: constraints) { answer, _ in
                        guard let answer else { return }
                        b.setLocalDescription(answer) { _ in
                            a.setRemoteDescription(answer) { _ in
                                delegateB.flush()   // and B's to A
                                DispatchQueue.main.async { done(received) }
                            }
                        }
                    }
                }
            }
        }
    }

    struct InboundSample { let fps: Double; let width: Int; let height: Int; let bytes: Double }

    nonisolated private static func inbound(_ report: RTCStatisticsReport) -> InboundSample? {
        guard let s = report.statistics.values.first(where: {
            $0.type == "inbound-rtp"
                && (($0.values["kind"] as? String) ?? ($0.values["mediaType"] as? String)) == "video"
        }) else { return nil }
        let v = s.values
        return InboundSample(fps: (v["framesPerSecond"] as? NSNumber)?.doubleValue ?? 0,
                             width: (v["frameWidth"] as? NSNumber)?.intValue ?? 0,
                             height: (v["frameHeight"] as? NSNumber)?.intValue ?? 0,
                             bytes: (v["bytesReceived"] as? NSNumber)?.doubleValue ?? 0)
    }

    struct OutboundSample {
        var available: Double?
        var bytesSent: Double?
        var fractionLost: Double?
        var rtt: Double?
        var bandwidthLimited = false
    }

    nonisolated private static func outbound(_ report: RTCStatisticsReport) -> OutboundSample {
        var out = OutboundSample()
        let stats = report.statistics.values
        if let pairId = stats.first(where: { $0.type == "transport" })?.values["selectedCandidatePairId"] as? String,
           let pair = report.statistics[pairId] {
            out.available = (pair.values["availableOutgoingBitrate"] as? NSNumber)?.doubleValue
        }
        if let o = stats.first(where: {
            $0.type == "outbound-rtp"
                && (($0.values["kind"] as? String) ?? ($0.values["mediaType"] as? String)) == "video"
        }) {
            out.bytesSent = (o.values["bytesSent"] as? NSNumber)?.doubleValue
            out.bandwidthLimited = (o.values["qualityLimitationReason"] as? String) == "bandwidth"
        }
        if let r = stats.first(where: {
            $0.type == "remote-inbound-rtp"
                && (($0.values["kind"] as? String) ?? ($0.values["mediaType"] as? String)) == "video"
        }) {
            out.fractionLost = (r.values["fractionLost"] as? NSNumber)?.doubleValue
            out.rtt = (r.values["roundTripTime"] as? NSNumber)?.doubleValue
        }
        return out
    }
}

/// One peer connection's delegate: hands every ICE candidate straight to the other connection.
/// Called on WebRTC's signaling thread; touches nothing but the other connection.
/// Candidates that come before the other side has its remote description are held until `flush()`.
final class DemoLoopbackDelegate: NSObject, RTCPeerConnectionDelegate {
    weak var other: RTCPeerConnection?
    private let lock = NSLock()
    private var ready = false
    private var pending: [RTCIceCandidate] = []

    /// The other side now has its remote description: hand over everything held so far.
    func flush() {
        lock.lock()
        ready = true
        let held = pending
        pending = []
        lock.unlock()
        held.forEach(deliver)
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        lock.lock()
        if !ready { pending.append(candidate); lock.unlock(); return }
        lock.unlock()
        deliver(candidate)
    }

    private func deliver(_ candidate: RTCIceCandidate) {
        other?.add(candidate) { err in
            if let err { NSLog("[ScreenShareDemo] addIceCandidate failed: %@", String(describing: err)) }
        }
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}
