import Foundation
import Observation
import AVFoundation
import UIKit   // app-lifecycle notification (foreground backstop for the background camera)
import UserNotifications   // "sharing video" note when their camera comes on while we're backgrounded
import CoreMedia
import WebRTC
import FirebaseAuth
import FirebaseFirestore
import FirebaseFunctions

// Voice calling over WebRTC, signalled through Firestore `calls/{id}` (offer/answer
// + caller/callee ICE candidate subcollections) — the same design the RN web client
// used. Media is peer-to-peer (STUN/TURN); the server only relays signalling.
//
// NOTE: untested from CI — WebRTC needs two real devices. Compile-checked only.
@Observable
final class CallService: NSObject {
    static let shared = CallService()

    private var lifecycleObserved = false
    private func observeLifecycleIfNeeded() {
        guard !lifecycleObserved else { return }
        lifecycleObserved = true
        NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.appWillEnterForeground()
        }
        // SECOND SHOT at taking the system PiP down, once the app is fully ACTIVE. AVKit can ignore a
        // stop request fired at willEnterForeground (the scene is not active yet), which left Apple's
        // window up next to our own FloatingCallWindow — the two-PiP report, again. Idempotent no-op
        // when nothing is up.
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                               object: nil, queue: .main) { _ in
            CallPiPController.shared.stopSystemPiP()
        }
        // The camera is driven by what the CAPTURE SESSION actually does, not by the app lifecycle.
        // See the "Background camera" section below for why.
        NotificationCenter.default.addObserver(forName: AVCaptureSession.wasInterruptedNotification,
                                               object: nil, queue: .main) { [weak self] note in
            self?.captureInterrupted(note)
        }
        NotificationCenter.default.addObserver(forName: AVCaptureSession.interruptionEndedNotification,
                                               object: nil, queue: .main) { [weak self] note in
            self?.captureInterruptionEnded(note)
        }
    }

    // .reconnecting = the media path dropped mid-call; we're trying to recover it.
    enum State: Equatable { case idle, outgoing, incoming, active, reconnecting, ended }

    // Why a call ended — drives the end tone, the status label, and the call record.
    enum EndReason: String { case none, hangup, declined, missed, failed, busy }

    var state: State = .idle {
        didSet {
            // connectedDate is set on ACTUAL media connect (iceConnectionState .connected), NOT here —
            // state flips to .active at signaling time, which would inflate the call duration (H1).
            if state == .outgoing, cameraOn {
                // Outgoing VIDEO call: ringback through the LOUDSPEAKER — you're looking at
                // your preview at arm's length, not holding the phone to your ear.
                isSpeaker = true; wantsSpeaker = true
                try? AVAudioSession.sharedInstance().overrideOutputAudioPort(.speaker)
            }
            if state == .active {
                // Video calls default to speakerphone. startedAsVideo covers the CALLEE: cameraOn is
                // set on the answer paths, and this also holds if that ever changes — they're watching
                // video at arm's length either way, so audio must go loud.
                // (This comment used to describe a "camera-off-on-answer model". That is WRONG: three
                // sites set cameraOn = isVideoCall on answer. Corrected so it stops misleading.)
                if cameraOn || startedAsVideo { isSpeaker = true; wantsSpeaker = true }
                try? AVAudioSession.sharedInstance().overrideOutputAudioPort(isSpeaker ? .speaker : .none)
                startRouteObservation()   // smart speaker button: track where audio actually goes
                observeLifecycleIfNeeded()   // capture-session interruption -> camera pause/resume
                startHeartbeat()             // prove we're alive; detect a force-quit on the other side
                startLinkMonitor()           // weak link -> drop to audio rather than starve it
                updateInCallScreenBehavior() // proximity (voice) / keep-awake (video)
            }
            if state == .idle {
                connectedDate = nil; isMuted = false; isSpeaker = false
                wantsSpeaker = false        // stale intent made the NEXT voice call blast on loudspeaker
                cameraPausedByBackground = false; stopPausedCameraRetry()
                stopLinkMonitor()
                calleeRinging = false; calleeAccepted = false; wasAccepted = false; recordWritten = false; minimized = false; liveRingRowId = nil
                endReason = .none; negotiationVersion = 0; appliedRemoteRestart = 0
                pendingOffer = nil
                pendingRemoteCandidates = []; localCandidateBuffer = []; callDocCreated = false
                stopRingback(); stopTone(); cancelTimers()
                cameraOn = false; remoteCameraOn = false; remoteMuted = false; isHeld = false
                usingFrontCamera = true; startedAsVideo = false; everVideo = false; pendingSwitchTarget = nil
                isLocalExpanded = false; pipOffset = .zero; pipBase = .zero
                videoCapturer?.stopCapture(); videoCapturer = nil
                localVideoTrack = nil; remoteVideoTrack = nil
                updateInCallScreenBehavior() // proximity off + allow sleep again
                // Glare: I stood down so the other side's call could win. Re-arm the listener now that
                // I am genuinely idle — their doc is unchanged, so only a fresh snapshot will ring me.
                if recheckIncomingWhenIdle {
                    recheckIncomingWhenIdle = false
                    observeIncoming()
                }
            }
        }
    }
    var otherName: String = ""
    var otherPhotoUrl: String?
    var isMuted = false
    var isSpeaker = false
    var minimized = false            // call screen minimized -> show the floating pill instead
    var calleeRinging = false        // caller: the other phone is actually ringing now
    /// Caller: the other person TAPPED ACCEPT (the instant `acceptedAt` signal — his two-phone
    /// report: the caller sat on "Ringing…" for the whole answer setup, and on the 12:27 call the
    /// answer write died silently and the caller rang out on a call that was picked up). The label
    /// flips to "Connecting…" and the ringback stops on this, not on the SDP answer.
    var calleeAccepted = false
    var connectedDate: Date?
    var endReason: EndReason = .none // last/in-progress end reason (UI reads it for the label)
    private var recordWritten = false
    /// EITHER side accepted this call (callee: the tap; caller: the acceptedAt signal). The standard messengers'
    /// record rule, adopted on his order: an accepted call that then FAILS logs as a plain call,
    /// never as "missed" — the person answered, and a red "Missed call · Call back" in the
    /// answerer's own chat reads as a lie.
    private var wasAccepted = false
    /// Set when THIS device (the caller) wrote the live "Ringing" row. Cleared when recordCall
    /// finalises it; if a teardown path suppresses the record (glare loser, blocked, answered
    /// elsewhere), finishCall deletes the row instead, so no chat keeps a call that never became
    /// anything. See ChatService.recordCallRinging.
    private var liveRingRowId: String?
    private var ringbackPlayer: AVAudioPlayer?
    private var tonePlayer: AVAudioPlayer?       // busy / ended one-shot tones
    private var localAudioTrack: RTCAudioTrack?
    // Video (1:1). Each side controls its OWN camera independently: no
    // permission — turning your camera on just sends your video and the other side sees it. The
    // video layout shows whenever EITHER camera is on.
    var cameraOn = false            // is MY camera sending
    var remoteCameraOn = false      // is THEIR camera sending (from the `cams` signal)
    var remoteMuted = false         // is THEIR mic muted (from the `muted` signal)
    var isVideo: Bool { cameraOn || remoteCameraOn }   // show the video layout
    /// STICKY: true from the first moment a camera came on, and it stays true for the rest of the call
    /// even if both cameras go off again. It drives the auto-hiding controls: a call that has been a
    /// video call keeps behaving like one, so the controls do not start reappearing permanently just
    /// because someone closed their camera for a minute. Cleared only when the call ends.
    /// ALSO drives the call record: a voice call where a camera came on logs as a video call.
    private(set) var everVideo = false
    /// Latch `everVideo`. It must be called from EVERY place a camera can come on, not just the mid-call
    /// toggle path: a call PLACED or ANSWERED as video sets `cameraOn` directly at setup and never goes
    /// through `setMyCamera`/`applyVideoAudioPolicy`. Latching only there left the flag false for the
    /// person who ANSWERED — their tap-to-hide-the-controls did nothing while the caller's worked, which
    /// is exactly what two phones showed.
    private func noteVideo() { if cameraOn || remoteCameraOn { everVideo = true } }
    /// Whatever is on the BIG screen right now — which is what the floating PiP window must show when you
    /// leave the app. The PiP was hard-wired to the remote feed, so after tapping the tile to swap
    /// yourself fullscreen, leaving the app put the OTHER person in the floating window: the big screen
    /// showed one feed and the PiP the other. `isLocalExpanded` is the same state the layout uses, so the
    /// two can never disagree again.
    var bigScreenTrack: RTCVideoTrack? { isLocalExpanded ? localVideoTrack : remoteVideoTrack }

    /// The WHOLE call layout for a floating window — big feed plus corner tile, like FaceTime — so the
    /// floating window is the call screen in miniature instead of one lone feed. Both follow the same
    /// `isLocalExpanded` swap the call screen uses. A track is offered only while that camera is
    /// actually SENDING (the track object lingers after someone turns their camera off); when it is
    /// not, the slot carries that person's name and photo instead, so a switched-off camera shows who
    /// it is rather than a black rectangle or an empty corner.
    struct PiPFeeds {
        var big: RTCVideoTrack?
        var tile: RTCVideoTrack?
        var mirrorBig = false
        var mirrorTile = false
        var bigName = ""
        var bigPhotoUrl: String?
        var tileName = ""
        var tilePhotoUrl: String?
        var showsTile = false
    }
    /// My own name and photo, for whichever slot is showing MY switched-off camera.
    var myName: String { ProfileStore.shared.me?.name ?? "You" }
    var myPhotoUrl: String? { ProfileStore.shared.me?.photoUrl }

    var pipFeeds: PiPFeeds {
        var f = PiPFeeds()
        if isLocalExpanded {
            f.big = cameraOn ? localVideoTrack : nil
            f.mirrorBig = usingFrontCamera
            f.bigName = myName; f.bigPhotoUrl = myPhotoUrl
            f.tile = remoteCameraOn ? remoteVideoTrack : nil
            f.tileName = otherName; f.tilePhotoUrl = otherPhotoUrl
        } else {
            f.big = remoteCameraOn ? remoteVideoTrack : nil
            f.bigName = otherName; f.bigPhotoUrl = otherPhotoUrl
            f.tile = cameraOn ? localVideoTrack : nil
            f.mirrorTile = usingFrontCamera
            f.tileName = myName; f.tilePhotoUrl = myPhotoUrl
        }
        // The tile belongs to the connected video call, not to a live camera: it stays put with a photo
        // in it when that camera is off. Before the call connects there is only the self-preview.
        f.showsTile = isVideo && (state == .active || state == .reconnecting)
        return f
    }

    private var startedAsVideo = false   // how the call was PLACED (cameras can toggle mid-call) — speaker default at answer
    var usingFrontCamera = true
    // Video layout state — owned HERE so minimize/restore keeps the user's big/small choice and PiP
    // tile position (CallView is destroyed by the cover on minimize; its @State reset every time).
    var isLocalExpanded = false
    var pipOffset = CGSize.zero
    var pipBase = CGSize.zero
    var localVideoTrack: RTCVideoTrack?
    var remoteVideoTrack: RTCVideoTrack?
    private var videoCapturer: RTCCameraVideoCapturer?
    private(set) var callId: String?
    /// Readable so the call screen can draw a verified mark beside the name. Still only writable in
    /// here: who is on the other end of a call is decided by the signalling, never by a view.
    private(set) var otherUid: String = ""
    private var isCaller = false

    // Reconnection / lifecycle timers.
    private var noAnswerWork: DispatchWorkItem?      // outgoing: nobody answered -> Missed
    private var acceptedConnectWork: DispatchWorkItem? // outgoing: they ACCEPTED but the answer never landed -> Failed fast
    private var iceRestartWork: DispatchWorkItem?    // delayed ICE restart after a drop
    private var reconnectGiveUpWork: DispatchWorkItem? // hard cap: can't recover -> Failed
    private var negotiationVersion = 0               // bumps each ICE restart / media renegotiation (caller)
    private var pendingOffer: [String: String]?      // cached incoming offer → answer without a server round-trip
    private var appliedRemoteRestart = 0             // last restart version we applied

    private let db = Firestore.firestore()
    private var pc: RTCPeerConnection?
    private var listeners: [ListenerRegistration] = []
    private var incomingListener: ListenerRegistration?
    private var ringingWatcher: ListenerRegistration?   // while .incoming: detect caller-cancel before answer

    private var me: String { Auth.auth().currentUser?.uid ?? "" }

    private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory()
    }()

    // STUN-only fallback (used until the real TURN relay list arrives from the server, and if
    // that fetch ever fails). STUN alone connects phones on friendly networks; the TURN relay
    // from `iceServers` is what makes calls work across mobile/CGNAT (the reported failures).
    private static let fallbackIceServers = [
        RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302", "stun:stun1.l.google.com:19302"]),
    ]
    // Filled by refreshIceServers() from the `iceServers` Cloud Function (real TURN creds live
    // server-side, never in this public repo). Read on every new peer connection.
    private var fetchedIceServers: [RTCIceServer]?

    private var config: RTCConfiguration {
        let c = RTCConfiguration()
        c.iceServers = fetchedIceServers ?? Self.fallbackIceServers
        c.sdpSemantics = .unifiedPlan
        // Connect faster (shorter "Connecting…"): pre-gather ICE candidates so they're ready the
        // instant the offer/answer is set, keep gathering continuously, and bundle all media on ONE
        // transport so there are far fewer candidate pairs to check before the path comes up.
        c.iceCandidatePoolSize = 1
        c.continualGatheringPolicy = .gatherContinually
        c.bundlePolicy = .maxBundle
        c.rtcpMuxPolicy = .require
        return c
    }

    /// Pull the live TURN/STUN list from the server (short-lived credentials). Call at launch
    /// after sign-in and again when starting/answering a call so credentials are always fresh.
    /// Never throws — on any failure we keep whatever we had (or the STUN fallback).
    func refreshIceServers() async {
        guard let res = try? await Functions.functions(region: "me-central1")
            .httpsCallable("iceServers").call(),
              let arr = (res.data as? [String: Any])?["iceServers"] as? [[String: Any]] else { return }
        let servers: [RTCIceServer] = arr.compactMap { s in
            guard let urls = s["urls"] as? [String] ?? (s["urls"] as? String).map({ [$0] }) else { return nil }
            if let user = s["username"] as? String, let cred = s["credential"] as? String {
                return RTCIceServer(urlStrings: urls, username: user, credential: cred)
            }
            return RTCIceServer(urlStrings: urls)
        }
        if !servers.isEmpty { fetchedIceServers = servers }
    }

    /// Make sure we have a real TURN list BEFORE building a peer connection, without ever holding a call
    /// hostage to a slow network.
    ///
    /// Both call paths used to fire `Task { await refreshIceServers() }` and then build the connection on
    /// the very next line, so the fetch almost never won that race and `config` fell back to STUN-only —
    /// exactly the CGNAT/mobile-data case the TURN relay exists for, and the likeliest cause of "the first
    /// call after opening the app doesn't connect".
    ///
    /// Returns instantly when the list is already warm (the common case: `observeIncoming` fetches at
    /// launch), so this costs nothing except on a genuinely cold start. On timeout we proceed with the
    /// STUN fallback rather than fail the call — a call that might not traverse beats no call at all — and
    /// the in-flight fetch is left running so the NEXT call is warm either way.
    private func awaitIceServers(timeout: Double = 2.0) async {
        if fetchedIceServers != nil { return }
        let fetch = Task { await self.refreshIceServers() }
        let deadline = Date().addingTimeInterval(timeout)
        while fetchedIceServers == nil, Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        _ = fetch   // deliberately NOT cancelled: let it finish and warm the next call
    }

    // Audio session is owned by CallKit (manual mode) — see CallKitManager.

    private func makePeerConnection() -> RTCPeerConnection? {
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let connection = Self.factory.peerConnection(with: config, constraints: constraints, delegate: self)
        // Local mic track.
        let audioSource = Self.factory.audioSource(with: nil)
        let audioTrack = Self.factory.audioTrack(with: audioSource, trackId: "audio0")
        connection?.add(audioTrack, streamIds: ["stream0"])
        localAudioTrack = audioTrack
        // Always negotiate a video m-line up front — the track is DISABLED for a voice call (no
        // frames, no camera). This makes a mid-call camera toggle a pure track-enable with NO
        // renegotiation (which is fragile + glare-prone) and no black-remote-on-re-toggle bugs.
        addLocalVideo(to: connection)
        applyDataSaver(to: connection)
        return connection
    }

    // Use Less Data (Settings > Storage and Data > Calls): cap the sender bitrates when
    // the saver is active on the current network. Audio ~24 kbps still sounds fine for
    // speech; video drops to 300 kbps at half resolution.
    private func applyDataSaver(to connection: RTCPeerConnection?) {
        guard let connection, UseLessDataPage.activeNow else { return }
        for sender in connection.senders {
            let params = sender.parameters
            for enc in params.encodings {
                if sender.track?.kind == "audio" {
                    enc.maxBitrateBps = NSNumber(value: 24_000)
                } else if sender.track?.kind == "video" {
                    enc.maxBitrateBps = NSNumber(value: 300_000)
                    enc.scaleResolutionDownBy = NSNumber(value: 2.0)
                }
            }
            sender.parameters = params
        }
    }

    // MARK: - Opus tuning (DTX + RED)

    // Every SDP we create goes through here before it is installed AND before the same bytes are
    // published to Firestore, so the two can never disagree.
    //
    // Opus DTX and opus RED are both off by default in libwebrtc, and at this SDK version there is no
    // API to switch them on from iOS: RTCRtpTransceiver has no setCodecPreferences (that one is
    // browser-only) and RTCRtpEncodingParameters has no dtx field. Rewriting the SDP is the only lever.
    //
    // What they buy on the mobile networks these calls actually run over: DTX stops the encoder paying
    // full bitrate for silence (only one person talks at a time, and the callee's line is silent for
    // the whole ring), and RED carries the previous opus frame alongside the current one so a single
    // lost packet no longer punches an audible hole.
    //
    // Direction is the reason this has to run on the ANSWER as well as the offer: the parameters in
    // the SDP we send configure the OTHER phone's encoder (RFC 7587 usedtx is stated as the decoder's
    // preference, and libwebrtc picks the send codec out of the remote description). Against a peer on
    // an older build the un-rewritten direction simply stays plain opus and still negotiates.
    private func withOpusDtxAndRed(_ original: RTCSessionDescription) -> RTCSessionDescription {
        RTCSessionDescription(type: original.type, sdp: opusDtxAndRedSdp(from: original.sdp))
    }

    // Deliberately paranoid. A malformed answer does not degrade a call, it kills it, so anything that
    // does not look exactly like what libwebrtc generates is handed back untouched.
    private func opusDtxAndRedSdp(from sdp: String) -> String {
        let eol = sdp.contains("\r\n") ? "\r\n" : "\n"
        var lines = sdp.components(separatedBy: eol)
        guard let mLine = lines.firstIndex(where: { $0.hasPrefix("m=audio ") }) else { return sdp }
        // Stop at the next m= line. A video call's section carries its own rtpmaps, video red/90000
        // included, and matching those would rewrite the wrong m-line.
        let end = lines[(mLine + 1)...].firstIndex(where: { $0.hasPrefix("m=") }) ?? lines.endIndex
        let audio = (mLine + 1)..<end

        func payloadType(of rtpmap: String) -> String? {
            for i in audio where lines[i].hasPrefix("a=rtpmap:") {
                let f = lines[i].dropFirst("a=rtpmap:".count).split(separator: " ", maxSplits: 1)
                if f.count == 2, f[1].trimmingCharacters(in: .whitespaces) == rtpmap { return String(f[0]) }
            }
            return nil
        }
        func fmtpLine(for pt: String) -> Int? { audio.first { lines[$0].hasPrefix("a=fmtp:\(pt) ") } }

        guard let opus = payloadType(of: "opus/48000/2") else { return sdp }

        // DTX and the bitrate ceiling both ride on the fmtp line libwebrtc already writes (minptime,
        // useinbandfec). No such line, or an empty one, and we skip rather than invent the syntax.
        let opusFmtp = "a=fmtp:\(opus) "
        if let i = fmtpLine(for: opus), lines[i].count > opusFmtp.count {
            if !lines[i].contains("usedtx") { lines[i] += ";usedtx=1" }
            // A voice ceiling, not a music one: opus is clean on speech well below this, and the
            // headroom it frees is the difference between a call holding and a call breaking up on a
            // 2G leg. Budget for roughly double on the wire when RED is also on, since every packet
            // then carries the previous frame as well.
            if !lines[i].contains("maxaveragebitrate") { lines[i] += ";maxaveragebitrate=24000" }
        }

        // libwebrtc offers red directly AFTER opus, which gets it negotiated but never used: the send
        // codec is the first one in the list, so red has to move in front of opus. This is exactly what
        // setCodecPreferences does in a browser, and only the m-line order matters (attributes are
        // looked up by payload type), so the rtpmap/fmtp lines are left where they are.
        if let red = payloadType(of: "red/48000/2"), let i = fmtpLine(for: red) {
            // red's own fmtp has to list this exact opus payload (a=fmtp:63 111/111). Red WITHOUT a
            // valid RFC 2198 line is the M95 shape that fails to negotiate, and preferring that would
            // take the whole audio stream down with it.
            let carried = lines[i].dropFirst(("a=fmtp:\(red) ").count).split(separator: "/")
            var pts = lines[mLine].split(separator: " ").map(String.init)
            // 0...2 are "m=audio", the port and the proto; the payload list starts at 3. Searching only
            // from there is what stops a port number that happens to read like a payload type matching.
            if !carried.isEmpty, carried.allSatisfy({ $0.trimmingCharacters(in: .whitespaces) == opus }),
               pts.count > 4,
               let redAt = pts[3...].firstIndex(of: red),
               let opusAt = pts[3...].firstIndex(of: opus), redAt > opusAt {
                pts.remove(at: redAt)
                pts.insert(red, at: opusAt)
                lines[mLine] = pts.joined(separator: " ")
            }
        }
        return lines.joined(separator: eol)
    }

    // MARK: - Video tracks / capture

    // THE REFERENCE APP'S WARM-UP (read from their source 2026-08-12): the capturer and track need no peer
    // connection, so a video-call ACCEPT can spin the camera up while TURN and the SDP answer are
    // still in flight, and the face shows the instant the call connects instead of a beat later.
    // Idempotent — the later attach reuses whatever is already warm. Torn down by the idle reset.
    private func prepareLocalVideo() {
        guard videoCapturer == nil else { return }
        let source = Self.factory.videoSource()
        let capturer = RTCCameraVideoCapturer(delegate: source)
        let track = Self.factory.videoTrack(with: source, trackId: "video0")
        track.isEnabled = cameraOn
        videoCapturer = capturer
        localVideoTrack = track
        if cameraOn { startCameraCapture() }
    }

    // Adds the local video track (once, at call setup). Only fires the camera + its permission
    // prompt if my camera is actually on now — a voice call adds a silent, disabled track.
    private func addLocalVideo(to connection: RTCPeerConnection?) {
        guard let connection else { return }
        prepareLocalVideo()
        guard let track = localVideoTrack else { return }
        track.isEnabled = cameraOn   // the toggle may have moved between warm-up and attach
        connection.add(track, streamIds: ["stream0"])
    }

    // Ask for camera access, then feed frames into the local track (off the main thread). Without
    // the access check the capturer can silently never produce frames -> black video on both ends.
    private func startCameraCapture() {
        // Register BEFORE the first frame: an outgoing video call captures while still ringing, so
        // waiting for .active would miss a backgrounding during the ring.
        observeLifecycleIfNeeded()
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard granted, let self else { return }
            DispatchQueue.global(qos: .userInitiated).async { self.startCapture(front: self.usingFrontCamera) }
        }
    }

    // How hot the phone is decides how hard we drive the camera. Nothing watched this before, so a long
    // video call just cooked until iOS interrupted the capture session outright — and lowering the frame
    // rate is Apple's DOCUMENTED way to earn a system-pressure interruption back, which means without
    // this the camera could stay dark for the rest of the call. Numbers, not a curve: the point is to
    // back off well before the OS has to.
    private var thermalCaps: (fps: Int, height: Int) {
        switch ProcessInfo.processInfo.thermalState {
        case .critical: return (15, 480)
        case .serious:  return (20, 540)
        default:        return (30, 720)
        }
    }
    private var thermalObserver: NSObjectProtocol?
    private var appliedThermalFps = 30
    private func observeThermalIfNeeded() {
        guard thermalObserver == nil else { return }
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                guard let self, cameraOn, !cameraPausedByBackground, videoCapturer != nil else { return }
                // Only restart when the cap actually MOVED — a restart costs a ~200ms black frame on
                // the other side, so reacting to every notification would be worse than the heat.
                guard thermalCaps.fps != appliedThermalFps else { return }
                let front = usingFrontCamera
                videoCapturer?.stopCapture { [weak self] in
                    DispatchQueue.global(qos: .userInitiated).async { self?.startCapture(front: front) }
                }
        }
    }

    // Pick the camera + a format and start feeding frames into the local track.
    private func startCapture(front: Bool) {
        guard let capturer = videoCapturer else { return }
        let position: AVCaptureDevice.Position = front ? .front : .back
        let devices = RTCCameraVideoCapturer.captureDevices()
        guard let device = devices.first(where: { $0.position == position }) ?? devices.first else { return }
        let formats = RTCCameraVideoCapturer.supportedFormats(for: device)
        let caps = thermalCaps
        let format = formats.min(by: {
            let d1 = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
            let d2 = CMVideoFormatDescriptionGetDimensions($1.formatDescription)
            return abs(Int(d1.height) - caps.height) < abs(Int(d2.height) - caps.height)
        })
        guard let format else { return }
        let fps = min(caps.fps, Int(format.videoSupportedFrameRateRanges.map { $0.maxFrameRate }.max() ?? 30))
        appliedThermalFps = caps.fps
        allowBackgroundCamera(on: capturer.captureSession)
        capturer.startCapture(with: device, format: format, fps: fps) { [weak self] _ in
            guard let self else { return }
            DispatchQueue.main.async {
                // A front↔back switch resolves HERE: the new camera is delivering (or has failed —
                // either way the flipped-away view must come back). The mirror already changed
                // while the view was edge-on/black (the write below this closure).
                if self.pendingSwitchTarget != nil {
                    self.pendingSwitchTarget = nil
                    self.cameraSwitchFlip += 1
                }
                // Only claim video once the session is REALLY running. `cams` was published purely from
                // intent, so a start that never succeeded (most visibly a video call answered from the
                // lock screen, where the camera cannot start and no interruption is posted either) left
                // the other side staring at a BLACK full-screen video with a running timer, forever.
                guard self.cameraOn, self.inLiveCall else { return }
                if capturer.captureSession.isRunning {
                    if self.cameraPausedByBackground { self.resumeCameraIfReallyBack() }
                } else if !self.cameraPausedByBackground {
                    self.cameraPausedByBackground = true
                    self.localVideoTrack?.isEnabled = false   // avatar, never a black rectangle
                    self.broadcastCameraState()
                    self.startPausedCameraRetry()
                }
            }
        }
        // Observed @Observable state must be written on main (this runs on a background queue).
        DispatchQueue.main.async { self.usingFrontCamera = front; self.observeThermalIfNeeded() }
    }

    // Lets the capture session survive backgrounding, so leaving the app does not black out my video
    // for the other side. Apple requires this to be set BEFORE the session starts running, which is
    // why it sits immediately above startCapture — and re-applied on every start, because a camera
    // flip stops and reconfigures the session underneath us.
    //
    // `isMultitaskingCameraAccessSupported` is the system's own answer, not a version check: it is
    // true here because we link iOS 18+ and declare `voip` in UIBackgroundModes (project.yml). If it
    // ever goes false the assignment is refused anyway, and the interruption path below covers us.
    // Apple also requires an ACTIVE PiP window for the frames to keep coming (CallPiPController).
    private func allowBackgroundCamera(on session: AVCaptureSession) {
        guard session.isMultitaskingCameraAccessSupported,
              !session.isMultitaskingCameraAccessEnabled else { return }
        session.beginConfiguration()
        session.isMultitaskingCameraAccessEnabled = true
        session.commitConfiguration()
    }

    func toggleCamera() { setMyCamera(on: !cameraOn) }

    /// Bumped ON MAIN the moment a front↔back switch's NEW camera is genuinely delivering — the
    /// UI's cue to swing the flipped tile back in (see CallView.flipCamera). The mirror
    /// (`usingFrontCamera`) changes in the same breath, while the view is edge-on or black, so the
    /// frozen old frame is never seen re-mirrored. This is the reference behaviour: the switch
    /// animation is driven by the ARRIVAL of the new camera, not by the tap.
    var cameraSwitchFlip = 0
    private var pendingSwitchTarget: Bool?

    func switchCamera() {
        guard cameraOn, let capturer = videoCapturer else { return }
        let next = !usingFrontCamera
        // Deliberately NOT flipping the mirror here (it used to): the frozen last frame keeps its
        // own mirroring through the restart gap; mirror and content swap together at the flip's
        // hidden midpoint, when startCapture's completion reports the new camera live.
        pendingSwitchTarget = next
        // Stop the running capture BEFORE starting the other camera — restarting a live
        // capturer in place can freeze/black the local feed on flip.
        capturer.stopCapture { [weak self] in
            DispatchQueue.global(qos: .userInitiated).async { self?.startCapture(front: next) }
        }
    }

    // MARK: - Camera (each side controls its OWN camera — no permission handshake)

    // Turn MY camera on/off. The video m-line was negotiated at call setup, so this is a pure
    // track-enable + capture start/stop — NO renegotiation. Broadcast my state so the other side
    // shows/hides my video. No prompt: I only ever share MY OWN camera, which is my choice.
    private func setMyCamera(on: Bool) {
        guard state == .active || state == .reconnecting else { return }
        cameraOn = on
        // Turning my own camera off while I am the one FULL SCREEN would leave the big view showing my
        // switched-off camera and push the other person into the corner. Go back to the normal layout.
        // Mirror of the same rule for their camera in handleRemoteCallState.
        if !on, isLocalExpanded { isLocalExpanded = false }
        // An explicit toggle overrides any pause. Without this, a camera turned off and on again while
        // paused left the flag set, and its `!cameraPausedByBackground` guard then swallowed the NEXT
        // real interruption — so the other side would have been left on a frozen frame.
        cameraPausedByBackground = false
        stopPausedCameraRetry()
        // MANUAL INTENT WINS, and it wins permanently. Clearing this here is what stops the weak-link
        // monitor from turning a camera back on that the user themselves switched off: with the flag
        // down there is nothing for the recovery path to resume, and the windows restart from scratch.
        videoPausedForNetwork = false
        linkPolicy.reset()
        localVideoTrack?.isEnabled = on
        if on { startCameraCapture() } else { videoCapturer?.stopCapture() }
        applyVideoAudioPolicy()
        CallKitManager.shared.updateHasVideo(on)
        broadcastCameraState()
        updateInCallScreenBehavior()   // video showing ↔ keep-awake / proximity
    }

    /// The ONE place that decides how call audio is routed and tuned for the current set of live
    /// cameras. Every event that can change that set calls this: my own toggle and THEIRS arriving over
    /// Firestore.
    ///
    /// It exists because those two were not symmetric. `setMyCamera` did route + mode + CallKit + screen
    /// work; `handleRemoteCallState` did almost none. Three separate bugs came out of that one gap:
    ///  • whoever turned their camera off FIRST was stranded on loudspeaker for the rest of the call —
    ///    the earpiece restore only ran on the local toggle path, and it no-ops while the other camera
    ///    is still on, so it never ran again for that person once THEIR camera went off too.
    ///  • turning my camera on force-overrode the output to the built-in speaker even while the user was
    ///    wearing AirPods, contradicting "external devices always win" three lines away in updateAudioRoute.
    ///  • their camera turning on flipped MY proximity sensor off (updateInCallScreenBehavior gates on
    ///    audioRoute == .earpiece) while leaving me on the earpiece — a live screen against the cheek.
    private func applyVideoAudioPolicy() {
        let session = AVAudioSession.sharedInstance()
        let videoShowing = cameraOn || remoteCameraOn
        noteVideo()   // both camera paths (mine and theirs) meet here
        // Echo cancellation follows what the audio is actually DOING, not who owns the camera:
        // .videoChat is tuned for the loudspeaker, .voiceChat for the earpiece. The wrong one is the
        // hear-your-own-voice bug.
        try? session.setMode(videoShowing ? .videoChat : .voiceChat)
        // An external device ALWAYS wins. Never yank audio out of someone's AirPods.
        guard audioRoute != .external else { return }
        if videoShowing {
            isSpeaker = true
            wantsSpeaker = true            // survives CallKit re-activating and resetting the route
            try? session.overrideOutputAudioPort(.speaker)
        } else {
            isSpeaker = false
            wantsSpeaker = false           // without this, updateAudioRoute re-asserts loudspeaker forever
            try? session.overrideOutputAudioPort(.none)
        }
    }

    // Tell the other side whether my camera is on — drives their show/hide of MY video.
    private func broadcastCameraState() {
        guard let id = callId else { return }
        // What we are ACTUALLY sending, not what the user asked for. A camera held down by a capture
        // interruption or a weak link is producing nothing, and announcing it as on is what leaves the
        // other side staring at a frozen face instead of falling back to the avatar. The interruption
        // path already said that was the intent in its own comment; it was still sending `cameraOn`.
        let sending = cameraOn && !cameraPausedByBackground && !videoPausedForNetwork
        db.collection("calls").document(id).updateData(["cams.\(me)": sending])
    }

    // MARK: - Screen behavior during calls
    // Voice call held to the ear → PROXIMITY sensor blanks the screen (no cheek-mutes/hangups).
    // Video showing (either side) → screen NEVER dims/locks (SleepBlocker) and proximity stays OFF.
    func updateInCallScreenBehavior() {
        let inCall = state == .active || state == .reconnecting
        let videoShowing = cameraOn || remoteCameraOn
        let proximity = inCall && !videoShowing && audioRoute == .earpiece
        let keepAwake = inCall && videoShowing
        DispatchQueue.main.async {   // UIDevice + SleepBlocker are main-actor
            UIDevice.current.isProximityMonitoringEnabled = proximity
            if keepAwake { SleepBlocker.shared.add("call-video") }
            else { SleepBlocker.shared.remove("call-video") }
        }
    }

    // MARK: - Background camera (leaving the app keeps your video going, like the reference app)
    //
    // OLD BEHAVIOUR, and why it changed: we used to stop the capturer on didEnterBackground and
    // broadcast cams=false, because iOS suspended the session anyway and the other side was left
    // staring at a FROZEN last frame. iOS 18 opened background capture to any app with `voip` in
    // UIBackgroundModes (we have it) via AVCaptureSession.isMultitaskingCameraAccessEnabled, so
    // stopping ourselves is now the ONLY thing preventing the the reference app behaviour.
    //
    // We no longer guess. The app lifecycle no longer touches the camera at all; we react to what the
    // SESSION reports:
    //   • multitasking access working + PiP up -> no interruption -> video keeps flowing. They see me.
    //   • not working (PiP never started, PiP stashed, another app grabbed the camera) -> the session
    //     is interrupted -> disable the track and broadcast cams=false, so they get the avatar rather
    //     than a freeze. That is exactly the old behaviour, now reached only when actually needed.
    // Self-correcting either way, which is why there is no "does this device support it" branch.
    //
    // `cameraOn` stays true throughout as the INTENT, so the UI and the resume path know to restore.
    private(set) var cameraPausedByBackground = false

    // Anywhere the camera may legitimately be running. Wider than .active on purpose: an OUTGOING
    // video call is already capturing while it rings, and backgrounding during the ring must be
    // handled too.
    private var inLiveCall: Bool { state != .idle && state != .ended }

    // Interruptions that mean "no camera frames". Audio-only reasons must NOT touch the video track.
    private func isVideoInterruption(_ reason: AVCaptureSession.InterruptionReason) -> Bool {
        switch reason {
        case .videoDeviceNotAvailableInBackground,
             .videoDeviceNotAvailableWithMultipleForegroundApps,
             .videoDeviceNotAvailableDueToSystemPressure,
             .videoDeviceInUseByAnotherClient:
            return true
        default:
            return false   // .audioDeviceInUseByAnotherClient and anything new: leave video alone
        }
    }

    private func captureInterrupted(_ note: Notification) {
        // Only OUR capture session, and only reasons that actually stop video frames.
        guard let session = note.object as? AVCaptureSession,
              session === videoCapturer?.captureSession,
              let raw = note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int,
              let reason = AVCaptureSession.InterruptionReason(rawValue: raw),
              isVideoInterruption(reason) else { return }
        guard inLiveCall, cameraOn, !cameraPausedByBackground else { return }
        cameraPausedByBackground = true
        localVideoTrack?.isEnabled = false   // stop sending, so they get the avatar and not a frozen face
        broadcastCameraState()
        startPausedCameraRetry()             // some interruptions never post an "ended" — see below
    }

    private func captureInterruptionEnded(_ note: Notification) {
        // MUST filter by session, exactly like captureInterrupted does. This notification is posted for
        // EVERY AVCaptureSession in the process, and StoryCameraView runs its own. Without this, the
        // story camera ending its interruption would resume the CALL camera and announce cams=true
        // while our session was still interrupted, putting the other side on a frozen frame.
        guard let session = note.object as? AVCaptureSession,
              session === videoCapturer?.captureSession else { return }
        resumeCameraIfReallyBack()
    }

    // The single resume path. Trusts the SESSION, never a flag: `isInterrupted` and `isRunning` are the
    // system's own answer, so this is safe to call speculatively from anywhere and cannot announce video
    // we are not actually producing.
    private func resumeCameraIfReallyBack() {
        // The user may have hung up or turned the camera off while it was interrupted — re-check the
        // intent instead of blindly restoring.
        guard inLiveCall, cameraOn, let session = videoCapturer?.captureSession else { return }
        // Still interrupted: do NOT clear the flag and do NOT claim video. Announcing cams=true here
        // was the bug that put the other side on a frozen frame AND swallowed the real resume later.
        guard !session.isInterrupted else { return }
        // Apple preserves the startRunning intent across an interruption as long as we never called
        // stopRunning, so the session resumes itself. Restart only if it genuinely did not.
        if !session.isRunning { startCameraCapture(); return }   // its own start will resume us
        stopPausedCameraRetry()
        guard cameraPausedByBackground || localVideoTrack?.isEnabled == false else { return }
        cameraPausedByBackground = false
        localVideoTrack?.isEnabled = true
        broadcastCameraState()   // they see my video come back
    }

    // Some interruptions never post an "ended". The documented example is thermal/system pressure, whose
    // recovery Apple expects the app to earn by lowering the frame rate (we do not, yet — see the audit),
    // and it fires in the FOREGROUND, where no app-lifecycle backstop can ever run. Camera-stolen-by-
    // another-app is the same shape. So while paused we re-check the session on a timer; the check is
    // cheap and self-cancels. Without this the camera stays dark and cams=false for the rest of the call.
    private var pausedCameraRetry: Timer?
    private func startPausedCameraRetry() {
        guard pausedCameraRetry == nil else { return }
        pausedCameraRetry = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard inLiveCall, cameraOn, cameraPausedByBackground else { stopPausedCameraRetry(); return }
            resumeCameraIfReallyBack()
        }
    }
    private func stopPausedCameraRetry() {
        pausedCameraRetry?.invalidate()
        pausedCameraRetry = nil
    }

    // MARK: - Weak-signal video fallback (1:1 only)

    // Group calls do NOT need this: their simulcast ladder steps 540p down to 360p down to 180p, so a
    // weak leg loses resolution instead of the call. A 1:1 call has no ladder and no floor, so video
    // just keeps competing with the audio until neither works. This is that missing floor.

    /// Video is off because the LINK cannot carry it, not because the user turned it off. The UI reads
    /// this to say so. `cameraOn` deliberately stays TRUE throughout: it holds the user's intent, and
    /// the moment the link recovers we restore what they actually asked for.
    private(set) var videoPausedForNetwork = false

    private var linkMonitor: Timer?
    /// The thresholds and both windows live in WeakLinkPolicy, which is pure and unit-tested.
    private var linkPolicy = WeakLinkPolicy()

    private func startLinkMonitor() {
        guard linkMonitor == nil else { return }
        linkMonitor = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.sampleLinkQuality()
        }
    }

    private func stopLinkMonitor() {
        linkMonitor?.invalidate(); linkMonitor = nil
        linkPolicy.reset()
        videoPausedForNetwork = false
    }

    private func sampleLinkQuality() {
        guard inLiveCall, let pc else { stopLinkMonitor(); return }
        // Only meaningful while we are trying to send video at all. A voice call has nothing to pause,
        // and leaving the windows running would carry a stale verdict into the next camera-on.
        guard cameraOn else { linkPolicy.reset(); return }
        pc.statistics { [weak self] report in
            // The ACTIVE pair's estimate. This is what WebRTC's own congestion controller concluded, so
            // it already folds in loss and round-trip time; a separate packet-loss rule bolted on top
            // would only add noise and a second thing to tune.
            let bitrate = report.statistics.values
                .filter { $0.type == "candidate-pair" && ($0.values["state"] as? String) == "succeeded" }
                .compactMap { ($0.values["availableOutgoingBitrate"] as? NSNumber)?.doubleValue }
                .max()
            DispatchQueue.main.async { self?.applyLinkQuality(bitrate) }
        }
    }

    private func applyLinkQuality(_ bitrate: Double?) {
        guard inLiveCall, cameraOn else { return }
        switch linkPolicy.evaluate(bitrate: bitrate, paused: videoPausedForNetwork, now: Date()) {
        case .pause:  pauseVideoForWeakLink()
        case .resume: resumeVideoAfterWeakLink()
        case .none:   break
        }
    }

    private func pauseVideoForWeakLink() {
        // A camera already down for a capture interruption is not ours to take over; that path owns
        // its own resume and would fight us for it.
        guard cameraOn, !cameraPausedByBackground else { return }
        videoPausedForNetwork = true
        localVideoTrack?.isEnabled = false
        videoCapturer?.stopCapture()   // stop paying for frames the link cannot carry
        broadcastCameraState()         // they get the avatar, not a frozen face
        updateInCallScreenBehavior()
    }

    private func resumeVideoAfterWeakLink() {
        videoPausedForNetwork = false
        // Re-check intent rather than blindly restoring: the user may have hung up, or turned the
        // camera off themselves, during the ten seconds we spent deciding the link was healthy.
        guard inLiveCall, cameraOn, !cameraPausedByBackground else { return }
        localVideoTrack?.isEnabled = true
        startCameraCapture()
        broadcastCameraState()
        updateInCallScreenBehavior()
    }

    // Backstop only. If an interruption ended without its notification (or one never fired), returning
    // to the foreground must never leave the camera dark while the intent says it is on. Note it does
    // NOT force the flag first: resumeCameraIfReallyBack decides from the session, so a still-interrupted
    // session correctly does nothing here rather than announcing video that does not exist.
    func appWillEnterForeground() {
        resumeCameraIfReallyBack()
        // TAKE THE SYSTEM PiP DOWN OURSELVES. Nothing here ever did, and iOS only dismisses a PiP window
        // on return by itself when that window is in its NORMAL state. Fling it to the screen edge and
        // iOS STASHES it instead — parked, not dismissed, and it survives the app coming forward. Our own
        // FloatingCallWindow then appears because the call is minimised, and the user is looking at two
        // floating windows, one of which is Apple's and outside our control (user report 2026-07-27).
        //
        // Unconditional and idempotent: stopSystemPiP no-ops when nothing is up, so there is no state to
        // get wrong here. Exactly one floating window can exist from this point.
        CallPiPController.shared.stopSystemPiP()
    }

    // Apply the other side's camera on/off each snapshot (their video m-line already exists; we just
    // reveal/hide it). Their track keeps arriving; `remoteCameraOn` gates whether we render it.
    /// The reference apps' "📹 … is sharing video. Tap to view." — a LOCAL note (the app is alive in
    /// the background on the call's audio session, so no server is involved). Removed when the call
    /// ends so it can never outlive its call.
    private func postVideoSharingNote() {
        let c = UNMutableNotificationContent()
        c.title = otherName
        c.body = "Sharing video. Tap to view."
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "call-video-sharing", content: c, trigger: nil))
    }

    private func handleRemoteCallState(_ d: [String: Any]) {
        notePeerHeartbeat(d)
        // Their mute state. Never signalled before, so muting was completely invisible to the other
        // person: they just heard silence, indistinguishable from a network stall. Our own GROUP call
        // UI already draws a mic-slash for remote participants, so 1:1 was the odd one out.
        if let m = d["muted"] as? [String: Bool], let mutedNow = m[otherUid], mutedNow != remoteMuted {
            remoteMuted = mutedNow
        }
        if let cams = d["cams"] as? [String: Bool], let on = cams[otherUid], on != remoteCameraOn {
            remoteCameraOn = on
            // THEIR CAMERA COMING ON DEMANDS THE SCREEN BACK (owner's side-by-side reference,
            // 2026-08-12; FaceTime agrees): a voice call becoming video is the one moment in a call
            // that needs eyes. Minimized in the app → the call returns fullscreen by itself.
            // Backgrounded → a "sharing video" notification whose tap lands on the fullscreen call
            // (minimized cleared NOW so the foregrounding presents it without another step).
            if on, state == .active || state == .reconnecting {
                minimized = false
                if UIApplication.shared.applicationState != .active { postVideoSharingNote() }
            }
            // Their video is what the swapped layout is BUILT ON: expanded means my feed is fullscreen
            // and theirs is in the tile. If they kill their camera while we are swapped, that tile has
            // nothing to draw and hides itself - taking the tap target with it and stranding me
            // fullscreen on my own face with no way back. Un-swap instead, so their avatar returns to
            // the big view and I go back to the corner, which is the layout for "their camera is off".
            if on == false, isLocalExpanded { isLocalExpanded = false }
            applyVideoAudioPolicy()        // SAME handling as my own toggle — see applyVideoAudioPolicy
            updateInCallScreenBehavior()   // their video appearing/leaving flips keep-awake/proximity
        }
    }

    // MARK: - In-call controls
    func toggleMute() {
        isMuted.toggle()
        localAudioTrack?.isEnabled = !(isMuted || isHeld)
        CallKitManager.shared.setMuted(isMuted)   // lock-screen/system UI stays in sync
        broadcastMuteState()
    }

    /// CallKit put us on hold (almost always: a normal cellular call arrived). Go genuinely quiet and
    /// say so, instead of leaving them with silence they cannot distinguish from a broken connection.
    /// `isMuted` is untouched, so unholding restores the user's OWN choice rather than guessing.
    private(set) var isHeld = false
    func setHeld(_ held: Bool) {
        guard isHeld != held else { return }
        isHeld = held
        localAudioTrack?.isEnabled = !(isMuted || isHeld)
        broadcastMuteState()
    }

    // What the other side needs to know is simply "can they hear me right now", which is mute OR hold.
    private func broadcastMuteState() {
        guard let id = callId else { return }
        db.collection("calls").document(id).updateData(["muted.\(me)": isMuted || isHeld])
    }

    // MARK: - Peer liveness (force-quit detection)
    //
    // Force-quitting the app runs NOTHING: no terminate hook exists, so no "ended" is ever written and
    // the other phone sits on a frozen last frame until its own 30s ICE give-up. There is no Firestore
    // equivalent of onDisconnect, so the only client-side answer is for each side to prove it is alive.
    //
    // Deliberately a plain changing NUMBER, not a serverTimestamp: we never compare their clock to ours,
    // only note LOCALLY when the value last changed. That makes clock skew irrelevant.
    //
    // It only ends the call when BOTH signals agree — their beat stopped AND our own ICE already
    // dropped us into .reconnecting. A stalled Firestore listener alone must never kill a healthy call.
    private var heartbeatTimer: Timer?
    private var lastPeerBeatAt: Date?
    private var lastPeerBeatValue: Double = 0

    private func startHeartbeat() {
        guard heartbeatTimer == nil else { return }
        lastPeerBeatAt = Date()
        writeHeartbeat()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.writeHeartbeat()
            self?.checkPeerLiveness()
        }
    }

    private func stopHeartbeat() {
        heartbeatTimer?.invalidate(); heartbeatTimer = nil
        lastPeerBeatAt = nil; lastPeerBeatValue = 0
    }

    private func writeHeartbeat() {
        guard let id = callId, state == .active || state == .reconnecting else { return }
        db.collection("calls").document(id).updateData(["hb.\(me)": Date().timeIntervalSince1970])
    }

    private func notePeerHeartbeat(_ d: [String: Any]) {
        guard let hb = d["hb"] as? [String: Any],
              let v = (hb[otherUid] as? NSNumber)?.doubleValue, v != lastPeerBeatValue else { return }
        lastPeerBeatValue = v
        lastPeerBeatAt = Date()
    }

    private func checkPeerLiveness() {
        guard state == .reconnecting, let last = lastPeerBeatAt else { return }
        guard Date().timeIntervalSince(last) > 15 else { return }
        endReason = .failed
        hangUp()   // ~15s instead of frozen for 30s+
    }
    // The user's EXPLICIT speaker choice. CallKit/WebRTC re-activate the audio session at
    // connect/answer and reset the route to the earpiece — which used to silently erase a speaker
    // tap made during "Calling…" (the "speaker sometimes doesn't work" bug). Intent is remembered
    // here and re-asserted whenever the system resets the route out from under it.
    private var wantsSpeaker = false

    func toggleSpeaker() {
        isSpeaker.toggle()
        wantsSpeaker = isSpeaker
        // Use AVAudioSession directly — CallKit owns the session in manual mode and
        // RTCAudioSession.lockForConfiguration() can deadlock when called while CallKit
        // is also configuring the session (e.g. right after answer/connect).
        try? AVAudioSession.sharedInstance().overrideOutputAudioPort(isSpeaker ? .speaker : .none)
    }

    // MARK: - Audio route awareness (smart speaker button)

    // Where call audio is coming out right now. With no external device the speaker button is a
    // plain earpiece/speaker toggle; with AirPods/Bluetooth/wired around, the button shows the
    // live route and opens the NATIVE route picker instead (system behavior).
    enum AudioRoute { case earpiece, speaker, external }
    var audioRoute: AudioRoute = .earpiece
    var externalAudioAvailable = false
    private var routeObserver: NSObjectProtocol?

    func startRouteObservation() {
        guard routeObserver == nil else { return }
        updateAudioRoute()
        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
                self?.updateAudioRoute()
        }
    }

    private func updateAudioRoute() {
        let session = AVAudioSession.sharedInstance()
        let outputs = session.currentRoute.outputs
        if outputs.contains(where: { $0.portType == .builtInSpeaker }) { audioRoute = .speaker }
        else if outputs.contains(where: { $0.portType == .builtInReceiver }) || outputs.isEmpty { audioRoute = .earpiece }
        else { audioRoute = .external }
        updateInCallScreenBehavior()
        // The user asked for speaker but a system reset (CallKit re-activation at connect, WebRTC
        // reconfigure) bounced the route back to the earpiece → RE-ASSERT the choice. External devices
        // (AirPods/car) always win — never fight a real device route.
        if wantsSpeaker, audioRoute == .earpiece {
            try? session.overrideOutputAudioPort(.speaker)
            // The follow-up routeChange notification re-runs this and lands in the .speaker branch.
            return
        }
        // Keep the toggle state honest no matter WHAT moved the route (picker, AirPods
        // connecting mid-call, CallKit) — the button highlight reads from this.
        isSpeaker = audioRoute == .speaker
        // ECHO CANCELLATION FOLLOWS THE ROUTE — his two-phone report: both sides on loudspeaker,
        // he heard his own voice come back until the other side left speaker. The AEC mode was
        // only ever chosen by CAMERA (applyVideoAudioPolicy), so a VOICE call flipped to
        // loudspeaker kept the earpiece-tuned canceller (.voiceChat) working against a
        // loudspeaker's acoustics — which is precisely the hear-yourself bug that mode split
        // exists to prevent. The mode now tracks where the sound actually comes OUT, on every
        // route change from any cause: loudspeaker → .videoChat (loudspeaker-tuned AEC, video or
        // not), anything else → .voiceChat. External devices keep .voiceChat: there is no
        // acoustic path from an AirPod to the mic worth retuning for, and their own processing
        // does the rest.
        let wantMode: AVAudioSession.Mode = (audioRoute == .speaker) ? .videoChat : .voiceChat
        if session.mode != wantMode { try? session.setMode(wantMode) }
        // Manual earpiece choice / external route: intent follows reality so we don't re-assert later.
        // NOT while video is showing, though. Clearing it unconditionally meant plugging in AirPods
        // destroyed the speakerphone intent a video call had set, so UNPLUGGING them later landed the
        // call on the EARPIECE — a video call held at arm's length with the audio in the earpiece,
        // because the re-assert branch above had nothing left to re-assert.
        if audioRoute == .external, !(cameraOn || remoteCameraOn) { wantsSpeaker = false }
        // Any external playback device around? Bluetooth headsets surface as available INPUTS
        // during a playAndRecord call; a currently-external route obviously counts too.
        let external: Set<AVAudioSession.Port> = [.bluetoothHFP, .bluetoothLE, .bluetoothA2DP,
                                                  .headphones, .headsetMic, .carAudio]
        let hasExternalInput = (session.availableInputs ?? []).contains { external.contains($0.portType) }
        externalAudioAvailable = hasExternalInput || audioRoute == .external
    }

    // Ringback the CALLER hears while waiting (generated tone, looped). Ensure the
    // audio unit is on + allow mixing so the player outputs while CallKit owns the session.
    private func startRingback() {
        guard ringbackPlayer == nil else { return }
        let s = RTCAudioSession.sharedInstance()
        s.lockForConfiguration()
        // KEEP BLUETOOTH (audit). CallKit's didActivate sets .playAndRecord with
        // [.allowBluetooth, .allowBluetoothA2DP], then calls straight into here — and options are
        // REPLACED, not merged, so starting the ringback with only [.mixWithOthers] tore the HFP
        // route down for the rest of every OUTGOING call. AirPods died the moment you dialled, while
        // answering a call was fine, because this path only runs for the caller.
        try? s.setCategory(.playAndRecord, mode: .voiceChat,
                           options: [.mixWithOthers, .allowBluetooth, .allowBluetoothA2DP])
        s.isAudioEnabled = true
        s.unlockForConfiguration()
        ringbackPlayer = try? AVAudioPlayer(data: RingbackTone.wavData())
        ringbackPlayer?.numberOfLoops = -1
        ringbackPlayer?.prepareToPlay()
        ringbackPlayer?.play()
        armRingbackWatchdog()
    }
    private func stopRingback() {
        ringbackWatchdog?.invalidate(); ringbackWatchdog = nil
        ringbackPlayer?.stop(); ringbackPlayer = nil
    }

    // The ringback must SURVIVE call-setup session churn: WebRTC's audio unit and CallKit both
    // reconfigure the audio session seconds into an outgoing call, and an interrupted AVAudioPlayer
    // stops silently — loops = -1 cannot save it (owner's report: one ring, then silence forever).
    // Same resume-don't-restart rule as audioSessionActivated, applied CONTINUOUSLY: a stalled
    // player is nudged with play() on the same instance (no restart-from-zero blip); only a wedged
    // one that refuses play() is rebuilt. Runs only while the call is still .outgoing.
    private var ringbackWatchdog: Timer?
    private func armRingbackWatchdog() {
        ringbackWatchdog?.invalidate()
        ringbackWatchdog = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self, state == .outgoing, let p = ringbackPlayer else { return }
            if !p.isPlaying, p.play() == false {
                ringbackPlayer = nil
                startRingback()
            }
        }
    }

    // Called by CallKit the instant it activates the audio session. The ringback starts at startCall
    // (deliberate: immediate, the reference app-verified) but the session may not be live yet then — on some
    // devices the early player is SILENT until this fires, on others it is already audible. The old
    // unconditional stop+start covered the silent case but gave the audible case a hear-it, cut,
    // hear-it-again stutter on every call (user report). RESUME, don't restart: an already-playing
    // player is left alone; a silent/stalled one is nudged with play() on the same instance (no
    // restart-from-zero blip); only a wedged player that refuses play() is rebuilt.
    func audioSessionActivated() {
        ringbackFallback?.invalidate(); ringbackFallback = nil
        guard state == .outgoing else { return }   // ringback plays for the whole wait, not only once they ring
        // The session is live NOW. Nothing was started before this point (see beginOutgoingMedia), so
        // this is the FIRST and ONLY start: audible, from the top, with nothing to cut.
        guard ringbackPlayer == nil else { return }
        startRingback()
    }

    /// Belt for the case CallKit never activates the session (activation failure, or a device that
    /// simply does not call back): after a short wait, start the ringback anyway rather than leave the
    /// caller in silence. Cancelled the moment a real activation arrives.
    private var ringbackFallback: Timer?
    private func armRingbackFallback() {
        ringbackFallback?.invalidate()
        ringbackFallback = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: false) { [weak self] _ in
            guard let self, state == .outgoing, ringbackPlayer == nil else { return }
            startRingback()
        }
    }

    // One-shot call-progress tone (busy/declined or ended). Same audio-session nudge
    // as ringback so it outputs while CallKit owns the session.
    private func playTone(_ data: Data, loops: Int) {
        stopTone()
        let s = RTCAudioSession.sharedInstance()
        s.lockForConfiguration()
        // Same Bluetooth preservation as startRingback — this runs at the END of a call, and
        // stripping the options here dropped the route for whatever came next.
        try? s.setCategory(.playAndRecord, mode: .voiceChat,
                           options: [.mixWithOthers, .allowBluetooth, .allowBluetoothA2DP])
        s.isAudioEnabled = true
        s.unlockForConfiguration()
        tonePlayer = try? AVAudioPlayer(data: data)
        tonePlayer?.numberOfLoops = loops
        tonePlayer?.prepareToPlay()
        tonePlayer?.play()
    }
    private func stopTone() { tonePlayer?.stop(); tonePlayer = nil }

    // Play the right tone for how a call ended (caller/receiver feedback).
    private func playEndTone(_ reason: EndReason) {
        stopRingback()
        switch reason {
        // TWO full busy cycles (2s), which is what the 1.8s stop in finishCall actually allows.
        // `loops: 3` claimed "~4s" and was cut off less than halfway through, so the comment and the
        // code disagreed about the one thing a caller hears (audit).
        case .busy: playTone(RingbackTone.busyData(), loops: 1)
        // A DECLINE sounds like a ring-out on purpose (OWNER'S ORDER 2026-08-12, standard-messenger parity): the
        // busy tone after one ring told the caller they were rejected. Declines are hidden
        // everywhere now — tone, end screen, record — so the tone must not leak what the label hides.
        case .failed, .hangup, .missed, .declined: playTone(RingbackTone.endedData(), loops: 0)
        case .none: break
        }
    }

    // MARK: - Lifecycle timers

    private func startNoAnswerTimeout() {
        noAnswerWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self, self.state == .outgoing else { return }   // still never connected
            self.endReason = .missed
            self.hangUp()
        }
        noAnswerWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 45, execute: w)   // ~45s, like big apps
    }

    /// Accepted, but the SDP answer never arrived: give the answering phone 15 seconds to finish
    /// its setup and land the write, then fail HONESTLY on both sides ("Call failed") instead of
    /// ringing into the 45s no-answer timeout on a call that was picked up.
    private func startAcceptedConnectTimeout() {
        acceptedConnectWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self, self.state == .outgoing else { return }   // answer arrived → .active
            self.endReason = .failed
            self.hangUp()
        }
        acceptedConnectWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: w)
    }

    // The CALLEE's own ring-out. The caller cancels an unanswered call after its timeout, but a
    // caller whose app DIES mid-ring cancels nothing, and this phone rang forever. Sixty seconds,
    // then the call ends as MISSED — written explicitly, so the end-reason inference never has to
    // guess about a ring-out, and the last corner of the false-"Declined" family is closed: a
    // decline is a finger, a ring-out is this timer, and neither can be read as the other.
    private var calleeRingWork: DispatchWorkItem?
    private func armCalleeRingTimeout(_ id: String) {
        calleeRingWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.state == .incoming, self.callId == id else { return }
            self.endReason = .missed
            self.finishCall(updateRemote: true, clearCallKit: true, localUser: false)
        }
        calleeRingWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: work)
    }

    private func cancelTimers() {
        calleeRingWork?.cancel(); calleeRingWork = nil
        noAnswerWork?.cancel(); noAnswerWork = nil
        acceptedConnectWork?.cancel(); acceptedConnectWork = nil
        iceRestartWork?.cancel(); iceRestartWork = nil
        reconnectGiveUpWork?.cancel(); reconnectGiveUpWork = nil
        // A pending ringback fallback must die with the call, or a call that ends inside its 1.2s
        // window would start a ringback nothing is left to stop.
        ringbackFallback?.invalidate(); ringbackFallback = nil
    }

    // MARK: - Reconnection (bad / lost connection)

    // Media path dropped. `disconnected` may self-heal, so we wait a few seconds before
    // forcing an ICE restart; `failed` won't, so we restart now. Either way we show
    // "Reconnecting…" and give up after a hard cap.
    private func enterReconnecting(restartAfter delay: Double) {
        guard state == .active || state == .reconnecting else { return }
        if state == .active { state = .reconnecting }
        // Hard cap: if we still haven't recovered, end as Failed.
        if reconnectGiveUpWork == nil {
            let g = DispatchWorkItem { [weak self] in
                guard let self, self.state == .reconnecting else { return }
                self.endReason = .failed
                self.hangUp()
            }
            reconnectGiveUpWork = g
            DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: g)
        }
        // The caller drives the ICE restart (avoids glare).
        guard isCaller else { return }
        iceRestartWork?.cancel()
        let r = DispatchWorkItem { [weak self] in
            guard let self, self.state == .reconnecting else { return }
            self.restartIce()
        }
        iceRestartWork = r
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: r)
    }

    private func recovered() {
        iceRestartWork?.cancel(); iceRestartWork = nil
        reconnectGiveUpWork?.cancel(); reconnectGiveUpWork = nil
        if state == .reconnecting { state = .active }
    }

    // Caller-only: renegotiate ICE (new credentials + candidates), media keeps flowing
    // on recovery. Cheaper than a full re-offer — DTLS/SRTP keys are preserved.
    private func restartIce() {
        guard isCaller, let pc = pc, let id = callId else { return }
        negotiationVersion += 1
        let v = negotiationVersion
        let constraints = RTCMediaConstraints(mandatoryConstraints: ["IceRestart": "true"],
                                              optionalConstraints: nil)
        pc.offer(for: constraints) { [weak self] sdp, _ in
            guard let self, let sdp, let pc = self.pc else { return }
            // createOffer rebuilds the codec list from scratch, so a restart offer that skipped this
            // would flip the order back to opus-first and drop RED for the rest of the call, right at
            // the moment the network is already bad enough to need a reconnect.
            let local = self.withOpusDtxAndRed(sdp)
            pc.setLocalDescription(local) { _ in
                self.db.collection("calls").document(id)
                    .updateData(["restartOffer": ["sdp": local.sdp, "version": v]])
            }
        }
    }

    // Callee marks the call as "ringing" so the caller can switch Calling… → Ringing….
    private func markRinging() {
        guard let id = callId else { return }
        db.collection("calls").document(id).updateData(["ringingAt": FieldValue.serverTimestamp()])
    }

    // MARK: - Outgoing

    /// THE NAME YOU GAVE THEM WINS, on every call screen (owner 2026-08-04: renamed a contact, and the
    /// call still said the old name).
    ///
    /// A nickname is local and lives in ContactNames, while a call carries the name the OTHER side
    /// published. Seven dial sites each passed whatever name they happened to be holding — a profile
    /// its `name`, the chat its `title` — so fixing them one at a time would have been seven fixes and
    /// an eighth waiting to be forgotten. Resolved here instead, which also covers the INCOMING side:
    /// somebody calling you shows as the name you filed them under, not the one they chose.
    static func displayName(for uid: String, fallback: String) -> String {
        guard !uid.isEmpty, let nick = ContactNames.shared.name(for: uid),
              !nick.trimmingCharacters(in: .whitespaces).isEmpty else { return fallback }
        return nick
    }

    /// Somebody whose settings refuse calls, surfaced so the UI can say so once. Cleared by the sheet.
    struct RestrictedCallee: Identifiable, Equatable {
        let id = UUID()
        let uid: String
        let name: String
        let photo: String?
        /// WHERE the call was attempted from decides HOW we say no (owner 2026-08-04).
        ///
        /// The profile gets the full sheet: their picture, the reason, and a Send message button —
        /// you are standing on their page with nothing else in front of you, and offering the thing
        /// you CAN do is useful there. Everywhere else — the chat header, the Calls tab, search —
        /// gets a plain centred alert, because a sheet sliding up over a conversation covers the
        /// conversation, and "Send message" is meaningless when you are already in the message.
        var fromProfile = false
    }
    var restrictedCallee: RestrictedCallee?

    func startCall(to uid: String, name: String, photo: String? = nil, video: Bool = false,
                   fromProfile: Bool = false) {
        guard state == .idle, !uid.isEmpty, !me.isEmpty else { return }   // never start with an empty caller id
        // ONE central block gate (audit). The profile's call tiles learned to hide while blocked, but
        // every other dial site — the Calls tab row button, its long-press menu, New Call, Calls
        // search — still rang a person the user had blocked. Gating here covers all of them at once
        // and cannot be missed by a future entry point.
        let blocked = ConversationsRepository.shared.conversations
            .first { $0.id == ChatService.convId(me, uid) }?.isBlockedByMe(me) ?? false
        guard !blocked else { return }
        // CALL PRIVACY, CHECKED BEFORE THE PHONE RINGS (owner 2026-08-04). The buttons stay live for
        // everyone — hiding them would tell you what somebody chose in their settings, which is
        // nobody's business — so the answer arrives when you press one.
        //
        // HERE, in the same central gate as the block check, for the same reason written above it:
        // there are seven dial sites and a future eighth would forget.
        //
        // The callee ALSO refuses on their own side, and that stays: this is a courtesy so the caller
        // gets a sentence instead of a call that dies for no visible reason. It is not the security
        // boundary and must never be treated as one.
        // Freshen on EVERY press, including a refused one. This used to run only when the call went
        // through, so a person who turned calls back ON stayed refused forever on any surface
        // without the live thread listener (Calls tab, search) — the index had no path back to yes.
        // The decision itself stays synchronous on the cached answer (miss means ring); inside an
        // open chat the thread's own users-doc listener keeps the answer current in real time.
        Task { await CallPrivacyIndex.refresh(uid) }
        if CallPrivacyIndex.refuses(uid, iAmTheirContact: Self.iAmContactOf(uid)) {
            restrictedCallee = RestrictedCallee(uid: uid, name: name, photo: photo, fromProfile: fromProfile)
            return
        }
        cameraOn = video   // a video call = my camera on from the start (the callee's is independent)
        startedAsVideo = video
        noteVideo()
        isCaller = true
        otherUid = uid
        otherName = Self.displayName(for: uid, fallback: name)
        otherPhotoUrl = photo
        state = .outgoing
        // iOS's own call UI and the recents list get the nickname too — the lock screen saying one
        // name while the app says another is worse than either being wrong on its own.
        CallKitManager.shared.startOutgoing(name: otherName)   // native call UI + audio session
        CallKitManager.shared.reportConnecting()

        ensureMicPermission { [weak self] granted in
            guard let self else { return }
            guard granted else { self.hangUp(); return }   // no mic -> don't start a dead call
            // TURN creds must be in hand BEFORE makePeerConnection reads `config` — see awaitIceServers.
            Task { @MainActor in
                await self.awaitIceServers()
                guard self.state == .outgoing else { return }   // cancelled while we waited
                self.beginOutgoingMedia(to: uid)
            }
        }
    }

    // The media half of startCall, split out so the TURN wait can sit between the mic prompt and here.
    private func beginOutgoingMedia(to uid: String) {
            // RINGBACK IS STARTED BY THE AUDIO SESSION, NOT HERE (2026-07-29). Starting it at this
            // point plays into a session CallKit has not activated yet: on some devices that is silent,
            // on others briefly audible — and every scheme that then corrected it on activation was
            // either a stutter (stop+start) or a permanent silence (leave-a-"playing"-but-mute-player
            // alone; AVAudioPlayer reports isPlaying = true even when the session was dead, which is the
            // bug the user heard: one blip, then nothing for the rest of the call). One start, on a live
            // session, is the only version with no failure mode. `armRingbackFallback` covers the case
            // where activation never comes, so the caller can never sit in true silence either.
            self.armRingbackFallback()
            self.startNoAnswerTimeout() // give up after ~45s -> Missed
            let ref = self.db.collection("calls").document()
            self.callId = ref.documentID
            self.pc = self.makePeerConnection()
            let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
            self.pc?.offer(for: constraints) { [weak self] sdp, _ in
                guard let self, let sdp, let pc = self.pc else { return }
                let local = self.withOpusDtxAndRed(sdp)
                pc.setLocalDescription(local) { _ in
                    ref.setData([
                        "caller": self.me,
                        "callee": uid,
                        "callerName": ProfileStore.shared.me?.name ?? "Caller",
                        "callerPhoto": ProfileStore.shared.me?.photoUrl ?? "",
                        "type": self.cameraOn ? "video" : "voice",
                        "status": "ringing",
                        "offer": ["sdp": local.sdp, "type": "offer"],
                        "cams": [self.me: self.cameraOn],   // seed my camera state (per-side)
                        "createdAt": FieldValue.serverTimestamp(),
                    ]) { [weak self] err in
                        guard let self else { return }
                        if err != nil { self.hangUp(); return }   // write failed -> don't leave the caller ringing into the void
                        if self.state != .outgoing {
                            // Caller hung up while the create was in flight: finishCall's update hit a
                            // not-yet-existing doc, so end it here or it would ring the callee later.
                            ref.updateData(["status": "ended", "endReason": EndReason.hangup.rawValue])
                            return
                        }
                        self.callDocCreated = true
                        // THE LIVE RING ROW (owner's 2026-08-12 reference): the chat shows the call
                        // while it happens — "Ringing" now, finalised in place by recordCall.
                        self.liveRingRowId = ref.documentID
                        let ringCid = [self.me, uid].sorted().joined(separator: "_")
                        Task { await ChatService.recordCallRinging(cid: ringCid, callId: ref.documentID,
                                                                   callerUid: self.me, video: self.cameraOn) }
                        self.flushLocalCandidates()   // now the doc exists, write the buffered candidates
                        // CRITICAL: listen only AFTER the doc exists. The rules gate reads on the call
                        // doc's caller/callee fields, so a listener attached before the create commits
                        // is permission-denied — and a denied listener never retries, leaving the
                        // caller deaf to the answer + candidates (every call dies at "Connecting…").
                        self.observeCallDoc(ref)
                        self.observeRemoteCandidates(ref.collection("calleeCandidates"))
                    }
                }
            }
    }

    private func ensureMicPermission(_ done: @escaping (Bool) -> Void) {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: done(true)
        case .denied:  done(false)
        case .undetermined:
            AVAudioApplication.requestRecordPermission { ok in DispatchQueue.main.async { done(ok) } }
        @unknown default: done(false)
        }
    }

    // MARK: - Incoming

    /// While a call is ringing (state == .incoming) but not yet answered, watch the call doc so a
    /// caller-cancel / timeout (status == "ended") tears us down instead of leaving us ringing or
    /// answering a dead call. Removed on answer (observeCallDoc takes over) and on teardown.
    private func watchRingingCancel(_ id: String) {
        ringingWatcher?.remove()
        ringingWatcher = db.collection("calls").document(id).addSnapshotListener { [weak self] snap, _ in
            guard let self, let d = snap?.data() else { return }
            // GHOST-CALL GUARD: a VoIP push can ring this phone because its push token is still listed under a
            // DIFFERENT account (a sign-out cleanup that didn't complete). If the call's callee is NOT the
            // account currently signed in HERE, it isn't for us — end it so it stops ringing. Self-heals stale
            // tokens no matter why the token wasn't removed. Only when `me` is known (auth restored), so a
            // legit call is never killed during a cold launch before auth loads.
            if !self.me.isEmpty, self.state == .incoming,
               let callee = d["callee"] as? String, !callee.isEmpty, callee != self.me {
                self.ringingWatcher?.remove(); self.ringingWatcher = nil
                self.remoteEnded(reason: .hangup)   // ends the CallKit ring on this device
                return
            }
            if (d["status"] as? String) == "ended", self.state == .incoming {
                self.ringingWatcher?.remove(); self.ringingWatcher = nil
                self.remoteEnded(reason: EndReason(rawValue: d["endReason"] as? String ?? "") ?? .hangup)
                return
            }
            // ANSWERED ELSEWHERE. `voipTokens` (users/{uid}/push/tokens) is an array and every signed-in device of mine rings, but
            // this watcher only ever handled "ended" and a callee mismatch — "active" matched neither, so
            // the OTHER phones kept ringing forever after I picked up on one. This watcher is removed the
            // moment THIS device answers (see completeAnswer), so still being .incoming while the doc says
            // active means someone else took it. Stop ringing without touching the doc: the device that
            // answered owns the call now, and writing anything here would fight it.
            if (d["status"] as? String) == "active", self.state == .incoming {
                self.ringingWatcher?.remove(); self.ringingWatcher = nil
                // No tone (localUser: true) — I did answer, just on my other phone — and no doc write,
                // which would fight the device that owns the call now. recordWritten is forced so we do
                // NOT log a missed call: the answering device writes the real record for this same
                // callId, and ours would overwrite it with "missed".
                self.recordWritten = true
                self.finishCall(updateRemote: false, clearCallKit: true, localUser: true)
            }
        }
    }

    /// App-wide listener: ring when someone calls me.
    func observeIncoming() {
        incomingListener?.remove()
        guard !me.isEmpty else { return }
        Task { await refreshIceServers() }   // warm the TURN list at launch so the first call has it

        incomingListener = db.collection("calls")
            .whereField("callee", isEqualTo: me)
            .whereField("status", isEqualTo: "ringing")
            .addSnapshotListener { [weak self] snap, _ in
                guard let self, let doc = snap?.documents.first else { return }
                let d = doc.data()
                // H3: ignore zombie ringing docs (caller crashed mid-ring) so they don't re-ring forever.
                if let ts = (d["createdAt"] as? Timestamp)?.dateValue(), Date().timeIntervalSince(ts) > 60 { return }
                // H4: already in a LIVE call → send this new caller a busy signal instead of dropping
                // them silently. `.ended` is NOT a live call: it is a cosmetic 1-2s tail before idle
                // (see finishCall), and treating it as busy meant an instant redial — or a third
                // person calling in that window — was rejected with a busy nobody was busy for, plus
                // a phantom missed row (audit).
                let inLiveCall = [.outgoing, .incoming, .active, .reconnecting].contains(self.state)
                if inLiveCall {
                    if doc.documentID != self.callId {
                        let caller = d["caller"] as? String ?? ""
                        // GLARE: we dialled each other at the same moment, so we are each other's
                        // "incoming call while busy" and both sides sent busy — killing BOTH calls and
                        // leaving two Missed rows in one chat. Break the tie on the only thing both
                        // phones already agree on: the two uids. Lower uid keeps its outgoing call and
                        // busies the other; higher uid gives up its own so the survivor can ring here.
                        if self.state == .outgoing, !caller.isEmpty, caller == self.otherUid {
                            if self.me < caller {
                                self.db.collection("calls").document(doc.documentID)
                                    .updateData(["status": "ended", "endReason": EndReason.busy.rawValue])
                                return
                            }
                            // I lose: cancel MY outgoing call, then re-arm the incoming listener once we
                            // are actually idle. Re-arming is required, not optional — their doc does not
                            // change when I stand down, so no further snapshot would ever arrive and I
                            // would sit idle while their phone rings on alone.
                            self.recheckIncomingWhenIdle = true
                            self.endReason = .hangup
                            // Standing down in glare is bookkeeping, not a missed call. Without
                            // this the loser wrote a call record whose outcome reads "missed" on
                            // the WINNER's phone — a red missed row for the person they are
                            // connecting with a second later (audit). Same suppression the
                            // answered-elsewhere path already uses.
                            self.recordWritten = true
                            self.finishCall(updateRemote: true, clearCallKit: true, localUser: true)
                            return
                        }
                        self.db.collection("calls").document(doc.documentID)
                            .updateData(["status": "ended", "endReason": EndReason.busy.rawValue])
                        // A busy call left NO trace on this phone: the caller got a Missed row, I got
                        // nothing and never learned they tried. Log it here (same deterministic doc id
                        // the caller uses, same "missed" outcome, so the two writes agree).
                        if !caller.isEmpty {
                            let cid = [self.me, caller].sorted().joined(separator: "_")
                            let isVideo = (d["type"] as? String) == "video"
                            Task {
                                await ChatService.recordCall(cid: cid, callId: doc.documentID,
                                                             callerUid: caller, outcome: "missed",
                                                             video: isVideo, durationSec: 0)
                            }
                        }
                    }
                    return
                }
                let caller = d["caller"] as? String ?? ""
                // THE SHARED GATE, not a second copy of it. This path had its own inline version of
                // the blocked + Calls-privacy check, with the same discarded read error — so the
                // comment on `callAllowed` claiming both paths shared it was simply untrue, and the
                // false-decline bug lived here twice. Silent block and Calls privacy both still
                // apply; the difference is that a read which FAILS no longer reads as a refusal.
                self.callAllowed(from: caller) { allowed in
                    guard allowed else {
                        self.db.collection("calls").document(doc.documentID)
                            .updateData(["status": "ended", "endReason": EndReason.declined.rawValue])
                        return
                    }
                    guard self.state == .idle else { return }
                    self.callId = doc.documentID
                    self.otherUid = caller
                    self.otherName = Self.displayName(for: caller,
                                                      fallback: d["callerName"] as? String ?? "Caller")
                    let photo = d["callerPhoto"] as? String ?? ""
                    self.otherPhotoUrl = photo.isEmpty ? nil : photo
                    self.isCaller = false
                    let isVideoCall = (d["type"] as? String == "video")
                    // Camera-on-answer model (user choice): accepting a video call opens MY camera immediately —
                    // both sides see each other the instant the call connects.
                    self.cameraOn = isVideoCall
                    self.startedAsVideo = isVideoCall
                    self.noteVideo()
                    self.pendingOffer = d["offer"] as? [String: String]    // cache → answer with no server round-trip
                    if let cams = d["cams"] as? [String: Bool], let on = cams[caller] { self.remoteCameraOn = on }
                    self.state = .incoming
                    // TURN starts fetching AT RING TIME on this path too — the push path has done
                    // this since the awaitIceServers fix, but the foreground listener path never
                    // did, so answering a call that rang while the app was OPEN could pay the whole
                    // TURN fetch (up to its 2s cap) inside "Connecting…". Fetched during the ring,
                    // it is warm by pickup and the await is a no-op.
                    Task { await self.refreshIceServers() }
                    CallKitManager.shared.reportIncoming(callId: doc.documentID, name: self.otherName,
                                                        video: isVideoCall, callerUid: caller)
                    self.markRinging()
                    self.watchRingingCancel(doc.documentID)   // tear down if the caller cancels before I answer
                    self.armCalleeRingTimeout(doc.documentID) // and end as MISSED if nobody ever does either
                }
            }
    }

    /// Set up an incoming call from a VoIP push (app may be cold-launching) so that a
    /// subsequent CallKit answer connects. No ringing here — CallKit shows the ring.
    func prepareIncoming(callId: String, name: String, uid: String, photo: String?, video: Bool = false) {
        // Busy: a VoIP push arriving mid-call must NOT overwrite the live call's identity/state (C3).
        // CRITICAL: only busy a DIFFERENT call. When the app is foreground, the Firestore listener
        // rings first and this push arrives seconds later FOR THE SAME CALL — busying it here made
        // the call end itself after ~2s of ringing (and the repeated instant-kills got our VoIP
        // pushes throttled by Apple → "sometimes doesn't ring, sometimes late").
        guard state == .idle else {
            if callId != self.callId {
                db.collection("calls").document(callId).updateData(["status": "ended", "endReason": EndReason.busy.rawValue])
            }
            return
        }
        self.cameraOn = video   // camera-on-answer model: accepting a video call opens my camera immediately
        self.startedAsVideo = video
        self.noteVideo()
        self.callId = callId
        self.otherName = Self.displayName(for: uid, fallback: name)
        self.otherUid = uid
        self.otherPhotoUrl = (photo?.isEmpty == false) ? photo : nil
        self.isCaller = false
        self.state = .incoming   // so the UI can present once answered
        Task { await refreshIceServers() }   // ensure fresh TURN before the callee builds its connection
        armCalleeRingTimeout(callId)         // a dead caller cancels nothing; end as MISSED after 60s
        // markRinging() is DEFERRED until the gate below answers (audit). Telling the caller
        // "Ringing…" and then ending the call a round-trip later gave a blocked caller a distinct
        // signature — ring-then-instant-decline when my app is killed, versus a silent 45s ring-out
        // when it is open — which is exactly the tell silent blocking exists to avoid.
        watchRingingCancel(callId)   // tear down if the caller cancels before I answer
        // BLOCKED / PRIVACY. The Firestore listener path gates on both; this PUSH path gated on
        // NEITHER, so with the app killed a blocked caller — or one excluded by "No One" / "My
        // Contacts" — rang straight through, which is the exact situation blocking is for.
        // iOS requires reportNewIncomingCall in the same run loop as the push, so the ring genuinely
        // cannot wait on an async lookup: PushManager reports first and we end it the moment we know.
        callAllowed(from: uid) { [weak self] ok in
            guard let self, self.state == .incoming, self.callId == callId else { return }
            guard ok else {
                // Refuse WITHOUT ever having marked it ringing: from the caller's side this is the
                // same silent non-answer the foreground listener path produces.
                self.db.collection("calls").document(callId)
                    .updateData(["status": "ended", "endReason": EndReason.declined.rawValue])
                self.recordWritten = true   // a blocked call leaves no trace, same as the listener path
                self.finishCall(updateRemote: false, clearCallKit: true, localUser: true)
                return
            }
            self.markRinging()   // allowed — only now does the caller hear it ring
        }
    }

    /// THE CALLER'S COPY OF THE CALLEE'S CONTACT TEST, and it must stay identical to the one in
    /// `callAllowed` below: a 1:1 conversation that exists and carries a last message. There is only
    /// ONE such document and both people can read it, so the caller does not need to fetch anything
    /// — the conversation is already in the list on screen. Synchronous, because this is decided on
    /// the frame the call button is pressed.
    ///
    /// Unknown (no local conversation) answers false, which through `CallPrivacyIndex.refuses` means
    /// somebody on My Friends whom we have never spoken to is warned about. That is the correct
    /// answer: with no conversation there is no last message, so their phone would refuse too.
    static func iAmContactOf(_ uid: String) -> Bool {
        let me = Auth.auth().currentUser?.uid ?? ""
        guard !me.isEmpty, !uid.isEmpty else { return false }
        guard let conv = ConversationsRepository.shared.conversations
            .first(where: { !$0.isGroup && $0.otherUid(me) == uid }) else { return false }
        return !conv.lastMessageCipher.isEmpty
    }

    /// Blocked + Calls-privacy gate, shared by both incoming paths so they cannot drift apart again.
    ///
    /// ⚠️ A FAILED READ IS NOT A "NO". This threw the error away (`{ cs, _ in }`), so a read that
    /// failed produced a nil snapshot, which made `isContact` false, which — with Calls defaulting
    /// to My Friends — DECLINED the call. It could not tell "this person is not your friend" from
    /// "I could not check", and answered both the same way.
    ///
    /// The owner hit it on a real call between two accounts that WERE friends: caller heard two
    /// rings (the ringback is local, so it starts before this gate resolves) and then Declined,
    /// while the callee's phone showed nothing at all and he could honestly say he never declined.
    ///
    /// So: on an error, ask the local cache, which for any chat you have actually used will have the
    /// document. Only when BOTH fail do we have no information, and then the call RINGS. A call that
    /// rings can still be refused by the person; a call silently refused for them cannot be undone,
    /// and they never learn it happened. The blocked flag rides the same document, so the worst case
    /// is a blocked caller making the phone ring once on a device that could not reach the network —
    /// which is a far smaller harm than real calls from real friends vanishing.
    private func callAllowed(from caller: String, completion: @escaping (Bool) -> Void) {
        guard !caller.isEmpty, !me.isEmpty else { completion(true); return }
        let cid = [me, caller].sorted().joined(separator: "_")
        let ref = db.collection("conversations").document(cid)
        ref.getDocument { [weak self] cs, err in
            guard let self else { return }
            guard err == nil, cs != nil else {
                ref.getDocument(source: .cache) { [weak self] cached, _ in
                    guard let self else { return }
                    guard let cached, cached.exists else {
                        DispatchQueue.main.async { completion(true) }   // unknown → let it ring
                        return
                    }
                    DispatchQueue.main.async { completion(self.decideAllowed(cached)) }
                }
                return
            }
            DispatchQueue.main.async { completion(self.decideAllowed(cs)) }
        }
    }

    /// The gate's actual decision, split out so the live read and the cache fallback cannot drift.
    private func decideAllowed(_ cs: DocumentSnapshot?) -> Bool {
        let blocked = ((cs?.data()?["blockedBy"] as? [String: Any])?[me] as? Bool) ?? false
        let audience = PrivacyPrefs.mine("calls")   // same default as the settings screen — see PrivacyPrefs
        let isContact = (cs?.exists == true) && !((cs?.data()?["lastMessage"] as? String ?? "").isEmpty)
        return !blocked && (audience == .everyone || (audience == .contacts && isContact))
    }

    func answer() {
        guard let id = callId else { return }
        ringingWatcher?.remove(); ringingWatcher = nil   // observeCallDoc (attached below) takes over
        callDocCreated = true   // callee: the caller already created the doc, so candidates can write now
        state = .active   // present the call screen immediately; SDP fills in below
        // THE INSTANT ACCEPT SIGNAL (the standard messenger order, owner's side-by-side report): tell the caller
        // the call was picked up NOW, before permissions, TURN, or the peer connection. A plain
        // update queues and retries on its own, unlike the answer transaction below — so even when
        // the heavy chain stalls, the caller stops ringing and shows "Connecting…" instead of
        // ringing out on a call that was answered.
        db.collection("calls").document(id).updateData(["acceptedAt": FieldValue.serverTimestamp()])
        wasAccepted = true
        // Video call: warm the camera NOW, in parallel with permissions/TURN/SDP (the reference apps' order),
        // so the local video is live the moment the connection comes up.
        if cameraOn { prepareLocalVideo() }
        ensureMicPermission { [weak self] granted in
            guard let self else { return }
            guard granted else { self.hangUp(); return }
            let ref = self.db.collection("calls").document(id)
            // FAST PATH: the incoming listener already cached the offer, so answer immediately with
            // no server round-trip. That forced getDocument(source:.server) was a big slice of the
            // "Connecting…" delay — skipping it lets the media path start right away.
            if let offer = self.pendingOffer, let sdp = offer["sdp"] {
                self.completeAnswer(ref: ref, offerSdp: sdp)
            } else {
                // Push path (app was killed, no cached offer): fetch it — WITH RETRIES. A single
                // failed read used to hang up on the spot, and a phone cold-launching in the night
                // answers over a radio that is still waking up: that one attempt is the "failed"
                // his 1:40 AM call died as. Three tries over ~3 seconds, then give up honestly.
                self.fetchOfferWithRetry(ref: ref, attempt: 1)
            }
        }
    }

    // Build the answering peer connection from the caller's offer, publish the answer + my camera state.
    // The TURN wait sits HERE rather than in answer(), because this is the one place that builds the
    // peer connection and so the last point at which `config` can still pick up real relay servers.
    /// The cold-launch offer fetch, allowed to try three times. The guard on `state` matters: the
    /// caller can cancel while we retry, and a late success must not answer a call that is over.
    private func fetchOfferWithRetry(ref: DocumentReference, attempt: Int) {
        ref.getDocument(source: .server) { [weak self] snap, _ in
            guard let self else { return }
            guard self.state == .active else { return }   // cancelled / ended while retrying
            if let d = snap?.data(), let offer = d["offer"] as? [String: String], let sdp = offer["sdp"] {
                self.startedAsVideo = (d["type"] as? String == "video")
                self.cameraOn = self.startedAsVideo   // accepting a video call opens the camera
                if let cams = d["cams"] as? [String: Bool], let on = cams[self.otherUid] { self.remoteCameraOn = on }
                self.completeAnswer(ref: ref, offerSdp: sdp)
                return
            }
            guard attempt < 3 else { self.hangUp(); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.fetchOfferWithRetry(ref: ref, attempt: attempt + 1)
            }
        }
    }

    private func completeAnswer(ref: DocumentReference, offerSdp: String) {
        Task { @MainActor in
            await self.awaitIceServers()
            guard self.state == .active else { return }   // ended while we waited
            self.buildAnswer(ref: ref, offerSdp: offerSdp)
        }
    }

    private func buildAnswer(ref: DocumentReference, offerSdp: String) {
        pc = makePeerConnection()   // cameraOn is already known → the local video track is added if it's a video call
        guard let pc else { hangUp(); return }
        let remote = RTCSessionDescription(type: .offer, sdp: offerSdp)
        pc.setRemoteDescription(remote) { [weak self] _ in
            guard let self, let pc = self.pc else { return }
            self.flushPendingCandidates()   // caller's candidates were buffered until now (C1)
            let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
            pc.answer(for: constraints) { answerSdp, _ in
                // NO SILENT DEATHS past this point (the 12:27 call: he accepted, this chain died
                // quietly, and both phones sat frozen until the timeout). A failure here ends the
                // call promptly on both sides instead of stranding two people mid-answer.
                guard let answerSdp else {
                    DispatchQueue.main.async { self.endReason = .failed; self.hangUp() }
                    return
                }
                let local = self.withOpusDtxAndRed(answerSdp)
                pc.setLocalDescription(local) { _ in
                    var data: [String: Any] = ["answer": ["sdp": local.sdp, "type": "answer"], "status": "active"]
                    data["cams.\(self.me)"] = self.cameraOn   // publish my camera state (per-side)
                    // NOT ENDED — deliberately no longer "== ringing" (his 3:48 AM two-phone
                    // report: he accepted, sat on Connecting… forever, and the CALLER kept
                    // ringing). The ringing status is written by markRinging AFTER the async
                    // caller-allowed gate resolves, and a person who accepts fast — CallKit shows
                    // the call instantly, the gate reads over a half-asleep radio — answers a doc
                    // whose status is not yet "ringing". The old guard read that as "not
                    // answerable" and silently dropped the answer on the floor: this side stuck
                    // Connecting, that side ringing a call already picked up. The one state that
                    // must genuinely refuse an answer is "ended" (the caller cancelled — the case
                    // this transaction exists for, and it still holds); anything else is a live
                    // call being answered.
                    self.writeAnswerWithRetry(ref: ref, data: data, attempt: 1)
                }
            }
        }
        observeCallDoc(ref)
        observeRemoteCandidates(ref.collection("callerCandidates"))
    }

    /// The "I answered" write, no longer allowed to die silently (the 12:27 call: it never landed,
    /// the caller rang out on an answered call, and nothing anywhere noticed). Still a transaction —
    /// answering an ENDED call must stay refused (the caller-cancelled race this has always
    /// guarded). On error: three attempts over ~3s, then end the call honestly on both sides. A
    /// transaction that HANGS outright (dead socket, no completion at all) is bounded by the
    /// caller's accepted-connect timeout, which fails the call from the other side.
    private func writeAnswerWithRetry(ref: DocumentReference, data: [String: Any], attempt: Int) {
        ref.firestore.runTransaction({ txn, errPtr -> Any? in
            // ⚠️ A FAILED READ IS NOT "THE CALLER CANCELLED". The old `try?` collapsed the two, so
            // one transient read hiccup returned success-with-no-writes, the retry path (which
            // keys on `error`) never fired, and the answer was silently never written — the 2:47
            // two-phone failure, proven from the live doc: offer, acceptedAt and 26 callee
            // candidates all present (plain writes flowing), answer absent. Only a genuinely READ
            // "ended" status may stand down; a read error must surface as an error and retry.
            do {
                let snap = try txn.getDocument(ref)
                if (snap.data()?["status"] as? String) == "ended" { return "ended" }
            } catch {
                errPtr?.pointee = error as NSError
                return nil
            }
            txn.updateData(data, forDocument: ref)
            return nil
        }, completion: { [weak self] result, error in
            guard let self else { return }
            if (result as? String) == "ended" { return }   // caller cancelled — the end path owns this
            guard error != nil else { return }             // landed
            guard self.state == .active else { return }    // call already over — nothing to save
            guard attempt < 3 else {
                // LAST RESORT, evidence-driven: tonight's failures had plain writes working while
                // the transaction path did not. Read once outside a transaction, then write plain.
                // The race this reopens (caller cancels in the same instant) is milliseconds wide
                // and its cost is a stale doc; the cost of NOT trying is a dead answered call.
                ref.getDocument(source: .server) { [weak self] snap, _ in
                    guard let self, self.state == .active else { return }
                    if let d = snap?.data(), (d["status"] as? String) != "ended" {
                        ref.updateData(data) { [weak self] err in
                            guard let self, err != nil, self.state == .active else { return }
                            self.endReason = .failed; self.hangUp()
                        }
                    } else if snap != nil {
                        return   // genuinely ended — the end path owns it
                    } else {
                        self.endReason = .failed; self.hangUp()
                    }
                }
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self, self.state == .active else { return }
                self.writeAnswerWithRetry(ref: ref, data: data, attempt: attempt + 1)
            }
        })
    }

    // MARK: - Signalling observers

    private func observeCallDoc(_ ref: DocumentReference) {
        let l = ref.addSnapshotListener { [weak self] snap, _ in
            guard let self, let d = snap?.data() else { return }

            // Remote ended (hang up / decline / unreachable) — play the matching tone,
            // then tear down. Do this first and bail.
            if (d["status"] as? String) == "ended", self.state != .ended, self.state != .idle {
                let reason = EndReason(rawValue: d["endReason"] as? String ?? "") ?? .hangup
                self.remoteEnded(reason: reason)
                return
            }

            // Caller: the callee's device is now ringing → "Calling…" becomes "Ringing…". (The ringback
            // tone is already playing since startCall — the LABEL is the honest reachability signal.)
            if self.isCaller, d["ringingAt"] != nil, !self.calleeRinging, self.state == .outgoing {
                self.calleeRinging = true
                self.startRingback()   // no-op if already playing (guard); safety for CallKit restarts
            }
            // Caller: they TAPPED ACCEPT — flip to "Connecting…" and stop the ring immediately,
            // seconds before the SDP answer can arrive. The no-answer timeout is replaced by a
            // SHORT one: an accepted call whose answer never lands must fail fast (his 12:27 call
            // rang the full timeout on a call that was picked up), not sit "Ringing" for 45s.
            if self.isCaller, d["acceptedAt"] != nil, !self.calleeAccepted, self.state == .outgoing {
                self.calleeAccepted = true
                self.wasAccepted = true
                self.stopRingback()
                self.noAnswerWork?.cancel()
                self.startAcceptedConnectTimeout()
            }
            // Caller applies the answer once it arrives → connected.
            if self.isCaller, let answer = d["answer"] as? [String: String], let sdp = answer["sdp"],
               self.pc?.remoteDescription == nil {
                self.noAnswerWork?.cancel()
                self.acceptedConnectWork?.cancel()
                self.stopRingback()
                self.pc?.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: sdp)) { _ in
                    self.flushPendingCandidates()
                }
                self.state = .active   // show the call screen; reportConnected fires on real ICE connect (H1)
            }
            // Callee applies an ICE-restart OFFER (reconnection) and answers it.
            if !self.isCaller, let ro = d["restartOffer"] as? [String: Any],
               let sdp = ro["sdp"] as? String,
               let v = (ro["version"] as? NSNumber)?.intValue, v > self.appliedRemoteRestart,
               let pc = self.pc {
                self.appliedRemoteRestart = v
                pc.setRemoteDescription(RTCSessionDescription(type: .offer, sdp: sdp)) { _ in
                    self.flushPendingCandidates()
                    let c = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
                    pc.answer(for: c) { ans, _ in
                        guard let ans else { return }
                        let local = self.withOpusDtxAndRed(ans)
                        pc.setLocalDescription(local) { _ in
                            ref.updateData(["restartAnswer": ["sdp": local.sdp, "version": v]])
                        }
                    }
                }
            }
            // Caller applies the ICE-restart ANSWER.
            if self.isCaller, let ra = d["restartAnswer"] as? [String: Any],
               let sdp = ra["sdp"] as? String,
               let v = (ra["version"] as? NSNumber)?.intValue,
               v == self.negotiationVersion, v > self.appliedRemoteRestart, let pc = self.pc {
                self.appliedRemoteRestart = v
                pc.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: sdp)) { _ in self.flushPendingCandidates() }
            }
            // The other side's camera on/off (per-side, no permission).
            self.handleRemoteCallState(d)
        }
        listeners.append(l)
    }

    // Trickle-ICE buffer: libwebrtc DROPS candidates added before the remote description is set,
    // so we queue them and flush after every setRemoteDescription (C1 — fixes flaky connect / one-way audio).
    private var pendingRemoteCandidates: [RTCIceCandidate] = []

    private func addOrBuffer(_ candidate: RTCIceCandidate) {
        guard let pc, pc.remoteDescription != nil else { pendingRemoteCandidates.append(candidate); return }
        pc.add(candidate) { err in if let err { print("call: addIceCandidate failed:", err) } }
    }

    func flushPendingCandidates() {
        // Always on MAIN: called from SDP completions (WebRTC thread) while Firestore listeners (main)
        // append to pendingRemoteCandidates - the unsynchronized mix raced/lost candidates.
        guard Thread.isMainThread else { DispatchQueue.main.async { self.flushPendingCandidates() }; return }
        guard let pc, pc.remoteDescription != nil, !pendingRemoteCandidates.isEmpty else { return }
        let pending = pendingRemoteCandidates
        pendingRemoteCandidates = []
        for c in pending { pc.add(c) { err in if let err { print("call: flush addIceCandidate failed:", err) } } }
    }

    private func observeRemoteCandidates(_ col: CollectionReference) {
        let l = col.addSnapshotListener { [weak self] snap, _ in
            guard let self else { return }
            snap?.documentChanges.forEach { change in
                guard change.type == .added else { return }
                let c = change.document.data()
                guard let sdp = c["candidate"] as? String else { return }
                let candidate = RTCIceCandidate(
                    sdp: sdp,
                    sdpMLineIndex: Int32((c["sdpMLineIndex"] as? NSNumber)?.intValue ?? 0),
                    sdpMid: c["sdpMid"] as? String
                )
                self.addOrBuffer(candidate)   // buffer until remote SDP is set, then flush
            }
        }
        listeners.append(l)
    }

    private var myCandidatesCollection: CollectionReference? {
        guard let id = callId else { return nil }
        return db.collection("calls").document(id)
            .collection(isCaller ? "callerCandidates" : "calleeCandidates")
    }

    // C2: the caller's setLocalDescription fires didGenerate BEFORE the call doc is committed, so
    // those candidate writes hit a non-existent parent → rule-denied + lost. Buffer local candidates
    // until the doc exists, then flush.
    private var callDocCreated = false
    private var recheckIncomingWhenIdle = false   // glare: I stood down, re-arm the ring listener at idle
    private var localCandidateBuffer: [[String: Any]] = []
    private func flushLocalCandidates() {
        guard let col = myCandidatesCollection, !localCandidateBuffer.isEmpty else { return }
        let buffered = localCandidateBuffer
        localCandidateBuffer = []
        buffered.forEach { col.addDocument(data: $0) }
    }

    // MARK: - Hang up / cleanup

    // System-/remote-initiated end (timeout, ICE failure, remote hang up) — plays a
    // feedback tone for this user and clears the system UI.
    func hangUp() { finishCall(updateRemote: true, clearCallKit: true, localUser: false) }
    // The local user pressed End via CallKit — no tone (they know), don't re-report.
    func endFromCallKit() { finishCall(updateRemote: true, clearCallKit: false, localUser: true) }
    // The other side ended the call — carry their reason so we play the right tone.
    private func remoteEnded(reason: EndReason) {
        endReason = reason
        finishCall(updateRemote: false, clearCallKit: true, localUser: false)
    }

    private func finishCall(updateRemote: Bool, clearCallKit: Bool, localUser: Bool) {
        guard state != .ended, state != .idle else { return }   // re-entry guard: only finish once
        cancelTimers()
        stopRingback()
        if endReason == .none {
            // Connected → hang up. Not connected: the CALLER's end is a miss, and the CALLEE's end
            // is a decline ONLY when a human did it (`localUser` — the CallKit End/Decline path).
            // ⚠️ It used to say declined for EVERY callee-side end, so a teardown the person never
            // touched — mic permission refused mid-answer, a cold-launch answer that found no
            // offer, any internal failure while ringing — told the caller "Declined", and the
            // callee could honestly swear they never declined (his 1:40 AM report, exactly that
            // shape). A failure is a failure; only a finger gets to be a refusal.
            endReason = connectedDate != nil ? .hangup
                      : (isCaller ? .missed : (localUser ? .declined : .failed))
        }
        // Write a call record into the chat (once). Each side writes its own row.
        // callId != nil matters: denying the mic on an OUTGOING call hangs up before the call doc is
        // ever created, and the `callId ?? UUID()` fallback below then wrote a phantom "Missed call" row
        // under a random id - for a call that was never placed, and undedupable against the other side.
        if !recordWritten, !otherUid.isEmpty, callId != nil {
            recordWritten = true
            let connected = connectedDate != nil
            let dur = connected ? Int(Date().timeIntervalSince(connectedDate!)) : 0
            let callerUidVal = isCaller ? me : otherUid
            // ⚠️ DECLINES ARE DELIBERATELY NOT RECORDED — HIS ORDER 2026-08-12, reversing the earlier
            // "a decline is not a miss" rule with the owner's reference screenshots in hand: the big messengers removed
            // declines from the log entirely so a rejection is never exposed. The caller sees
            // "No answer", the decliner sees the same red "Missed call · Call back" as an ignored
            // ring. `EndReason.declined` still exists internally (teardown paths), it just never
            // reaches the record. Do not bring the "declined" outcome back without his word.
            //
            // `wasAccepted`: a call somebody ANSWERED can never log as missed,
            // even when the connection then failed — it renders as a plain call with no duration.
            let outcome = (connected || wasAccepted) ? "answered" : "missed"
            let cid = [me, otherUid].sorted().joined(separator: "_")
            let cidCallId = callId ?? UUID().uuidString
            // The record says what the call WAS, not how it was placed (his report: voice call,
            // camera opened mid-call, the bubble still said "Voice call"). `everVideo` is the sticky
            // either-camera-came-on latch the controls already run on, and BOTH ends latch it (the
            // `cams` signal carries the remote side), so the two merged writes agree. `startedAsVideo`
            // still counts for calls that never connected — a missed video call rang as one.
            let video = startedAsVideo || everVideo   // capture before the idle reset clears them
            liveRingRowId = nil   // the final merge owns the row now — the cleanup below must not touch it
            Task { await ChatService.recordCall(cid: cid, callId: cidCallId, callerUid: callerUidVal, outcome: outcome, video: video, durationSec: dur) }
        }
        // A teardown that was told NOT to write a record (glare loser, blocked callee, answered on
        // my other phone all force `recordWritten`) leaves the live "Ringing" row with no finaliser
        // — delete it, or the chat keeps a call that never became anything. Only ever set on the
        // device that CREATED the row, so this cannot race the other side's real record.
        if let ringId = liveRingRowId, !otherUid.isEmpty {
            liveRingRowId = nil
            let cid = [me, otherUid].sorted().joined(separator: "_")
            db.collection("conversations").document(cid)
                .collection("messages").document("call_\(ringId)").delete()
        }
        if updateRemote, let id = callId {
            db.collection("calls").document(id).updateData(["status": "ended", "endReason": endReason.rawValue])
        }
        listeners.forEach { $0.remove() }
        listeners = []
        ringingWatcher?.remove(); ringingWatcher = nil
        // The "sharing video" note must never outlive its call.
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["call-video-sharing"])
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["call-video-sharing"])
        // The route observer was installed on the first .active call and NEVER removed, so it lived for
        // the app's lifetime and kept running updateAudioRoute() — mutating isSpeaker and re-running
        // screen behaviour — with no call in progress at all.
        if let obs = routeObserver { NotificationCenter.default.removeObserver(obs); routeObserver = nil }
        if let obs = thermalObserver { NotificationCenter.default.removeObserver(obs); thermalObserver = nil }
        stopHeartbeat()
        // The camera used to keep capturing through the whole 1-2s .ended tail, because teardown only
        // happened at .idle. Nobody can see those frames; stop them the moment the call is over.
        videoCapturer?.stopCapture()
        localVideoTrack?.isEnabled = false
        stopPausedCameraRetry()
        pc?.close()
        pc = nil
        callId = nil
        otherUid = ""
        isCaller = false

        // Feedback tone for the non-initiating side / system-ended calls. Keep the audio
        // session alive until the tone finishes, THEN clear CallKit (which deactivates it).
        let reason = endReason
        if !localUser, reason != .none {
            playEndTone(reason)
            let toneDur = (reason == .busy) ? 2.0 : 0.6   // matches loops: 1 (declined plays the short ended tone now)
            DispatchQueue.main.asyncAfter(deadline: .now() + toneDur) {
                self.stopTone()
                if clearCallKit { CallKitManager.shared.reportEnded() }
            }
        } else if clearCallKit {
            CallKitManager.shared.reportEnded()
        }

        state = .ended
        // Keep the final state visible briefly (longer for the busy tone) before idle.
        let idleDelay = (!localUser && reason == .busy) ? 2.0 : 1.0
        DispatchQueue.main.asyncAfter(deadline: .now() + idleDelay) {
            if self.state == .ended { self.state = .idle }
        }
    }
}

