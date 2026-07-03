import Foundation
import Observation
import AVFoundation
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

    // .reconnecting = the media path dropped mid-call; we're trying to recover it.
    enum State: Equatable { case idle, outgoing, incoming, active, reconnecting, ended }

    // Why a call ended — drives the end tone, the status label, and the call record.
    enum EndReason: String { case none, hangup, declined, missed, failed, busy }

    var state: State = .idle {
        didSet {
            // connectedDate is set on ACTUAL media connect (iceConnectionState .connected), NOT here —
            // state flips to .active at signaling time, which would inflate the call duration (H1).
            if state == .active {
                if isVideo { isSpeaker = true }   // video calls default to speakerphone (like FaceTime)
                try? AVAudioSession.sharedInstance().overrideOutputAudioPort(isSpeaker ? .speaker : .none)
            }
            if state == .idle {
                connectedDate = nil; isMuted = false; isSpeaker = false
                calleeRinging = false; recordWritten = false; minimized = false
                endReason = .none; negotiationVersion = 0; appliedRemoteRestart = 0; handledVideoRequest = false
                pendingRemoteCandidates = []; localCandidateBuffer = []; callDocCreated = false
                stopRingback(); stopTone(); cancelTimers()
                isVideo = false; cameraOn = true; usingFrontCamera = true
                videoCapturer?.stopCapture(); videoCapturer = nil
                localVideoTrack = nil; remoteVideoTrack = nil
            }
        }
    }
    var otherName: String = ""
    var otherPhotoUrl: String?
    var isMuted = false
    var isSpeaker = false
    var minimized = false            // call screen minimized -> show the floating pill instead
    var calleeRinging = false        // caller: the other phone is actually ringing now
    var connectedDate: Date?
    var endReason: EndReason = .none // last/in-progress end reason (UI reads it for the label)
    private var recordWritten = false
    private var ringbackPlayer: AVAudioPlayer?
    private var tonePlayer: AVAudioPlayer?       // busy / ended one-shot tones
    private var localAudioTrack: RTCAudioTrack?
    // Video (1:1 video calls) — layered on top of the existing audio peer connection.
    var isVideo = false
    var cameraOn = true
    var usingFrontCamera = true
    var localVideoTrack: RTCVideoTrack?
    var remoteVideoTrack: RTCVideoTrack?
    private var videoCapturer: RTCCameraVideoCapturer?
    private(set) var callId: String?
    private var otherUid: String = ""
    private var isCaller = false

    // Reconnection / lifecycle timers.
    private var noAnswerWork: DispatchWorkItem?      // outgoing: nobody answered -> Missed
    private var iceRestartWork: DispatchWorkItem?    // delayed ICE restart after a drop
    private var reconnectGiveUpWork: DispatchWorkItem? // hard cap: can't recover -> Failed
    private var negotiationVersion = 0               // bumps each ICE restart / media renegotiation (caller)
    private var handledVideoRequest = false          // caller handled a callee's mid-call video request once
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

    // Audio session is owned by CallKit (manual mode) — see CallKitManager.

    private func makePeerConnection() -> RTCPeerConnection? {
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let connection = Self.factory.peerConnection(with: config, constraints: constraints, delegate: self)
        // Local mic track.
        let audioSource = Self.factory.audioSource(with: nil)
        let audioTrack = Self.factory.audioTrack(with: audioSource, trackId: "audio0")
        connection?.add(audioTrack, streamIds: ["stream0"])
        localAudioTrack = audioTrack
        if isVideo { addLocalVideo(to: connection) }
        return connection
    }

    // MARK: - Video tracks / capture

    private func addLocalVideo(to connection: RTCPeerConnection?) {
        guard let connection else { return }
        let source = Self.factory.videoSource()
        let capturer = RTCCameraVideoCapturer(delegate: source)
        let track = Self.factory.videoTrack(with: source, trackId: "video0")
        track.isEnabled = cameraOn
        connection.add(track, streamIds: ["stream0"])
        videoCapturer = capturer
        localVideoTrack = track
        // Explicitly ensure camera access, THEN start capture (off the main thread). Without
        // this the capturer can silently never produce frames -> black video on both ends.
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard granted, let self else { return }
            DispatchQueue.global(qos: .userInitiated).async { self.startCapture(front: self.usingFrontCamera) }
        }
    }

    // Pick the camera + a ~720p format and start feeding frames into the local track.
    private func startCapture(front: Bool) {
        guard let capturer = videoCapturer else { return }
        let position: AVCaptureDevice.Position = front ? .front : .back
        let devices = RTCCameraVideoCapturer.captureDevices()
        guard let device = devices.first(where: { $0.position == position }) ?? devices.first else { return }
        let formats = RTCCameraVideoCapturer.supportedFormats(for: device)
        let target = 720
        let format = formats.min(by: {
            let d1 = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
            let d2 = CMVideoFormatDescriptionGetDimensions($1.formatDescription)
            return abs(Int(d1.height) - target) < abs(Int(d2.height) - target)
        })
        guard let format else { return }
        let fps = min(30, Int(format.videoSupportedFrameRateRanges.map { $0.maxFrameRate }.max() ?? 30))
        capturer.startCapture(with: device, format: format, fps: fps)
        // Observed @Observable state must be written on main (this runs on a background queue).
        DispatchQueue.main.async { self.usingFrontCamera = front }
    }

    func toggleCamera() {
        cameraOn.toggle()
        localVideoTrack?.isEnabled = cameraOn
        if cameraOn { startCapture(front: usingFrontCamera) } else { videoCapturer?.stopCapture() }
    }

    func switchCamera() {
        guard cameraOn, let capturer = videoCapturer else { return }
        let next = !usingFrontCamera
        // Stop the running capture BEFORE starting the other camera — restarting a live
        // RTCCameraVideoCapturer in place can freeze/black the local feed on flip.
        capturer.stopCapture { [weak self] in
            DispatchQueue.global(qos: .userInitiated).async { self?.startCapture(front: next) }
        }
    }

    /// Upgrade an ACTIVE voice call to video without dropping it: add my camera track and
    /// renegotiate the existing peer connection (reuses the proven restartOffer/restartAnswer
    /// channel). The peer's didAdd(rtpReceiver) fires for the new video track → their UI flips.
    /// NOTE: mid-call SDP renegotiation needs a real 2-device test; not verifiable in the simulator.
    func upgradeToVideo() {
        guard let pc, state == .active, !isVideo, localVideoTrack == nil else { return }
        isVideo = true
        cameraOn = true
        if !isSpeaker { toggleSpeaker() }
        addLocalVideo(to: pc)        // inject my video track into the live session
        renegotiateMedia()
    }

    // Re-offer the current tracks. Caller drives signaling directly; callee asks the caller to
    // (the restart channel is caller→callee), having already added its own track first.
    private func renegotiateMedia() {
        guard let pc, let id = callId else { return }
        if isCaller {
            negotiationVersion += 1
            let v = negotiationVersion
            pc.offer(for: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)) { [weak self] sdp, _ in
                guard let self, let sdp, let pc = self.pc else { return }
                pc.setLocalDescription(sdp) { _ in
                    self.db.collection("calls").document(id).updateData(["restartOffer": ["sdp": sdp.sdp, "version": v]])
                }
            }
        } else {
            db.collection("calls").document(id).updateData(["videoRequested": FieldValue.serverTimestamp()])
        }
    }

    // MARK: - In-call controls
    func toggleMute() {
        isMuted.toggle()
        localAudioTrack?.isEnabled = !isMuted
    }
    func toggleSpeaker() {
        isSpeaker.toggle()
        // Use AVAudioSession directly — CallKit owns the session in manual mode and
        // RTCAudioSession.lockForConfiguration() can deadlock when called while CallKit
        // is also configuring the session (e.g. right after answer/connect).
        try? AVAudioSession.sharedInstance().overrideOutputAudioPort(isSpeaker ? .speaker : .none)
    }

    // Ringback the CALLER hears while waiting (generated tone, looped). Ensure the
    // audio unit is on + allow mixing so the player outputs while CallKit owns the session.
    private func startRingback() {
        guard ringbackPlayer == nil else { return }
        let s = RTCAudioSession.sharedInstance()
        s.lockForConfiguration()
        try? s.setCategory(.playAndRecord, mode: .voiceChat, options: [.mixWithOthers])
        s.isAudioEnabled = true
        s.unlockForConfiguration()
        ringbackPlayer = try? AVAudioPlayer(data: RingbackTone.wavData())
        ringbackPlayer?.numberOfLoops = -1
        ringbackPlayer?.prepareToPlay()
        ringbackPlayer?.play()
    }
    private func stopRingback() { ringbackPlayer?.stop(); ringbackPlayer = nil }

    // Called by CallKit the instant it activates the audio session. Until this fires the session is
    // dead (CallKit owns it), so the ringback started at startCall was silent. Restart it fresh on
    // the live session — but only while we're still the caller waiting for an answer (outgoing).
    func audioSessionActivated() {
        guard state == .outgoing else { return }
        stopRingback()
        startRingback()
    }

    // One-shot call-progress tone (busy/declined or ended). Same audio-session nudge
    // as ringback so it outputs while CallKit owns the session.
    private func playTone(_ data: Data, loops: Int) {
        stopTone()
        let s = RTCAudioSession.sharedInstance()
        s.lockForConfiguration()
        try? s.setCategory(.playAndRecord, mode: .voiceChat, options: [.mixWithOthers])
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
        case .declined, .busy: playTone(RingbackTone.busyData(), loops: 3)   // ~4s busy signal
        case .failed, .hangup, .missed: playTone(RingbackTone.endedData(), loops: 0)
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

    private func cancelTimers() {
        noAnswerWork?.cancel(); noAnswerWork = nil
        iceRestartWork?.cancel(); iceRestartWork = nil
        reconnectGiveUpWork?.cancel(); reconnectGiveUpWork = nil
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
            pc.setLocalDescription(sdp) { _ in
                self.db.collection("calls").document(id)
                    .updateData(["restartOffer": ["sdp": sdp.sdp, "version": v]])
            }
        }
    }

    // Callee marks the call as "ringing" so the caller can switch Calling… → Ringing….
    private func markRinging() {
        guard let id = callId else { return }
        db.collection("calls").document(id).updateData(["ringingAt": FieldValue.serverTimestamp()])
    }

    // MARK: - Outgoing

    func startCall(to uid: String, name: String, photo: String? = nil, video: Bool = false) {
        guard state == .idle, !uid.isEmpty, !me.isEmpty else { return }   // never start with an empty caller id
        isVideo = video
        isCaller = true
        otherUid = uid
        otherName = name
        otherPhotoUrl = photo
        state = .outgoing
        CallKitManager.shared.startOutgoing(name: name)   // native call UI + audio session
        CallKitManager.shared.reportConnecting()

        Task { await refreshIceServers() }   // fresh TURN creds before we build the connection
        ensureMicPermission { [weak self] granted in
            guard let self else { return }
            guard granted else { self.hangUp(); return }   // no mic -> don't start a dead call
            self.startRingback()        // caller hears "ring… ring…" right away, like a real phone
            self.startNoAnswerTimeout() // give up after ~45s -> Missed
            let ref = self.db.collection("calls").document()
            self.callId = ref.documentID
            self.pc = self.makePeerConnection()
            let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
            self.pc?.offer(for: constraints) { [weak self] sdp, _ in
                guard let self, let sdp, let pc = self.pc else { return }
                pc.setLocalDescription(sdp) { _ in
                    ref.setData([
                        "caller": self.me,
                        "callee": uid,
                        "callerName": ProfileStore.shared.me?.name ?? "Caller",
                        "callerPhoto": ProfileStore.shared.me?.photoUrl ?? "",
                        "type": self.isVideo ? "video" : "voice",
                        "status": "ringing",
                        "offer": ["sdp": sdp.sdp, "type": "offer"],
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
            if (d["status"] as? String) == "ended", self.state == .incoming {
                self.ringingWatcher?.remove(); self.ringingWatcher = nil
                self.remoteEnded(reason: EndReason(rawValue: d["endReason"] as? String ?? "") ?? .hangup)
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
                // H4: already in a call → send this new caller a busy signal instead of dropping them silently.
                if self.state != .idle {
                    if doc.documentID != self.callId {
                        self.db.collection("calls").document(doc.documentID)
                            .updateData(["status": "ended", "endReason": EndReason.busy.rawValue])
                    }
                    return
                }
                let caller = d["caller"] as? String ?? ""
                // Silent block: a call from someone I've blocked never rings me.
                let cid = [self.me, caller].sorted().joined(separator: "_")
                self.db.collection("conversations").document(cid).getDocument { cs, _ in
                    let blocked = ((cs?.data()?["blockedBy"] as? [String: Any])?[self.me] as? Bool) ?? false
                    guard !blocked, self.state == .idle else { return }
                    self.callId = doc.documentID
                    self.otherUid = caller
                    self.otherName = d["callerName"] as? String ?? "Caller"
                    let photo = d["callerPhoto"] as? String ?? ""
                    self.otherPhotoUrl = photo.isEmpty ? nil : photo
                    self.isCaller = false
                    self.isVideo = (d["type"] as? String == "video")
                    self.state = .incoming
                    CallKitManager.shared.reportIncoming(callId: doc.documentID, name: self.otherName, video: self.isVideo)
                    self.markRinging()
                    self.watchRingingCancel(doc.documentID)   // tear down if the caller cancels before I answer
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
        self.isVideo = video
        self.callId = callId
        self.otherName = name
        self.otherUid = uid
        self.otherPhotoUrl = (photo?.isEmpty == false) ? photo : nil
        self.isCaller = false
        self.state = .incoming   // so the UI can present once answered
        Task { await refreshIceServers() }   // ensure fresh TURN before the callee builds its connection
        markRinging()
        watchRingingCancel(callId)   // tear down if the caller cancels before I answer
    }

    func answer() {
        guard let id = callId else { return }
        ringingWatcher?.remove(); ringingWatcher = nil   // observeCallDoc (attached below) takes over
        callDocCreated = true   // callee: the caller already created the doc, so candidates can write now
        state = .active   // present the call screen immediately; SDP fills in below
        ensureMicPermission { [weak self] granted in
            guard let self else { return }
            guard granted else { self.hangUp(); return }
            let ref = self.db.collection("calls").document(id)
            ref.getDocument(source: .server) { [weak self] snap, _ in
                guard let self else { return }
                guard let d = snap?.data(),
                      let offer = d["offer"] as? [String: String], let sdp = offer["sdp"] else { self.hangUp(); return }
                // CRITICAL: learn whether this is a video call from the offer BEFORE building the
                // peer connection, so the local video track is actually added on the answering side.
                self.isVideo = (d["type"] as? String == "video")
                self.pc = self.makePeerConnection()
                guard let pc = self.pc else { self.hangUp(); return }
                let remote = RTCSessionDescription(type: .offer, sdp: sdp)
                pc.setRemoteDescription(remote) { _ in
                    self.flushPendingCandidates()   // caller's candidates were buffered until now (C1)
                    let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
                    pc.answer(for: constraints) { answerSdp, _ in
                        guard let answerSdp else { return }
                        pc.setLocalDescription(answerSdp) { _ in
                            ref.updateData([
                                "answer": ["sdp": answerSdp.sdp, "type": "answer"],
                                "status": "active",
                            ])
                        }
                    }
                }
                self.observeCallDoc(ref)
                self.observeRemoteCandidates(ref.collection("callerCandidates"))
            }
        }
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

            // Caller: the callee's device is now ringing → "Calling…" becomes "Ringing…".
            if self.isCaller, d["ringingAt"] != nil, !self.calleeRinging, self.state == .outgoing {
                self.calleeRinging = true
            }
            // Caller applies the answer once it arrives → connected.
            if self.isCaller, let answer = d["answer"] as? [String: String], let sdp = answer["sdp"],
               self.pc?.remoteDescription == nil {
                self.noAnswerWork?.cancel()
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
                        pc.setLocalDescription(ans) { _ in
                            ref.updateData(["restartAnswer": ["sdp": ans.sdp, "version": v]])
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
            // Caller: the callee tapped video mid-call → add a recv-only video transceiver so their
            // track has an m-line to land on, flip our UI to video, and drive the re-offer.
            if self.isCaller, d["videoRequested"] != nil, !self.handledVideoRequest, let pc = self.pc {
                self.handledVideoRequest = true
                self.isVideo = true
                let initt = RTCRtpTransceiverInit(); initt.direction = .recvOnly
                pc.addTransceiver(of: .video, init: initt)
                self.renegotiateMedia()
            }
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
        if endReason == .none {   // infer it: connected→hang up, else caller=missed / callee=declined
            endReason = connectedDate != nil ? .hangup : (isCaller ? .missed : .declined)
        }
        // Write a call record into the chat (once). Each side writes its own row.
        if !recordWritten, !otherUid.isEmpty {
            recordWritten = true
            let connected = connectedDate != nil
            let dur = connected ? Int(Date().timeIntervalSince(connectedDate!)) : 0
            let callerUidVal = isCaller ? me : otherUid
            let outcome = connected ? "answered" : "missed"
            let cid = [me, otherUid].sorted().joined(separator: "_")
            let cidCallId = callId ?? UUID().uuidString
            Task { await ChatService.recordCall(cid: cid, callId: cidCallId, callerUid: callerUidVal, outcome: outcome, durationSec: dur) }
        }
        if updateRemote, let id = callId {
            db.collection("calls").document(id).updateData(["status": "ended", "endReason": endReason.rawValue])
        }
        listeners.forEach { $0.remove() }
        listeners = []
        ringingWatcher?.remove(); ringingWatcher = nil
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
            let toneDur = (reason == .declined || reason == .busy) ? 1.8 : 0.6
            DispatchQueue.main.asyncAfter(deadline: .now() + toneDur) {
                self.stopTone()
                if clearCallKit { CallKitManager.shared.reportEnded() }
            }
        } else if clearCallKit {
            CallKitManager.shared.reportEnded()
        }

        state = .ended
        // Keep the final state visible briefly (longer for the busy tone) before idle.
        let idleDelay = (!localUser && (reason == .declined || reason == .busy)) ? 2.0 : 1.0
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
        // Buffer until the call doc exists (else the write is rule-denied + lost — C2).
        if callDocCreated, let col = myCandidatesCollection { col.addDocument(data: data) }
        else { localCandidateBuffer.append(data) }
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        DispatchQueue.main.async {
            switch newState {
            case .connected, .completed:
                // First real media connect → NOW the call is truly connected: start the timer + tell CallKit.
                if self.connectedDate == nil {
                    self.connectedDate = Date()
                    CallKitManager.shared.reportConnected()
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
            // Mid-call upgrade: a video track arriving on a voice call flips this side to video.
            DispatchQueue.main.async { self.remoteVideoTrack = track; self.isVideo = true }
        }
    }
}