// MARK: - RTCPeerConnectionDelegate

extension CallService: RTCPeerConnectionDelegate {
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        let data: [String: Any] = [
            "candidate": candidate.sdp,
            "sdpMLineIndex": candidate.sdpMLineIndex,
            "sdpMid": candidate.sdpMid as Any,
        ]
        // MAIN hop: this fires on WebRTC's signaling thread, but callDocCreated/localCandidateBuffer
        // are also touched from Firestore callbacks (main). Unsynchronized access raced — a candidate
        // generated at the wrong instant could be dropped (lost connectivity path) or crash.
        DispatchQueue.main.async {
            // Buffer until the call doc exists (else the write is rule-denied + lost — C2).
            if self.callDocCreated, let col = self.myCandidatesCollection { col.addDocument(data: data) }
            else { self.localCandidateBuffer.append(data) }
        }
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        DispatchQueue.main.async {
            switch newState {
            case .connected, .completed:
                // First real media connect → NOW the call is truly connected: start the timer + tell CallKit.
                if self.connectedDate == nil {
                    self.connectedDate = Date()
                    CallKitManager.shared.reportConnected()
                    // The live row goes "Ringing" → "Ongoing". Caller only — one writer, and it is
                    // the device that created the row.
                    if self.isCaller, let id = self.callId, !self.otherUid.isEmpty {
                        let cid = [self.me, self.otherUid].sorted().joined(separator: "_")
                        Task { await ChatService.markCallOngoing(cid: cid, callId: id) }
                    }
                }
                self.recovered()                          // back to a healthy media path
            case .disconnected:
                self.enterReconnecting(restartAfter: 3)   // may self-heal; force a restart in 3s
            case .failed:
                self.enterReconnecting(restartAfter: 0)   // won't self-heal; restart now
            case .closed:
                if self.state == .active || self.state == .reconnecting {
                    self.endReason = .failed; self.hangUp()
                }
            default:
                break
            }
        }
    }
    // Unused delegate methods (required by protocol).
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}

    // Unified-plan remote track arrival: grab the remote video track for rendering.
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams mediaStreams: [RTCMediaStream]) {
        if let track = rtpReceiver.track as? RTCVideoTrack {
            // Just bind the remote feed for rendering. isVideo is driven by the consent handshake (or
            // the initial call type) — NOT flipped here, so an unsolicited track can't force video on.
            DispatchQueue.main.async { self.remoteVideoTrack = track }
        }
    }
}
