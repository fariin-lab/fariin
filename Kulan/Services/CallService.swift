import Foundation
import Observation
import AVFoundation
import UIKit   // app-lifecycle notification (foreground backstop for the background camera)
import UserNotifications   // "sharing video" note when their camera comes on while we're backgrounded
import CoreMedia
import Network   // NWPathMonitor: notice a Wi-Fi <-> cellular switch before ICE does
import Combine   // audit M-106: the late "broadcast started" guard after an abandoned share
import WebRTC
import FirebaseAuth
import FirebaseFirestore
import FirebaseFunctions
import CryptoKit   // 1:1 audit r2 A1: the accept stamp's VoIP token hash

// Voice calling over WebRTC, signalled through Firestore `calls/{id}` (offer/answer
// + caller/callee ICE candidate subcollections) — the same design the RN web client
// used. Media is peer-to-peer (STUN/TURN); the server only relays signalling.
//
/// The running call clock. It exists because the old `%02d:%02d` never carried into hours, so an
/// hour-and-a-bit call read "100:45" — a number that looks like a mistake and cannot be read as a
/// time at all (owner's screenshot, 2026-08-23). Under an hour it stays MM:SS, the way every call
/// screen shows it; past that it becomes H:MM:SS.
enum CallDuration {
    static func clock(_ seconds: Int) -> String {
        let s = max(0, seconds)
        if s < 3600 { return String(format: "%02d:%02d", s / 60, s % 60) }
        return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }
}

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
                                               object: nil, queue: .main) { [weak self] _ in
            CallPiPController.shared.stopSystemPiP()
            self?.startVoiceMonitor()   // 1:1 audit r2 J3, 2026-10-08: back on screen with the card up
        }
        // 1:1 audit r2 J3, 2026-10-08: nobody sees the talking badge in the background or with the
        // screen locked, so the 0.3 s stats poll stops there (the reference app polls no levels at all
        // in a 1:1 call).
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.pauseVoiceMonitor()
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
            // 1:1 audit check, 2026-10-08: a new call never inherits the teardown flag.
            if state == .outgoing || state == .incoming { tearingDown = false }
            // 1:1 audit r2 C4/D5, 2026-10-08: the ring screen reads the live route, not the last call's.
            if (state == .outgoing || state == .incoming) && oldValue != state { refreshRouteForRing() }
            // connectedDate is set on ACTUAL media connect (iceConnectionState .connected), NOT here —
            // state flips to .active at signaling time, which would inflate the call duration (H1).
            // Audit M-049, 2026-10-07: not with AirPods, a headset or a car connected. The override
            // pulled a video call's audio out of the AirPods onto the loudspeaker.
            if state == .outgoing, cameraOn, !externalOutputAround {
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
                // ONCE PER CALL (owner audit 2026-10-06 #6). `.active` is re-entered on every recovery
                // from .reconnecting, and applying the default each time put a video call the person
                // had moved to the earpiece back on the loudspeaker after any network blip. The
                // default is the call's starting point, not a rule that outranks their choice.
                // Audit M-010 / M-049, 2026-10-07: never over the person's own pick (a speaker tap
                // during "Calling..." used to be overruled here), and never with a device connected.
                if !videoSpeakerDefaultApplied, cameraOn || startedAsVideo,
                   !speakerChosenByUser, !externalOutputAround {
                    videoSpeakerDefaultApplied = true
                    isSpeaker = true; wantsSpeaker = true
                }
                try? AVAudioSession.sharedInstance().overrideOutputAudioPort(isSpeaker ? .speaker : .none)
                // Back from .reconnecting: re-send "can they hear me". A mute write made while the
                // link was down can be lost, and the other side's muted icon would stay wrong until
                // the next toggle (owner audit 2026-10-06 #36). One write per recovery.
                // Audit M-051, 2026-10-07: and on the FIRST entry from the ring when already muted or
                // held. A mute tapped during "Calling..." could be written before the doc existed, or
                // lost, and nothing sent it again, so the other side never saw it for the whole call.
                if oldValue == .reconnecting
                    || (oldValue != .active && (isMuted || isHeld)) { broadcastMuteState() }
                if oldValue == .reconnecting, screenSharing {
                    broadcastScreenState()   // same reason
                    // The ICE restart keeps the sender, but its parameters are put back anyway: one
                    // cheap write, and the share comes out of the drop at the tier it went in with.
                    applyScreenShareEncoding(true)
                }
                // Audit M-121, 2026-10-07: the camera signal too (a share's write above carries it).
                if oldValue == .reconnecting, !screenSharing { broadcastCameraState() }
                startRouteObservation()   // smart speaker button: track where audio actually goes
                observeLifecycleIfNeeded()   // capture-session interruption -> camera pause/resume
                startHeartbeat()             // prove we're alive; detect a force-quit on the other side
                startLinkMonitor()           // weak link -> drop to audio rather than starve it
                startPathMonitor()           // Wi-Fi <-> cellular -> ICE restart before the path dies
                // Answered while you were already out of the call screen: the card is up, so the
                // talking monitor has to start HERE too, not only when you minimize.
                startVoiceMonitor()
                updateInCallScreenBehavior() // proximity (voice) / keep-awake (video)
                reconnectIfDroppedDuringRing() // owner audit 2026-10-06 #15: path died while it rang
            }
            if state == .reconnecting, oldValue != .reconnecting, lastPeerBeatAt != nil {
                // The liveness check counts their silence from HERE, not from their last beat before
                // the drop (owner audit 2026-10-06 #13). A drop on both phones stops both beats at
                // once, so the old origin was already ~5s stale, and a listener that had stalled
                // earlier made it older still: a 1-2s blip then ended a healthy call on the next tick.
                lastPeerBeatAt = Date()
            }
            if state == .idle {
                connectedDate = nil; isMuted = false; isSpeaker = false
                wantsSpeaker = false        // stale intent made the NEXT voice call blast on loudspeaker
                videoSpeakerDefaultApplied = false   // the next call gets its own default (#6)
                speakerChosenByUser = false          // audit M-010: so does its own choice
                cameraPausedByBackground = false; stopPausedCameraRetry()
                stopLinkMonitor()
                stopPathMonitor()
                restartRequestsSent = 0; restartRequestsSeen = 0
                restartInFlightAt = nil; pcIceServersFetchedAt = nil   // audit M-117, M-009
                transportFailed = false                                // audit M-042
                stopVoiceMonitor()
                calleeRinging = false; calleeAccepted = false; wasAccepted = false; recordWritten = false; minimized = false; liveRingRowId = nil
                callAudioLive = false
                activatedSinceInterruption = false   // 1:1 audit r2 D2/J2, 2026-10-08
                // 1:1 audit r2 C4/D5, 2026-10-08: the next ring screen must not draw this call's route.
                audioRoute = .earpiece; externalAudioAvailable = false
                everMinimized = false
                endReason = .none; negotiationVersion = 0; appliedRemoteRestart = 0
                micDenied = false
                cameraDenied = false   // audit M-011
                // ⚠️ RESET WITH EVERYTHING ELSE. A timeline left standing would measure the second
                // call of a session from the first call's origin, which is worse than no measurement
                // at all: the numbers still look like numbers.
                timeline = [:]; timelineOrigin = nil; timelineWritten = false
                // ⛔ THESE TWO MUST RESET OR THE NEXT CALL IS BROKEN IN BOTH DIRECTIONS: a stale
                // `preNegotiated` sends `answer()` down the fast path with no peer connection built,
                // and a stale `mediaReady` would start a call the instant it is accepted, before any
                // media exists. Both silent, both only visible on the SECOND call of a session.
                preNegotiated = false; mediaReady = false
                heldPreAnswer = nil   // 2026-09-24 fix-all #230: belongs to that call's connection
                // Belongs to the peer connection that just died. Held across calls it would be a
                // closed channel the next call quietly tries to send its accept down — the accept
                // would silently never arrive and the blink would come back, on some calls only,
                // which is the worst kind of bug to chase.
                acceptChannel?.close(); acceptChannel = nil
                pendingOffer = nil
                sealSignalling = false   // #27: each call decides its own sealing
                pendingRemoteCandidates = []; localCandidateBuffer = []; callDocCreated = false
                stopRingback(); stopTone(); cancelTimers()
                // 1:1 audit check, 2026-10-08: per-call reconnect clocks and the stall flag.
                iceCheckingSince = nil; reconnectStartedAt = nil
                lastIceConnectedAt = nil; relayRefreshTriedAt = nil
                stopRemoteFreezeWatch()
                tearingDown = false
                // Backstop for an end that skipped finishCall: no share, and no socket listener, may
                // outlive the call. Idempotent.
                stopScreenShare(requestExtensionStop: true, signal: false)
                remoteScreenSharing = false
                screenShareNotice = nil   // belongs to the call that just ended
                // Screen share v3: dual-mode state belongs to the connection that just died.
                ScreenShareAudioMixer.shared.isMixing = false
                shareUsesTrack = false; screenSource = nil; screenTrack = nil
                remoteScreenTrack = nil; remoteScreenMode = "camera"; peerHasScreen2 = false
                screenUpgradeOfferAt = nil; screenUpgradeAttempts = 0
                screenUpgradeInFlightVersion = nil; cameraPausedForShareTier = false
                videoSource = nil
                cameraOn = false; remoteCameraOn = false; remoteMuted = false; isHeld = false
                cameraStarting = false   // 1:1 audit r2 E1, 2026-10-08
                usingFrontCamera = true; startedAsVideo = false; everVideo = false; pendingSwitchTarget = nil
                isLocalExpanded = false; pipCornerLeft = false; pipCornerTop = false
                cardOffset = .zero; cardBase = .zero; cardStashed = false; cardFrame = .zero
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
    /// Call screen minimized → the floating card instead. The talking monitor rides on this: the card
    /// is the only thing that reads who is speaking, so it runs exactly while the card is on screen.
    var minimized = false {
        didSet {
            guard minimized != oldValue else { return }
            if minimized { everMinimized = true }
            minimized ? startVoiceMonitor() : stopVoiceMonitor()
        }
    }
    /// Has this call been shrunk into the card at least once? It decides WHICH THING the call screen
    /// zooms out of and back into. Before the first minimize the answer is the button that placed the
    /// call; after it, the card — and the card is the honest answer, because by then the button is
    /// usually on a screen you navigated away from. Sticky for the whole call, so restoring and
    /// minimizing again keeps flying between the same two shapes.
    private(set) var everMinimized = false
    var calleeRinging = false        // caller: the other phone is actually ringing now
    /// Caller: the other person TAPPED ACCEPT (the instant `acceptedAt` signal — his two-phone
    /// report: the caller sat on "Ringing…" for the whole answer setup, and on the 12:27 call the
    /// answer write died silently and the caller rang out on a call that was picked up). The label
    /// flips to "Connecting…" and the ringback stops on this, not on the SDP answer.
    var calleeAccepted = false
    var connectedDate: Date?
    var endReason: EndReason = .none // last/in-progress end reason (UI reads it for the label)
    /// The call ended because microphone access is off. Audit 2026-09-24: a denied mic hung up with
    /// no reason at all, so the caller's screen read "Couldn't reach them" and the callee's "Call
    /// failed", and neither said the one thing that would fix it. The call screen reads this.
    var micDenied = false
    private var recordWritten = false

    // MARK: - Where the seconds actually go
    //
    // WHY THIS EXISTS. "Connecting… takes a bit" is a real report and nothing in this app could say
    // WHICH part is slow. The candidates are all plausible and they are not the same fix: the offer
    // round trip, the relay credentials, building the connection, the candidate exchange crossing
    // Firestore in Doha, the connectivity checks crossing an ocean, or the encrypt handshake. Tuning
    // by guess on a file this heavily iterated is how a call system gets worse while being improved.
    //
    // So: a handful of milestones per call, in milliseconds from the first one, written ONCE.
    //
    // WRITTEN TO ITS OWN COLLECTION, never onto the call document. Both phones hold a live listener
    // on the call doc; an extra field there would push a snapshot to both mid-call for nothing —
    // the same reason the announcement push markers live apart from the announcements.
    //
    // Costs one small write per call, on connect only. Nothing reads it in the app; it is there to
    // be queried from a desk after a real call between two real countries.
    private var timeline: [String: Int] = [:]
    private var timelineOrigin: Date?
    private var timelineWritten = false

    private func mark(_ label: String) {
        let now = Date()
        if timelineOrigin == nil { timelineOrigin = now }
        guard let origin = timelineOrigin, timeline[label] == nil else { return }
        timeline[label] = Int(now.timeIntervalSince(origin) * 1000)
    }

    // MARK: - Pre-negotiation: the connection is built while the phone rings
    //
    // ⭐ WHAT SIGNAL DOES, IN THEIR OWN WORDS: rather than waiting for the recipient to answer, the
    // ICE negotiation happens BEFORE the call is accepted, so that when somebody picks up, the
    // encrypted connection is already prepared. Measured here on 2026-08-22, the wait between
    // tapping answer and hearing sound was 3.4 to 6.7 seconds, and almost all of it was work that
    // could have been done during the twenty seconds the phone spent ringing.
    //
    // ⛔ THE ONE RULE THAT MAKES THIS SAFE: the microphone stays off until the person accepts. The
    // path exists and carries silence. Two independent locks, either of which is sufficient:
    //   1. the local audio track is created DISABLED and only enabled in `accept()`
    //   2. CallKit owns the audio session (`useManualAudio`), and WebRTC's audio unit stays off
    //      until `didActivate` fires, which only happens on a real answer
    // If either is ever removed, this feature becomes a bug that records people before they answer.

    // MARK: - Telling the caller "I answered" down the fast road
    //
    // ⭐ THE LAST VISIBLE DELAY, AND IT IS NOT THE NETWORK. The caller cannot start its timer until
    // it is TOLD the callee accepted, and that message travels Uganda → Firestore in Doha → USA.
    // Measured by the owner on a good connection on both ends: 0.67 seconds of "Connecting…" on
    // every single call, while the two phones were already connected and his voice was arriving.
    // The sound takes the direct road; the news takes the slow one.
    //
    // So the accept also goes over the peer connection itself, which is already up by then.
    //
    // ⛔ THIS IS AN ACCELERATOR AND NOTHING DEPENDS ON IT. The Firestore `acceptedAt` write and the
    // listener that reads it are untouched and still authoritative — this just usually gets there
    // first. If the channel never opens, never negotiates, or the message is lost, the caller falls
    // back to exactly today's behaviour: 0.67s instead of instant. Never make correctness rest on
    // it. It is also backward compatible: a phone on an older build simply never opens the channel
    // and the call proceeds as before.
    private var acceptChannel: RTCDataChannel?
    private static let acceptChannelLabel = "accept"
    private static let acceptMessage = "accepted"

    /// The media path is up. Says nothing about whether a human has accepted.
    private var mediaReady = false
    /// This side built its peer connection during the ring rather than at the tap.
    private var preNegotiated = false
    /// 2026-09-24 fix-all #230: the answer made during the ring, written only when THIS device accepts.
    private var heldPreAnswer: [String: Any]?

    /// Has this call actually been accepted by a person? The callee's own tap, or — on the caller —
    /// the callee's `acceptedAt` landing. Media being ready is not acceptance.
    private var callAccepted: Bool { isCaller ? calleeAccepted : wasAccepted }

    /// Callee: say "I answered" straight down the connection. Best effort by design — a failure here
    /// costs the caller nothing except the 0.67s it already pays through Firestore.
    private func sendAcceptOverChannel() {
        guard !isCaller, let ch = acceptChannel, ch.readyState == .open else { return }
        let data = Data(Self.acceptMessage.utf8)
        ch.sendData(RTCDataBuffer(data: data, isBinary: false))
    }

    /// Caller: the accept arrived over the connection instead of through Doha. Everything below is
    /// the same work the Firestore listener does — deliberately, so the two paths cannot drift — and
    /// `calleeAccepted` is the latch that makes whichever arrives second a no-op.
    private func acceptArrivedOverChannel() {
        guard isCaller, !calleeAccepted, state != .ended else { return }
        mark("acceptSeenFast")
        calleeAccepted = true
        wasAccepted = true
        stopRingback()
        noAnswerWork?.cancel()
        startAcceptedConnectTimeout()
        beginConnectedCallIfAccepted()
    }

    /// Promote a warm media path into a running call. Called from both directions: the path may come
    /// up before the accept (the normal case now) or after it (a slow network), and whichever
    /// arrives second is the one that starts the call.
    private func beginConnectedCallIfAccepted() {
        guard mediaReady, callAccepted, connectedDate == nil else { return }
        connectedDate = Date()
        acceptedMediaWork?.cancel(); acceptedMediaWork = nil   // audit M-008: media came up in time
        mark("mediaUp")          // still the moment the user stops waiting, which is what we measure
        writeTimeline()
        CallKitManager.shared.reportConnected()
        // Screen share v3: open the screen m-line now if the callee is v3 (caps already read). A
        // beat later so the answer's own work settles first; call-doc snapshots retry it anyway.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.upgradeScreenTransceiverIfDue() }
        // The live row goes "Ringing" → "Ongoing". Caller only — one writer, and it is the device
        // that created the row.
        if isCaller, let id = callId, !otherUid.isEmpty {
            let cid = [me, otherUid].sorted().joined(separator: "_")
            Task { await ChatService.markCallOngoing(cid: cid, callId: id) }
        }
    }

    /// Flushed when the media path comes up, and again — for the first time — when a call ENDS
    /// without ever getting there.
    ///
    /// ⛔ IT ONLY SAVED ON SUCCESS, WHICH IS BACKWARDS. A call that connects is the one you least
    /// need to measure. A call that rings out, or fails, or is never answered is the one worth
    /// reading, and it was throwing its numbers away — so dialling somebody who is asleep, which is
    /// the easiest test there is to run alone, recorded nothing at all.
    ///
    /// `outcome` says which kind this was, so the two are never confused when read back.
    private func writeTimeline(outcome: String = "connected") {
        guard !timelineWritten, let id = callId, !timeline.isEmpty else { return }
        timelineWritten = true
        var payload: [String: Any] = timeline
        payload["role"] = isCaller ? "caller" : "callee"
        payload["outcome"] = outcome
        payload["at"] = FieldValue.serverTimestamp()
        // Merged, and keyed by role, so the two sides land in one document without racing each
        // other. Failures are ignored: a measurement must never be able to disturb a live call.
        db.collection("callTiming").document(id)
            .setData([isCaller ? "caller" : "callee": payload], merge: true)
    }
    /// EITHER side accepted this call (callee: the tap; caller: the acceptedAt signal). The standard messengers'
    /// record rule, adopted on his order: an accepted call that then FAILS logs as a plain call,
    /// never as "missed" — the person answered, and a red "Missed call · Call back" in the
    /// answerer's own chat reads as a lie.
    /// Readable outside (audit M-012, 2026-10-07): the call screen shows the `.ended` tail only to
    /// someone who was in the call (the caller, or a callee who accepted), not to a callee whose
    /// phone merely rang. Still written only here.
    private(set) var wasAccepted = false
    /// Set when THIS device (the caller) wrote the live "Ringing" row. Cleared when recordCall
    /// finalises it; if a teardown path suppresses the record (glare loser, blocked, answered
    /// elsewhere), finishCall deletes the row instead, so no chat keeps a call that never became
    /// anything. See ChatService.recordCallRinging.
    private var liveRingRowId: String?
    private var ringbackPlayer: AVAudioPlayer?
    /// CallKit has activated this call's audio session (`audioSessionActivated`). The ringback is
    /// only ever started into a live session; a "ringing" signal that lands before this waits for it.
    private var callAudioLive = false
    private var tonePlayer: AVAudioPlayer?       // busy / ended one-shot tones
    private var localAudioTrack: RTCAudioTrack?
    // Video (1:1). Each side controls its OWN camera independently: no
    // permission — turning your camera on just sends your video and the other side sees it. The
    // video layout shows whenever EITHER camera is on.
    var cameraOn = false            // is MY camera sending
    var remoteCameraOn = false {    // is THEIR camera sending (from the `cams` signal)
        didSet {
            // 1:1 audit r2 J4, 2026-10-08: the frozen-video watch runs only while their camera is
            // said on, not as a 1 Hz timer on every call (voice calls included).
            guard remoteCameraOn != oldValue else { return }
            if remoteCameraOn { startRemoteFreezeWatchIfNeeded() } else { stopRemoteFreezeWatch() }
        }
    }
    var remoteMuted = false         // is THEIR mic muted (from the `muted` signal)
    /// MY SCREEN is going out in place of my camera (1:1 screen share). Deliberately separate from
    /// `cameraOn`: that stays the camera INTENT through the share, so stopping restores exactly the
    /// camera the user had, and every camera-only rule (speaker default, CallKit hasVideo, capture
    /// interruptions) keeps reading the camera and nothing else.
    private(set) var screenSharing = false
    /// Where MY share is, for the call screen. `screenSharing` is true for `.starting` and `.live`
    /// (unchanged meaning: the share has begun and owns the video source).
    ///   picking  - the system picker was asked for; nothing in the call has changed yet.
    ///   starting - the extension is connected; its first frame has not been decoded yet.
    ///   live     - frames are flowing to the other side.
    /// Every path goes through `setScreenSharePhase`, which never leaves it on after the call.
    enum ScreenSharePhase: Equatable { case off, picking, starting, live }
    private(set) var screenSharePhase: ScreenSharePhase = .off
    /// One short line for the call screen when MY share ended without me pressing Stop, or never got
    /// going. Nil after the user's own Stop. The view shows it and calls `clearScreenShareNotice()`.
    var screenShareNotice: String?
    /// How well my share is getting through, from the quality ladder (ScreenShareQuality):
    /// T0-T1 good, T2 constrained, T3 poor. `.good` whenever not sharing.
    enum ScreenShareLink: Equatable { case good, constrained, poor }
    private(set) var screenShareLink: ScreenShareLink = .good
    /// THEIR screen is what their video carries (from the `screen` signal). The big view switches to
    /// aspect FIT and never crops it; their `cams` is also true meanwhile, so the video layout shows.
    private(set) var remoteScreenSharing = false {
        didSet {
            guard remoteScreenSharing != oldValue else { return }
            remoteScreenSharingSince = remoteScreenSharing ? Date() : nil
        }
    }
    /// When their share started (nil while they are not sharing), so the "is sharing" label can fade.
    private(set) var remoteScreenSharingSince: Date?
    // remoteScreenSharing: in dual mode their `cams` is their real camera, which may be off while
    // they share. In fallback their `cams` is true for the share anyway, so nothing changes there.
    var isVideo: Bool { cameraOn || remoteCameraOn || screenSharing || remoteScreenSharing }   // show the video layout
    /// A VIDEO CALL, as opposed to a call with a camera on right now: placed as video, or a camera
    /// has been on at some point. The minimized card keys on this (owner, 2026-10-05: a video call
    /// minimized while ringing, camera not up yet, showed the voice card). The video card already
    /// draws the photo for any camera that is off.
    var isVideoCall: Bool { isVideo || startedAsVideo || everVideo }

    /// The chat this call belongs to while it is RUNNING — nil the rest of the time. The chat list
    /// reads it to float that one row to the top and label it "Active call", the way the reference
    /// app keeps a call you are on visible in the list instead of only in a bar over it.
    /// Ringing (.outgoing/.incoming) is deliberately NOT included: the call screen is already up in
    /// front of you then, and a row that appeared for two seconds and vanished on a missed call
    /// would just make the list jump.
    var liveConversationId: String? {
        guard state == .active || state == .reconnecting, !otherUid.isEmpty else { return nil }
        let mine = me
        guard !mine.isEmpty else { return nil }
        return ChatService.convId(mine, otherUid)
    }
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
    var bigScreenTrack: RTCVideoTrack? {
        if isLocalExpanded { return localVideoTrack }
        return remoteScreenSharing ? remoteShareTrack : remoteVideoTrack   // dual mode: their screen
    }

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

    /// 1:1 audit #11 (owner, 2026-10-08): my video is ACTUALLY going out, the same truth `cams` sends.
    /// `cameraOn` is the intent and stays true through a capture interruption, a weak-link pause or a
    /// hold, when the stopped capturer leaves my last frame frozen in every renderer.
    var localVideoLive: Bool { camsSignal }

    /// 1:1 audit #13 (owner, 2026-10-08): their camera is said to be on AND frames are arriving.
    /// A lost `cams=false` or a stalled stream otherwise left their last frame up as live video.
    var remoteVideoLive: Bool { remoteCameraOn && !remoteVideoStalled }
    /// No decoded frame from their camera for `remoteStallAfter` while `cams` says on. Main only.
    private(set) var remoteVideoStalled = false
    private var remoteFreezeWatch: Timer?
    private var remoteFramesDecoded: Double?
    private var remoteFramesMovedAt: Date?
    private static let remoteStallAfter: TimeInterval = 4

    /// Started with the call's video plumbing (prepareLocalVideo); stops itself at idle.
    private func startRemoteFreezeWatchIfNeeded() {
        guard remoteFreezeWatch == nil else { return }
        remoteFreezeWatch = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.sampleRemoteFrames()
        }
    }

    private func stopRemoteFreezeWatch() {
        remoteFreezeWatch?.invalidate(); remoteFreezeWatch = nil
        resetRemoteFrameWatch()
    }

    /// 1:1 audit r2 E8, 2026-10-08: frames have moved since the last reset. Until they do, a resumed
    /// stream gets `remoteFirstFrameAllowance` for its first keyframe on a weak link.
    private var remoteFramesMovedSinceReset = false
    private static let remoteFirstFrameAllowance: TimeInterval = 8

    private func resetRemoteFrameWatch() {
        remoteFramesDecoded = nil
        remoteFramesMovedAt = nil
        remoteFramesMovedSinceReset = false
        if remoteVideoStalled { remoteVideoStalled = false }
    }

    private func sampleRemoteFrames() {
        guard state != .idle else { stopRemoteFreezeWatch(); return }
        guard let pc else { return }
        // Only a connected call with their camera said on. A share (a still screen sends no frames)
        // and "Reconnecting" (which has its own screen) are left alone.
        guard state == .active, remoteCameraOn, !remoteScreenSharing,
              let trackId = remoteVideoTrack?.trackId else { resetRemoteFrameWatch(); return }
        pc.statistics { [weak self] report in
            let video = report.statistics.values.filter {
                $0.type == "inbound-rtp" && (($0.values["kind"] as? String) ?? ($0.values["mediaType"] as? String)) == "video"
            }
            // Their camera's stream by track id; with no match, the only video stream if there is one.
            let stat = video.first { ($0.values["trackIdentifier"] as? String) == trackId }
                ?? (video.count == 1 ? video.first : nil)
            let frames = (stat?.values["framesDecoded"] as? NSNumber)?.doubleValue
            DispatchQueue.main.async { self?.applyRemoteFrames(frames, from: pc) }
        }
    }

    private func applyRemoteFrames(_ frames: Double?, from connection: RTCPeerConnection) {
        guard connection === pc, state == .active, remoteCameraOn, !remoteScreenSharing else { return }
        guard let frames else { return }   // no stats for it: no verdict
        let now = Date()
        // Equal = not moving. A smaller count is a new stream (renegotiation): a fresh baseline.
        if let last = remoteFramesDecoded, frames == last {
            let since = remoteFramesMovedAt ?? now
            if remoteFramesMovedAt == nil { remoteFramesMovedAt = now }
            // r2 E8: a longer wait for the first frame after a reset (camera on, reconnect).
            let limit = remoteFramesMovedSinceReset ? Self.remoteStallAfter : Self.remoteFirstFrameAllowance
            if !remoteVideoStalled, now.timeIntervalSince(since) >= limit {
                remoteVideoStalled = true
                print("[Call] their video stalled (no frames for \(Int(Self.remoteStallAfter))s), showing their photo")
            }
        } else {
            if remoteVideoStalled { print("[Call] their video is moving again") }
            if remoteFramesDecoded != nil { remoteFramesMovedSinceReset = true }   // r2 E8
            remoteFramesDecoded = frames
            remoteFramesMovedAt = now
            if remoteVideoStalled { remoteVideoStalled = false }
        }
    }

    var pipFeeds: PiPFeeds {
        var f = PiPFeeds()
        // My track carries my SCREEN while sharing: it is live, and it is never mirrored (mirrored
        // text is unreadable, and a screen is not a selfie).
        // Dual mode: my track stays my camera during a share, so only the fallback share counts here.
        // 1:1 audit #11: what is really going out (`camsSignal`), not `cameraOn`; a paused camera
        // shows my photo instead of a frozen frame.
        let localLive = camsSignal
        let mirrorLocal = usingFrontCamera && !shareOwnsCamera
        if isLocalExpanded {
            f.big = localLive ? localVideoTrack : nil
            f.mirrorBig = mirrorLocal
            f.bigName = myName; f.bigPhotoUrl = myPhotoUrl
            f.tile = remoteVideoLive ? remoteVideoTrack : nil
            f.tileName = otherName; f.tilePhotoUrl = otherPhotoUrl
        } else {
            f.big = remoteVideoLive ? remoteVideoTrack : nil
            // Their dual-mode share is on its own track and goes big, whatever their camera is doing.
            if remoteScreenSharing, remoteScreenMode == "track", let screen = remoteScreenTrack { f.big = screen }
            f.bigName = otherName; f.bigPhotoUrl = otherPhotoUrl
            f.tile = localLive ? localVideoTrack : nil
            f.mirrorTile = mirrorLocal
            f.tileName = myName; f.tilePhotoUrl = myPhotoUrl
        }
        // ⛔ WHILE IT RINGS, THE BIG VIEW IS MY CAMERA — owner, 2026-10-06, with two screenshots: the
        // call screen showed his camera under "Calling…", and the minimized card showed a photo on
        // black, which reads as a voice call. Before anyone answers there is no remote video to show,
        // so the big view is the self-preview, the same thing the call screen draws (the reference
        // app's preview fills its small window with the local camera when it is the only video).
        if state == .outgoing || state == .incoming, cameraOn, let local = localVideoTrack {
            f.big = local
            f.mirrorBig = usingFrontCamera
            f.bigName = myName; f.bigPhotoUrl = myPhotoUrl
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
    // Owner audit 2026-10-06 #18: the tile's resting place is a CORNER, not a stored offset. An
    // absolute offset was only right for the bounds it was measured against; when the chrome hid, the
    // tile shrank and its home dropped, and the same offset left it mid-screen. The offset is derived
    // from the corner and the live bounds every time. The live drag is the view's own state
    // (audit 11: writing it here re-rendered the whole call screen on every drag frame).
    var pipCornerLeft = false
    var pipCornerTop = false
    /// WHERE THE MINIMIZED CARD WAS LEFT. Owned here for the same reason as the tile above: the card
    /// is destroyed and rebuilt every time you go back into the call and minimize again, so view
    /// @State sent it home to the bottom-right corner every single time (owner, 2026-08-23 — it
    /// should land where you left it). Cleared with everything else when the call ends, so the next
    /// call starts in the corner rather than wherever the last one happened to finish.
    var cardOffset = CGSize.zero
    var cardBase = CGSize.zero
    /// The card's frame in window points, for the minimize/restore flight (`CallPipMorph`). Never
    /// read from a `body`, so writing it does not redraw anything.
    @ObservationIgnored var cardFrame = CGRect.zero
    /// The real card stays invisible while the minimize flight is landing on it.
    var cardHiddenForMorph = false
    /// The card has been shoved off the side and is sitting there as a tab (owner, 2026-08-23 —
    /// the reference app does this, and he asked whether we could without Apple's help; we can,
    /// because this only ever happens INSIDE our own window. Hiding a floating window past the edge
    /// of the SCREEN, over other apps, is the part only the system can do).
    ///
    /// Which side it went is not stored: `cardBase.width` is negative only when it was parked on the
    /// left, so the side is already written down and cannot disagree with itself.
    var cardStashed = false
    var localVideoTrack: RTCVideoTrack?
    var remoteVideoTrack: RTCVideoTrack?

    // MARK: Screen share v3 dual mode (screen on its own track, camera keeps running)
    //
    // Every new 1:1 connection carries a SECOND video transceiver for the screen (see
    // `screenTransceiver`). Dual mode needs both phones to say `caps.<uid>: ["screen2"]` in the call
    // doc AND that transceiver to be negotiated for sending. Anything else is FALLBACK: today's
    // behaviour, the screen replaces the camera on the camera's own source.
    //
    // Old-build safety: the caller offers the screen m-line RECVONLY, so an old callee (which binds
    // every incoming video track to its one remote view) never gets a second sending track. Once the
    // callee's caps say screen2, the caller flips it to sendrecv with one re-offer after connect
    // (`upgradeScreenTransceiverIfDue`). The callee can send on it from its first answer.
    /// Capability tag this build writes into the call doc.
    private static let screenCap = "screen2"
    /// The other phone wrote `caps.<them>` with screen2.
    private(set) var peerHasScreen2 = false
    /// THEIR screen in dual mode (the second video transceiver's receiver). Their camera stays on
    /// `remoteVideoTrack`.
    private(set) var remoteScreenTrack: RTCVideoTrack?
    /// How THEIR share is carried, from `screenMode.<them>`: "track" (dual mode, on
    /// `remoteScreenTrack`) or "camera" (fallback, on `remoteVideoTrack`). Old builds never write it.
    private(set) var remoteScreenMode: String = "camera"
    /// The track showing THEIR shared screen, whichever way it is carried.
    var remoteShareTrack: RTCVideoTrack? { remoteScreenMode == "track" ? remoteScreenTrack : remoteVideoTrack }
    /// MY current (or pending) share runs in dual mode. Decided when the share is asked for.
    private(set) var shareUsesTrack = false
    /// The share has taken over the camera's source (fallback mode): every camera path stands off.
    private var shareOwnsCamera: Bool { screenSharing && !shareUsesTrack }
    /// The camera button stays usable while sharing (dual mode). Before a share: whether one would be.
    var canUseCameraWhileSharing: Bool { screenSharing ? shareUsesTrack : dualModeAvailable }
    /// Dual-mode source and track ("screen0"), alive only for a dual-mode share.
    @ObservationIgnored private var screenSource: RTCVideoSource?
    @ObservationIgnored private var screenTrack: RTCVideoTrack?
    /// The caller's one-time re-offer that turns the screen m-line to sendrecv (bounded retries).
    @ObservationIgnored private var screenUpgradeOfferAt: Date?
    @ObservationIgnored private var screenUpgradeAttempts = 0
    /// The upgrade re-offer's negotiation version while its answer is outstanding. Kept apart from
    /// `restartInFlightAt` so a real ICE restart is never held back by it.
    @ObservationIgnored private var screenUpgradeInFlightVersion: Int?
    /// Dual mode, ladder's bottom tier: the camera was paused by the share (through the weak-link
    /// pause), so the share, not the link monitor, brings it back.
    @ObservationIgnored private var cameraPausedForShareTier = false

    private var videoCapturer: RTCCameraVideoCapturer?
    /// The ONE video source behind `localVideoTrack`. The camera capturer feeds it normally; during a
    /// screen share the ScreenShareCapturer feeds it instead (same track, same sender).
    @ObservationIgnored private var videoSource: RTCVideoSource?
    /// The extension link for a share that has been asked for (picker shown) or is running.
    @ObservationIgnored private var screenShareSession: ScreenShareSession?
    @ObservationIgnored private var screenCapturer: ScreenShareCapturer?
    /// Gives up on a picker that was opened but never started a broadcast, so we stop listening.
    @ObservationIgnored private var screenSharePendingTimeout: DispatchWorkItem?
    /// The app came back from the system sheet: if no broadcast started, the sheet was closed
    /// (1:1 audit #15, owner, 2026-10-08). See `watchPickerReturn`.
    @ObservationIgnored private var screenSharePickerReturn: NSObjectProtocol?
    /// A broadcast started from Control Center during a live 1:1 call is adopted as a share
    /// (1:1 audit #37, owner, 2026-10-08). See `installShareAdoption`.
    @ObservationIgnored private var shareAdoption: AnyCancellable?
    /// Audit M-106, 2026-10-07: after a pending share is abandoned, answers a late "broadcast started"
    /// with a stop request for 60s. See `armLateShareStop`.
    @ObservationIgnored private var lateShareStop: AnyCancellable?
    @ObservationIgnored private var lateShareStopExpiry: DispatchWorkItem?
    /// The share's quality ladder (owner, 2026-10-08), in place of audit M-107's single 2 Mbps /
    /// 600 kbps switch. Four tiers, frame rate gives first; see ScreenShareQuality.
    @ObservationIgnored private var shareQuality = ScreenShareQuality()
    /// The video sender's bytesSent at the previous stats read, for its real send rate.
    @ObservationIgnored private var shareLastSent: (bytes: Double, at: Date)?
    private(set) var callId: String?
    /// Readable so the call screen can draw a verified mark beside the name. Still only writable in
    /// here: who is on the other end of a call is decided by the signalling, never by a view.
    private(set) var otherUid: String = ""
    private(set) var isCaller = false   // readable (audit round 2, V3 N6): CallKitManager arms its unmute window for the caller only

    // Reconnection / lifecycle timers.
    private var noAnswerWork: DispatchWorkItem?      // outgoing: nobody answered -> Missed
    private var acceptedConnectWork: DispatchWorkItem? // outgoing: they ACCEPTED but the answer never landed -> Failed fast
    private var iceRestartWork: DispatchWorkItem?    // delayed ICE restart after a drop
    private var reconnectGiveUpWork: DispatchWorkItem? // hard cap: can't recover -> Failed
    private var iceRestartRetryWork: DispatchWorkItem? // re-offer every few seconds while still reconnecting
    private var pathMonitor: NWPathMonitor?            // network switch watcher, live while a call is up
    private var lastPathKey: String?                   // last interface set seen, to spot a real change
    private var restartRequestsSent = 0                // callee -> caller "please restart ICE" counter
    private var restartRequestsSeen = 0                // caller side: highest request already served
    private var negotiationVersion = 0               // bumps each ICE restart / media renegotiation (caller)
    private var pendingOffer: [String: String]?      // cached incoming offer → answer without a server round-trip
    private var appliedRemoteRestart = 0             // last restart version we applied

    private let db = Firestore.firestore()
    private var pc: RTCPeerConnection?
    private var listeners: [ListenerRegistration] = []
    private var incomingListener: ListenerRegistration?
    private var ringingWatcher: ListenerRegistration?   // while .incoming: detect caller-cancel before answer
    /// Calls whose refused ring watch was already re-checked once (2026-10-08): a second refusal ends
    /// the ring quietly instead of looping token refresh → read → re-attach → refused.
    private var ringRechecked: Set<String> = []

    // LISTENERS THAT COME BACK (owner, 2026-10-08). A Firestore listener that ends in an error is
    // dead for good, and every one in this file threw its error away: after one refused token or
    // stalled connection the phone stopped ringing for the rest of the session, and a live call
    // went deaf to the answer, the hang-up and the other side's routes. Each one now reports to
    // SessionRecovery and is attached again on `SessionRecovery.recovered`, or after a back-off
    // when the error was not a refusal. Incoming also re-attaches on foreground.
    private var incomingWanted = false        // observeIncoming has been asked for (signed in, shell up)
    private var incomingDead = false          // the incoming listener ended in an error
    private var incomingHeardServer = false   // a server (non-cache) snapshot arrived since it attached
    private var incomingAttach = 0            // which attach is current; an older one's error or retry does nothing
    private var incomingRetryStep = 0         // back-off position (5s, 15s, 30s, then 60s), reset by a server snapshot
    private var recoveryObserved = false
    private var callDocWatch: DocumentReference?       // the live call's doc, for re-attaching observeCallDoc
    private var callDocListener: ListenerRegistration?
    private var candidatesWatch: CollectionReference?  // the other side's candidates, for observeRemoteCandidates
    private var candidatesListener: ListenerRegistration?
    private var ringingWatchId: String?                // the call watchRingingCancel is watching
    /// Candidate docs already handed to WebRTC this call. A re-attached listener's first snapshot
    /// lists every candidate again as "added"; these are skipped. Cleared in finishCall.
    private var appliedCandidateIds: Set<String> = []

    private var me: String { Auth.auth().currentUser?.uid ?? "" }

    // MARK: - Sealed signalling (owner audit 2026-10-06 #27)
    //
    // The offer, the answer, every ICE-restart offer/answer and every ICE candidate used to sit in
    // the call document as plain text: IP addresses and the DTLS fingerprint, readable (and the
    // fingerprint swappable) by anyone with server access. The reference app carries all call
    // signalling inside its end-to-end channel. Each payload is now sealed with the 1:1 chat crypto
    // (same keys, same conversation id) and only ciphertext is written: `offerEnc`, `answerEnc`,
    // `restartOffer.enc`, `restartAnswer.enc`, candidate `enc`, plus `sig: 2` on the call doc.
    //
    // 1:1 audit r2 G2, 2026-10-08: NO PLAINTEXT SIGNALLING. The caller reads the callee's key fresh
    // before the offer (`ensureSignalKey`); no key = the call fails with "Can't call right now".
    // The callee refuses an unsealed offer and ends quietly as failed (`readOffer`). Every build
    // since 827 seals. A plaintext SDP on a sealed call is refused (a swapped fingerprint looks like
    // that). Plaintext candidates are still taken (DTLS, whose fingerprint is sealed, makes an
    // injected route useless).
    private var sealSignalling = false
    private var signalCid: String { ChatService.convId(me, otherUid) }

    /// Seal one signalling payload for this call, or nil when this call is not sealed. A seal that
    /// fails on a sealed call (key dropped from the cache mid-call) is logged and the caller sends
    /// plaintext, so a reconnect is late rather than lost.
    private func sealSignal(_ text: String) -> String? {
        guard sealSignalling, !otherUid.isEmpty else { return nil }
        let s = Crypto.shared.encryptForConversationIfCached(signalCid, text)
        if s == nil { print("call: #27 seal failed on a sealed call, sending this one unsealed") }
        return s
    }

    /// Open one sealed payload. nil = not sealed, or not openable yet (key not in memory): the
    /// marker strings `decrypt` returns for those are never valid SDP or candidate JSON.
    private func openSignal(_ raw: String?) -> String? {
        guard let raw, raw.hasPrefix("enc1:"), !otherUid.isEmpty else { return nil }
        let out = Crypto.shared.decrypt(raw, cid: signalCid)
        guard out != raw, out != "…", out != "🔒", out != "[old message]" else {
            warmSignalKey()
            return nil
        }
        return out
    }

    /// An SDP from the call doc: the sealed field first; the old plaintext one only on a call that
    /// is not sealed (see the note above).
    private func signalSdp(sealed: Any?, plain: Any?) -> String? {
        if let s = openSignal(sealed as? String) { return s }
        guard !sealSignalling else { return nil }
        return plain as? String
    }

    /// The offer of a call document, read by the callee. A sealed offer that opens makes the call
    /// sealed. nil when absent or sealed but not openable yet; the key warm is already started and
    /// the callers' own retries pick it up.
    private func readOffer(_ d: [String: Any]) -> String? {
        if let enc = d["offerEnc"] as? String {
            guard let sdp = openSignal(enc) else { return nil }
            sealSignalling = true
            return sdp
        }
        // 1:1 audit r2 G2, 2026-10-08: an unsealed offer is refused, never answered in plaintext
        // (the reference app drops an offer without identity keys). The call ends quietly as failed.
        sealSignalling = false
        if d["offer"] != nil, let id = callId { refuseUnsealedOffer(id) }
        return nil
    }

    /// 1:1 audit r2 G2, 2026-10-08: end this ring or call quietly as failed (no tone, no miss).
    private func refuseUnsealedOffer(_ id: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.callId == id, !self.isCaller,
                  self.state != .idle, self.state != .ended else { return }
            print("call: G2 unsealed offer refused")
            self.endReason = .failed
            self.endLocally()
        }
    }

    /// 1:1 audit r2 G2, 2026-10-08: the callee's key in memory before the offer is made, read fresh
    /// from the server (a key from before a reinstall seals an offer their phone cannot open).
    /// false = no key after that read: the dial fails, never goes out unsealed.
    private func ensureSignalKey(_ peer: String) async -> Bool {
        guard !peer.isEmpty else { return false }
        try? await Crypto.shared.ensureReady()
        switch await Crypto.shared.fetchFreshKey(peer) {
        case .key: break
        case .noKey: return false
        case .unreachable: _ = await Crypto.shared.preloadKey(peer)   // offline: the cached key
        }
        return Crypto.shared.encryptForConversationIfCached(ChatService.convId(me, peer), "k") != nil
    }

    /// 1:1 audit r2 G3, 2026-10-08: Settings > Privacy > "Always Relay Calls".
    static var alwaysRelay: Bool { UserDefaults.standard.bool(forKey: "calls.alwaysRelay") }

    /// Get the peer's key into memory, off the hot path (dial / ring time), so sealing and opening
    /// never wait on a network read. `fresh` (caller) re-reads it from the server: a key cached
    /// from before the callee reinstalled would seal an offer their phone can never open.
    private func warmSignalKey(fresh: Bool = false) {
        let peer = otherUid
        guard !peer.isEmpty else { return }
        Task.detached {
            try? await Crypto.shared.ensureReady()
            if fresh, case .key = await Crypto.shared.fetchFreshKey(peer) { return }
            _ = await Crypto.shared.preloadKey(peer)
        }
    }

    private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        // Screen share v3: the factory carries the app-audio mixer (capture post-processing), so
        // the shared app's sound rides in my mic track while I share. Plain factory if unavailable.
        return ScreenShareAudioMixer.makeFactory()
    }()

    /// 1:1 audit #17 (owner, 2026-10-08): builds the factory above off the main thread at launch
    /// (CallKitManager's init), so the first ring or dial no longer pays for it on main. A static
    /// let is initialised once and thread-safely; a caller that arrives mid-build waits for it.
    static func warmUpEngine() {
        DispatchQueue.global(qos: .userInitiated).async { _ = CallService.factory }
    }

    // STUN-only fallback (used until the real TURN relay list arrives from the server, and if
    // that fetch ever fails). STUN alone connects phones on friendly networks; the TURN relay
    // from `iceServers` is what makes calls work across mobile/CGNAT (the reported failures).
    private static let fallbackIceServers = [
        RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302", "stun:stun1.l.google.com:19302"]),
    ]
    // Filled by refreshIceServers() from the `iceServers` Cloud Function (real TURN creds live
    // server-side, never in this public repo). Read on every new peer connection.
    private var fetchedIceServers: [RTCIceServer]? {
        get { iceServersFetchedAt.map { Date().timeIntervalSince($0) < Self.iceServersMaxAge } == true ? iceServersCache : nil }
        set { iceServersCache = newValue; iceServersFetchedAt = newValue == nil ? nil : Date() }
    }
    /// ⛔ RELAY CREDENTIALS EXPIRE, AND A LIST HELD PAST THAT IS WORSE THAN NONE. The server mints
    /// them for two hours (`iceServers`, ttl 7200). This list used to be fetched once and trusted
    /// for the life of the process, so a call placed from an app left open overnight offered TURN
    /// with dead credentials: the relay refuses them silently and the call fails on exactly the
    /// networks the relay exists for. The reference app expires its cached list at the server's TTL;
    /// here it is treated as gone after 90 minutes, which leaves any call started on it a 30-minute
    /// margin, and the next call fetches fresh (`awaitIceServers`).
    private static let iceServersMaxAge: TimeInterval = 90 * 60
    private var iceServersCache: [RTCIceServer]?
    private var iceServersFetchedAt: Date?

    /// WHO IS ALLOWED TO SEE MY IP ADDRESS.
    ///
    /// A WebRTC call that connects directly, phone to phone, tells each side the other's IP — which
    /// gives away roughly where somebody is and who their provider is. We set no transport policy at
    /// all before this, so EVERY call could go direct, including a call from somebody who found this
    /// account by QR code or username and has never met its owner.
    ///
    /// Relaying everything is not the answer either: relayed media runs through our TURN server, so
    /// it costs real bandwidth per minute and adds a hop. The rule the established messengers use,
    /// and the one here, is to spend that only where the risk is: people you have an ACCEPTED chat
    /// with connect directly, strangers are relayed.
    ///
    /// `accepted` is exactly the right question — it means this account replied, which is the moment
    /// a stranger stops being one. A chat that predates message requests reads accepted, which is
    /// correct: those are people already being talked to.
    /// Answered ONCE per call, when the peer becomes known, and stored.
    ///
    /// ⚠️ Not computed at connection time. `config` is read while building the peer connection, which
    /// is not guaranteed to be the main thread, and the answer would then depend on reaching into
    /// another observable object's array from there. Deciding at the one moment `otherUid` is set
    /// makes it deterministic for the whole call.
    private(set) var peerIsEstablishedContact = false

    private func resolvePeerTrust() {
        guard !otherUid.isEmpty, !me.isEmpty else { peerIsEstablishedContact = false; return }
        let cid = [me, otherUid].sorted().joined(separator: "_")
        // No chat at all → a stranger, which is the safe reading: it is exactly the QR-code and
        // username case, where two people who have never spoken are connecting.
        let known = ConversationsRepository.shared.conversations.first(where: { $0.id == cid })
        peerIsEstablishedContact = known?.accepted ?? false
        // 2026-09-24 fix-all #231: on a cold launch (a call that woke the app) the chat list has not
        // loaded yet, so every contact read as a stranger and the call went relay-only. When the chat
        // is not in the list, read the conversation itself; the connection-building paths wait for
        // that answer (`awaitPeerTrust`, at most 1.5s) before `config` is read. No doc, a failed
        // read or a timeout keeps the safe reading: stranger.
        peerTrustPending = false
        guard known == nil else { return }
        peerTrustPending = true
        let peer = otherUid
        Task { [weak self] in
            let snap = try? await Firestore.firestore().collection("conversations").document(cid).getDocument()
            await MainActor.run {
                guard let self, self.otherUid == peer else { return }
                if let data = snap?.data() {
                    self.peerIsEstablishedContact = Conversation(id: cid, data: data).accepted
                }
                self.peerTrustPending = false
            }
        }
    }

    /// 2026-09-24 fix-all #231: true while `resolvePeerTrust` is still reading the conversation.
    private var peerTrustPending = false

    /// Wait (bounded) for the contact check above before anything reads `config`.
    private func awaitPeerTrust(timeout: Double = 1.5) async {
        let deadline = Date().addingTimeInterval(timeout)
        while peerTrustPending, Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private var config: RTCConfiguration {
        let c = RTCConfiguration()
        let servers = fetchedIceServers ?? Self.fallbackIceServers
        c.iceServers = servers
        // ⚠️ RELAY ONLY IF WE ACTUALLY HAVE A RELAY, and a relay means a `turn:` URL specifically.
        // `.relay` against a STUN-only list is not a private call, it is NO call: nothing will ever
        // produce a relay candidate and the connection can never come up. A failed TURN fetch, or a
        // server that hands back STUN only, must therefore fall back to `.all` — connecting beats
        // failing silently, and the call then behaves exactly as it did before this existed.
        //
        // 2026-09-24 audit: that `.all` fallback is for established contacts ONLY. A failed or slow
        // relay fetch used to send a STRANGER's call direct too, handing both IPs to someone found by
        // QR code or username. A stranger with no relay in hand is now refused before this is read
        // (see `strangerWithoutRelay`), and this line is the last lock: if a new path ever forgets
        // that check, a stranger's call stays relay-only and fails instead of going direct.
        // 1:1 audit r2 G3, 2026-10-08: "Always Relay Calls" (Privacy) relays every call.
        c.iceTransportPolicy = peerIsEstablishedContact && !Self.alwaysRelay ? .all : .relay
        c.sdpSemantics = .unifiedPlan
        // Connect faster (shorter "Connecting…"): pre-gather ICE candidates so they're ready the
        // instant the offer/answer is set, keep gathering continuously, and bundle all media on ONE
        // transport so there are far fewer candidate pairs to check before the path comes up.
        c.iceCandidatePoolSize = 1
        c.continualGatheringPolicy = .gatherContinually
        c.bundlePolicy = .maxBundle
        c.rtcpMuxPolicy = .require
        // Keep the BACKUP candidate pairs warm: pinged every 2s instead of libwebrtc's ~25s, so when
        // the path in use dies (Wi-Fi drops while mobile data is up) a working pair is already proven
        // and the switch takes a moment instead of a fresh search. Costs a few tiny STUN packets.
        c.iceBackupCandidatePairPingInterval = 2000
        return c
    }

    /// Pull the live TURN/STUN list from the server (short-lived credentials). Call at launch
    /// after sign-in and again when starting/answering a call so credentials are always fresh.
    /// Never throws — on any failure we keep whatever we had (or the STUN fallback).
    func refreshIceServers() async {
        // A failure is reported to SessionRecovery now (owner, 2026-10-08); still never throws.
        let reply: Any
        do {
            reply = try await Functions.functions(region: "me-central1").httpsCallable("iceServers").call().data
        } catch {
            Self.reportToRecovery(error, "call relay list")
            return
        }
        guard let arr = (reply as? [String: Any])?["iceServers"] as? [[String: Any]] else { return }
        // ONE RTCIceServer PER URL (the reference app does the same): a server entry carrying both
        // the UDP route and the TLS-on-443 route is otherwise one unit, and each route should be
        // gathered, and fail, on its own.
        let servers: [RTCIceServer] = arr.flatMap { s -> [RTCIceServer] in
            guard let urls = s["urls"] as? [String] ?? (s["urls"] as? String).map({ [$0] }) else { return [] }
            return urls.map { url -> RTCIceServer in
                if let user = s["username"] as? String, let cred = s["credential"] as? String {
                    return RTCIceServer(urlStrings: [url], username: user, credential: cred)
                }
                return RTCIceServer(urlStrings: [url])
            }
        }
        guard !servers.isEmpty else { return }
        // 1:1 audit r2 F4, 2026-10-08: a STUN-only reply (both relay providers down) never replaces
        // a list that still has a relay; a live call keeps the relay it can use.
        // 1:1 audit r2 J5, 2026-10-08: written on main, where every reader of the list runs.
        await MainActor.run {
            if !Self.hasRelay(servers), let held = self.fetchedIceServers, Self.hasRelay(held) { return }
            self.fetchedIceServers = servers
        }
    }

    /// 1:1 audit r2 F4: the list carries a `turn:`/`turns:` server.
    private static func hasRelay(_ servers: [RTCIceServer]) -> Bool {
        servers.contains { $0.urlStrings.contains { $0.hasPrefix("turn:") || $0.hasPrefix("turns:") } }
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
        if fetchedIceServers != nil {
            // Audit M-009, 2026-10-07: a list still inside its 90 minutes can be 89 minutes old, which
            // leaves a call started on it about half an hour before the relay refuses its credentials.
            // Past 30 minutes, ask for a fresh one and wait a short, bounded moment for it; on timeout
            // the old list (still valid) is used and the fetch keeps running for the restart path
            // (`applyNewerIceServers`).
            guard let at = iceServersFetchedAt,
                  Date().timeIntervalSince(at) > Self.iceServersRefreshAge else { return }
            let refresh = Task { await self.refreshIceServers() }
            let until = Date().addingTimeInterval(min(timeout, 1.0))
            while iceServersFetchedAt == at, Date() < until {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            _ = refresh
            return
        }
        let fetch = Task { await self.refreshIceServers() }
        let deadline = Date().addingTimeInterval(timeout)
        while fetchedIceServers == nil, Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        _ = fetch   // deliberately NOT cancelled: let it finish and warm the next call
    }

    /// Audit M-009, 2026-10-07: past this age a list is refreshed at call start and on a drop.
    private static let iceServersRefreshAge: TimeInterval = 30 * 60
    /// When the list the LIVE connection was built with was fetched; nil = the STUN-only fallback.
    /// The connection used to keep its creation-time servers for life, so a call that started on the
    /// fallback (the TURN list landed a few seconds late) could never get a relay, and every ICE
    /// restart on carrier NAT failed the same way. Compared with `iceServersFetchedAt` to tell when a
    /// newer list is in hand.
    private var pcIceServersFetchedAt: Date?

    /// Audit M-009, 2026-10-07: hand the live connection a newer TURN list than the one it was built
    /// with, if one is cached. Called right before an ICE restart (both sides), because only the
    /// gathering a restart starts uses the new servers. Everything else in `config` is unchanged, so
    /// libwebrtc accepts the change mid-call.
    private func applyNewerIceServers(to connection: RTCPeerConnection) {
        guard fetchedIceServers != nil, let at = iceServersFetchedAt, at != pcIceServersFetchedAt else { return }
        if connection.setConfiguration(config) {
            pcIceServersFetchedAt = at
        } else {
            print("call: M-009 setConfiguration refused the newer ICE servers")
        }
    }

    /// Audit M-009, 2026-10-07: the media path dropped. With no list, or one past the refresh age,
    /// start a fetch now so the restart (or its 8s retry) can use it.
    private func refreshIceServersForReconnect() {
        // No list at all (the fallback call whose fetch failed) reads as stale too. A fresh list that
        // simply landed after the connection was built needs no fetch: the restart picks it up.
        let stale = iceServersFetchedAt.map { Date().timeIntervalSince($0) > Self.iceServersRefreshAge } ?? true
        guard stale else { return }
        Task { await self.refreshIceServers() }
    }

    /// 2026-09-24 audit: true when this call must be relayed (the peer is not an established
    /// contact) but no `turn:`/`turns:` server is in hand. Such a call ends as a failure through the
    /// normal `.failed` path; contacts are unaffected and still fall back to STUN-only.
    private var strangerWithoutRelay: Bool {
        // 1:1 audit r2 G3, 2026-10-08: with "Always Relay Calls" on, every call needs a relay.
        guard !peerIsEstablishedContact || Self.alwaysRelay else { return false }
        let servers = fetchedIceServers ?? Self.fallbackIceServers
        return !servers.contains { $0.urlStrings.contains { url in
            url.hasPrefix("turn:") || url.hasPrefix("turns:")
        } }
    }

    /// For a stranger, give the relay fetch one more, longer chance before refusing the call.
    private func awaitRelayForStranger() async {
        // A list that arrived without TURN will not grow one on a retry; only a missing list waits.
        guard strangerWithoutRelay, fetchedIceServers == nil else { return }
        await awaitIceServers(timeout: 6.0)
    }

    // Audio session is owned by CallKit (manual mode) — see CallKitManager.

    private func makePeerConnection() -> RTCPeerConnection? {
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        // Audit M-009: remember which list this connection carries (nil = STUN fallback).
        pcIceServersFetchedAt = fetchedIceServers == nil ? nil : iceServersFetchedAt
        let connection = Self.factory.peerConnection(with: config, constraints: constraints, delegate: self)
        // Local mic track.
        let audioSource = Self.factory.audioSource(with: nil)
        let audioTrack = Self.factory.audioTrack(with: audioSource, trackId: "audio0")
        // ⛔ DISABLED WHEN THIS CONNECTION IS BUILT BEFORE THE PERSON ANSWERED. The pre-negotiated
        // path builds everything during the ring so the accept is instant, and the price of that is
        // that a live connection exists to somebody who has not said yes yet. It carries silence
        // until `answer()` enables this track. Do not "tidy" this to always-true: it is the lock.
        //
        // Belt as well as braces — CallKit owns the audio session and WebRTC's audio unit stays off
        // until didActivate, which only fires on a real answer. Either one alone would be enough;
        // both together mean a refactor has to break two things to start recording somebody early.
        //
        // 2026-09-24 audit: also honour a mute tapped BEFORE this track existed. The caller's mute
        // button is live from "Calling…", but the track is only built after the mic prompt and the
        // relay fetch, so `toggleMute` hit a nil track and the call went out with the mic open while
        // the button read muted. Nothing re-applied it later.
        audioTrack.isEnabled = !(preNegotiated && !wasAccepted) && !(isMuted || isHeld)
        connection?.add(audioTrack, streamIds: ["stream0"])
        localAudioTrack = audioTrack
        // Always negotiate a video m-line up front — the track is DISABLED for a voice call (no
        // frames, no camera). This makes a mid-call camera toggle a pure track-enable with NO
        // renegotiation (which is fragile + glare-prone) and no black-remote-on-re-toggle bugs.
        addLocalVideo(to: connection)
        // Screen share v3: the caller puts the screen's m-line in the offer, right after the camera's,
        // so it is always the SECOND video m-line. The callee gets its transceiver from the offer.
        if isCaller { addScreenTransceiver(to: connection) }
        applyDataSaver(to: connection)
        // The CALLER opens it, because the caller writes the offer and the channel has to be in that
        // offer to be negotiated at all. The callee receives it through `didOpen` instead.
        if isCaller, let connection {
            let cfg = RTCDataChannelConfiguration()
            cfg.isOrdered = true            // one tiny message; ordering is free and delivery matters
            if let ch = connection.dataChannel(forLabel: Self.acceptChannelLabel, configuration: cfg) {
                ch.delegate = self
                acceptChannel = ch
            }
        }
        return connection
    }

    // Use Less Data (Settings > Storage and Data > Calls): cap the sender bitrates when
    // the saver is active on the current network. Audio ~24 kbps still sounds fine for
    // speech; video drops to 300 kbps at half resolution.
    /// 1:1 audit #8 (owner, 2026-10-08): also re-run by the path monitor when the call moves between
    /// Wi-Fi and cellular. `onWifi` is that monitor's own reading, so this does not race the app-wide
    /// NetworkState updating from the same event. The saver-off branch now also UNDOES the saver
    /// (audio cap, half resolution), or a call that started on cellular stayed small on Wi-Fi.
    private func applyDataSaver(to connection: RTCPeerConnection?, onWifi: Bool? = nil) {
        guard let connection else { return }
        let saverOn: Bool
        if let onWifi, UserDefaults.standard.string(forKey: "calls.lessData") == "cellular" {
            saverOn = !onWifi
        } else {
            saverOn = UseLessDataPage.activeNow
        }
        guard saverOn else {
            for sender in connection.senders where sender.track?.kind == "audio" {
                let params = sender.parameters
                guard params.encodings.contains(where: { $0.maxBitrateBps != nil }) else { continue }
                params.encodings.forEach { $0.maxBitrateBps = nil }
                sender.parameters = params
            }
            // Saver off: video still gets a CEILING (2026-10-04, the reference engine's numbers).
            // Uncapped, the encoder ramps until the link queues, and on a weak link that queue is
            // the voice breaking up. 2 Mbps normally; 1 Mbps when the call is relay-only (a
            // stranger), because every relayed bit is paid for twice and crosses an extra hop.
            let cap = peerIsEstablishedContact ? 2_000_000 : 1_000_000
            // A screen share sets its own video encoding (applyScreenShareEncoding) and keeps it.
            guard !screenSharing else { return }
            for sender in connection.senders where sender.track?.kind == "video" {
                let params = sender.parameters
                params.encodings.forEach {
                    $0.maxBitrateBps = NSNumber(value: cap)
                    $0.scaleResolutionDownBy = nil   // #8: full size again after the saver
                }
                sender.parameters = params
            }
            return
        }
        for sender in connection.senders {
            let params = sender.parameters
            for enc in params.encodings {
                if sender.track?.kind == "audio" {
                    enc.maxBitrateBps = NSNumber(value: 24_000)
                } else if sender.track?.kind == "video", !screenSharing {
                    // Never on a screen share: half resolution makes its text unreadable.
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
            // 2026-10-04: the reference engine's measured voice profile, which it tuned with loss
            // simulations: 32 kbps CONSTANT bitrate, in-band FEC, 60 ms packets. CBR keeps packet
            // sizes steady under congestion control; FEC lets the next packet rebuild a lost one;
            // 60 ms packets are a third of the per-packet header overhead of 20 ms, which matters
            // most on exactly the weak links this is for. Was 24 kbps VBR with 20 ms packets.
            if !lines[i].contains("maxaveragebitrate") { lines[i] += ";maxaveragebitrate=32000" }
            if !lines[i].contains("cbr=") { lines[i] += ";cbr=1" }
            if !lines[i].contains("useinbandfec") { lines[i] += ";useinbandfec=1" }
            // a=ptime is the packet length this side wants to RECEIVE; both ends munge, so both
            // send 60 ms. Placed right after the fmtp line, inside the audio section.
            if !lines[audio].contains(where: { $0.hasPrefix("a=ptime:") }) {
                lines.insert("a=ptime:60", at: i + 1)
            }
        }
        // RED is NOT preferred any more (2026-10-04). It sends every frame twice, doubling audio on
        // the wire, and the reference engine relies on FEC alone. With FEC + CBR above, RED would
        // push a 2G leg from 32 to 64 kbps. Left in the codec list (harmless), just not first.
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
        videoSource = source
        videoCapturer = capturer
        localVideoTrack = track
        if cameraOn { startCameraCapture() }
    }

    // Adds the local video track (once, at call setup). Only fires the camera + its permission
    // prompt if my camera is actually on now — a voice call adds a silent, disabled track.
    private func addLocalVideo(to connection: RTCPeerConnection?) {
        guard let connection else { return }
        prepareLocalVideo()
        // 1:1 audit #13; r2 J4: the freeze watch now starts with their camera (remoteCameraOn).
        if remoteCameraOn { startRemoteFreezeWatchIfNeeded() }
        guard let track = localVideoTrack else { return }
        track.isEnabled = cameraOn   // the toggle may have moved between warm-up and attach
        connection.add(track, streamIds: ["stream0"])
    }

    // MARK: - Screen transceiver (screen share v3, dual mode)

    /// Caller only, once, at setup. RECVONLY in the first offer: an old callee then has nothing new
    /// arriving and keeps today's experience exactly. A new callee answers it sendonly (it can share
    /// at once); the caller's own sending side is opened by `upgradeScreenTransceiverIfDue`.
    private func addScreenTransceiver(to connection: RTCPeerConnection?) {
        guard let connection else { return }
        let ini = RTCRtpTransceiverInit()
        ini.direction = .recvOnly
        ini.streamIds = ["screen0"]
        if connection.addTransceiver(of: .video, init: ini) == nil {
            print("[ScreenShare] could not add the screen transceiver; this call shares in fallback mode")
        }
    }

    /// The screen's transceiver: the SECOND video transceiver in `pc.transceivers` order, on both
    /// sides. Nil on a call with an old peer as caller (its offer has one video m-line).
    private func screenTransceiver(in pc: RTCPeerConnection) -> RTCRtpTransceiver? {
        let video = pc.transceivers.filter { $0.mediaType == .video }
        return video.count >= 2 ? video[1] : nil
    }

    /// The camera's transceiver: the first video transceiver.
    private func cameraTransceiver(in pc: RTCPeerConnection) -> RTCRtpTransceiver? {
        pc.transceivers.first { $0.mediaType == .video }
    }

    /// The screen transceiver has been negotiated with a sending direction on MY side.
    private func screenCanSend(_ pc: RTCPeerConnection) -> Bool {
        guard let t = screenTransceiver(in: pc) else { return false }
        var current = RTCRtpTransceiverDirection.inactive
        guard t.currentDirection(&current) else { return false }
        return current == .sendRecv || current == .sendOnly
    }

    /// A share started now would run in dual mode.
    private var dualModeAvailable: Bool {
        guard peerHasScreen2, let pc else { return false }
        return screenCanSend(pc)
    }

    /// Callee, after setRemoteDescription(offer) and before createAnswer: an offer with two video
    /// m-lines came from a v3 caller, so the second one becomes our screen sender. Idempotent.
    private func acceptScreenTransceiver(_ pc: RTCPeerConnection) {
        guard let t = screenTransceiver(in: pc), t.direction != .sendRecv else { return }
        t.setDirection(.sendRecv, error: nil)
    }

    /// Caller: once the call is up and the callee has said screen2, turn the screen m-line to
    /// sendrecv with one re-offer (no ICE restart; the restartOffer/restartAnswer path carries it).
    /// Called on every call-doc snapshot, so it retries by itself; at most 3 tries per call.
    private func upgradeScreenTransceiverIfDue() {
        // 1:1 audit #28 (owner, 2026-10-08): our own unanswered upgrade offer leaves the connection
        // in have-local-offer, and `stable` alone then blocked every retry for the rest of the call.
        // Re-offering over our own latest upgrade is allowed (a newer version; a late answer to the
        // old one fails the version check); the 8s spacing and the 3-try cap below still hold.
        guard let pc else { return }
        let stalledUpgrade = pc.signalingState == .haveLocalOffer
            && screenUpgradeInFlightVersion != nil && screenUpgradeInFlightVersion == negotiationVersion
        guard isCaller, peerHasScreen2, state == .active, connectedDate != nil,
              pc.remoteDescription != nil, pc.signalingState == .stable || stalledUpgrade,
              let t = screenTransceiver(in: pc) else { return }
        var current = RTCRtpTransceiverDirection.inactive
        if t.currentDirection(&current), current == .sendRecv { return }
        guard screenUpgradeAttempts < 3 else { return }
        if let at = screenUpgradeOfferAt, Date().timeIntervalSince(at) < 8 { return }
        // An ICE restart still waiting for its answer goes first (its offer carries the m-line too).
        if let t = restartInFlightAt, Date().timeIntervalSince(t) < 6 { return }
        if t.direction != .sendRecv { t.setDirection(.sendRecv, error: nil) }
        screenUpgradeAttempts += 1
        screenUpgradeOfferAt = Date()
        print("[ScreenShare] opening the screen m-line for sending (try \(screenUpgradeAttempts))")
        restartIce(iceRestart: false)
    }

    // Ask for camera access, then feed frames into the local track (off the main thread). Without
    // the access check the capturer can silently never produce frames -> black video on both ends.
    private func startCameraCapture() {
        // Register BEFORE the first frame: an outgoing video call captures while still ringing, so
        // waiting for .active would miss a backgrounding during the ring.
        observeLifecycleIfNeeded()
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard let self else { return }
            guard granted else {
                DispatchQueue.main.async { self.cameraAccessDenied() }
                return
            }
            self.startCaptureIfWanted(front: nil)
        }
    }

    /// Audit M-011, 2026-10-07: camera access is off. Shown by the call screen as a one-line note
    /// (`Allow camera access in Settings`); reset at .idle.
    private(set) var cameraDenied = false

    /// Audit M-011, 2026-10-07: the denied branch used to return silently, so the button stayed ON,
    /// `cams` said true (seeded from the call type) and the other side got a black tile. Undo the
    /// intent the same way a camera-off tap does, and say why. Main only.
    private func cameraAccessDenied() {
        guard inLiveCall, cameraOn, !shareOwnsCamera else { return }
        cameraDenied = true
        cameraOn = false
        cameraStarting = false   // r2 E1
        localVideoTrack?.isEnabled = false
        if isLocalExpanded { isLocalExpanded = false }
        CallKitManager.shared.updateHasVideo(false)
        broadcastCameraState()
        updateInCallScreenBehavior()
    }

    /// The ONE answer to "should the camera be capturing right now", checked by every path that can
    /// start it (owner audit 2026-10-06 #1, #14). Each start path used to check its own subset: the
    /// weak-link resume forgot hold, the foreground backstop and the thermal restart forgot the
    /// weak-link pause, and none of them looked again after their async hops. So a hold, a weak link
    /// or a quick off-toggle could each be undone by a start that was already on its way, leaving the
    /// camera light on while the other side was told the camera was off.
    ///
    /// `cameraPausedByBackground` is deliberately NOT in here: that pause is recovered BY restarting
    /// the capture (resumeCameraIfReallyBack), so blocking starts on it would make it permanent.
    private var cameraShouldRun: Bool {
        // `!shareOwnsCamera`: a fallback share owns the video source while it runs. A thermal step, a
        // foreground backstop or an interruption retry must not start the camera into the same source
        // and interleave camera frames with screen frames. stopScreenShare restarts it if wanted.
        inLiveCall && cameraOn && !videoPausedForNetwork && !isHeld && !shareOwnsCamera
    }

    /// Re-checks `cameraShouldRun` on main AFTER whatever async hop led here (permission callback,
    /// stopCapture completion), then starts off-main. `front` nil means "whichever camera is current".
    /// A start refused here still resolves a pending front/back switch, or its flipped tile never
    /// swings back. startCapture's own completion re-checks once more for the gap after this one.
    private func startCaptureIfWanted(front: Bool?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard self.cameraShouldRun else {
                // 1:1 audit #33: a switch refused mid-way (paused during the stop) keeps its choice.
                if let want = self.pendingSwitchTarget { self.usingFrontCamera = want }
                self.resolvePendingSwitch(); return
            }
            let target = front ?? self.usingFrontCamera
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.startCapture(front: target) }
        }
    }

    /// Ends a front/back switch's flip animation. Main only.
    private func resolvePendingSwitch() {
        guard pendingSwitchTarget != nil else { return }
        pendingSwitchTarget = nil
        cameraSwitchFlip += 1
    }

    /// 1:1 audit r2 E4, 2026-10-08: mirror and flip change when the new camera's first frame reaches
    /// the track, so the old frozen frame is never shown re-mirrored. Main only.
    private var switchProbe: FirstFrameProbe?
    private var switchProbeSeq = 0
    private func resolveSwitchOnFirstFrame(track: RTCVideoTrack, front: Bool) {
        if let old = switchProbe { track.remove(old); switchProbe = nil }
        switchProbeSeq &+= 1
        let seq = switchProbeSeq
        let finish: () -> Void = { [weak self, weak track] in
            guard let self, self.switchProbeSeq == seq else { return }
            self.switchProbeSeq &+= 1
            if let p = self.switchProbe { track?.remove(p); self.switchProbe = nil }
            guard self.pendingSwitchTarget != nil else { return }   // the call ended meanwhile
            self.usingFrontCamera = front
            self.resolvePendingSwitch()
        }
        let probe = FirstFrameProbe(finish)
        switchProbe = probe
        track.add(probe)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: finish)
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
                // cameraShouldRun, not just cameraOn: a thermal step used to restart a camera that a
                // weak link or a hold had stopped (owner audit 2026-10-06 #14).
                guard let self, cameraShouldRun, !cameraPausedByBackground, videoCapturer != nil else { return }
                // Only restart when the cap actually MOVED — a restart costs a ~200ms black frame on
                // the other side, so reacting to every notification would be worse than the heat.
                guard thermalCaps.fps != appliedThermalFps else { return }
                // HOTTER steps down at once. COOLER waits 10s and must still be cooler then: a phone
                // sitting right on a thermal boundary flips state back and forth, and each flip was
                // a black frame for the other person.
                thermalStepUpWork?.cancel(); thermalStepUpWork = nil
                if thermalCaps.fps < appliedThermalFps { restartCaptureForThermal(); return }
                let w = DispatchWorkItem { [weak self] in
                    guard let self, self.cameraShouldRun, !self.cameraPausedByBackground, self.videoCapturer != nil,
                          self.thermalCaps.fps > self.appliedThermalFps else { return }
                    self.restartCaptureForThermal()
                }
                thermalStepUpWork = w
                DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: w)
        }
    }
    private var thermalStepUpWork: DispatchWorkItem?

    private func restartCaptureForThermal() {
        let front = usingFrontCamera
        // The restart re-checks after the stop completes: a toggle-off, hold or weak-link pause that
        // lands during the stop used to be overridden by this start (owner audit 2026-10-06 #14).
        videoCapturer?.stopCapture { [weak self] in self?.startCaptureIfWanted(front: front) }
    }

    // Pick the camera + a format and start feeding frames into the local track.
    private func startCapture(front: Bool) {
        // Every early return below must still end a pending front/back switch; they used to return
        // straight past the completion that does it, so the flipped-away tile never came back
        // (owner audit 2026-10-06 #14).
        let giveUp = { DispatchQueue.main.async { [weak self] in self?.resolvePendingSwitch() } }
        guard let capturer = videoCapturer else { giveUp(); return }
        let position: AVCaptureDevice.Position = front ? .front : .back
        let devices = RTCCameraVideoCapturer.captureDevices()
        guard let device = devices.first(where: { $0.position == position }) ?? devices.first else { giveUp(); return }
        // The mirror follows the camera that ACTUALLY opened: the `?? devices.first` fallback can open
        // the other one, and mirroring by the request then showed it the wrong way round.
        let liveFront = device.position == .front ? true : (device.position == .back ? false : front)
        let formats = RTCCameraVideoCapturer.supportedFormats(for: device)
        let caps = thermalCaps
        // 1:1 audit #36 (owner, 2026-10-08): many formats share the nearest height. Ties go to 16:9,
        // then to one that can reach the fps cap, instead of whichever the device listed first.
        func rank(_ f: AVCaptureDevice.Format) -> (Int, Int, Int) {
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            let wide = Int(d.width) * 9 == Int(d.height) * 16 ? 0 : 1
            let maxFps = f.videoSupportedFrameRateRanges.map { $0.maxFrameRate }.max() ?? 0
            return (abs(Int(d.height) - caps.height), wide, maxFps >= Double(caps.fps) ? 0 : 1)
        }
        let format = formats.min(by: { rank($0) < rank($1) })
        guard let format else { giveUp(); return }
        let fps = min(caps.fps, Int(format.videoSupportedFrameRateRanges.map { $0.maxFrameRate }.max() ?? 30))
        appliedThermalFps = caps.fps
        allowBackgroundCamera(on: capturer.captureSession)
        capturer.startCapture(with: device, format: format, fps: fps) { [weak self] _ in
            // 1:1 audit #12 (owner, 2026-10-08): set it again now that the session HAS its camera
            // input. Before startCapture the session has none, and `isMultitaskingCameraAccessSupported`
            // can read false there, so the call above may do nothing. On the capturer's own queue.
            self?.allowBackgroundCamera(on: capturer.captureSession)
            print("[Call] background camera access: \(capturer.captureSession.isMultitaskingCameraAccessEnabled)")
            guard let self else { return }
            DispatchQueue.main.async {
                // A front↔back switch resolves HERE: the new camera is delivering (or has failed —
                // either way the flipped-away view must come back). The mirror changes in the same
                // breath (1:1 audit #34): it used to change at dispatch, so the mini card and the
                // system PiP showed the frozen old frame re-mirrored for the restart gap.
                // 1:1 audit r2 E4, 2026-10-08: the completion fires right after startRunning, before
                // the new camera's first frame. A switch now resolves on that frame (0.8 s fallback).
                if self.pendingSwitchTarget != nil, capturer.captureSession.isRunning,
                   let track = self.localVideoTrack {
                    self.resolveSwitchOnFirstFrame(track: track, front: liveFront)
                } else {
                    self.usingFrontCamera = liveFront
                    self.resolvePendingSwitch()
                }
                // THE LAST RE-CHECK (owner audit 2026-10-06 #14). This start was decided before one or
                // more async hops; if a toggle-off, hold, weak-link pause or hang-up landed meanwhile,
                // its own stopCapture ran FIRST and this start then switched the camera back on, light
                // and all, with nothing left to turn it off. Stop it here. `capturer` is the one this
                // start used, so it is stopped even after the idle reset has dropped `videoCapturer`.
                guard self.cameraShouldRun else { capturer.stopCapture(); return }
                // Only claim video once the session is REALLY running. `cams` was published purely from
                // intent, so a start that never succeeded (most visibly a video call answered from the
                // lock screen, where the camera cannot start and no interruption is posted either) left
                // the other side staring at a BLACK full-screen video with a running timer, forever.
                // 1:1 audit r2 E1, 2026-10-08: a turn-on is announced only now, with the session up.
                let announce = self.cameraStarting
                self.cameraStarting = false
                if capturer.captureSession.isRunning {
                    if self.cameraPausedByBackground { self.resumeCameraIfReallyBack() }
                    if announce { self.broadcastCameraState() }
                } else if !self.cameraPausedByBackground {
                    self.cameraPausedByBackground = true
                    self.localVideoTrack?.isEnabled = false   // avatar, never a black rectangle
                    self.broadcastCameraState()
                    self.startPausedCameraRetry()
                }
            }
        }
        // Observed @Observable state must be written on main (this runs on a background queue).
        // The mirror (`usingFrontCamera`) is written in the completion above (1:1 audit #34).
        DispatchQueue.main.async { self.observeThermalIfNeeded() }
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
        guard cameraOn, !shareOwnsCamera, let capturer = videoCapturer else { return }
        // 1:1 audit r2 E5, 2026-10-08: a tap during a slow restart goes back to the other side. The
        // mirror flag only changes at the new camera's first frame (#34), so it still names the old one.
        let next = !(pendingSwitchTarget ?? usingFrontCamera)
        switchProbeSeq &+= 1   // r2 E4: an earlier switch's first-frame wait no longer resolves this one
        // 1:1 audit #33 (owner, 2026-10-08): camera paused (weak link, hold). Nothing to restart, so
        // just take the choice; the resume starts the side asked for. It used to be thrown away.
        guard cameraShouldRun else {
            usingFrontCamera = next
            pendingSwitchTarget = next
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.resolvePendingSwitch() }
            return
        }
        // Deliberately NOT flipping the mirror here (it used to): the frozen last frame keeps its
        // own mirroring through the restart gap; mirror and content swap together at the flip's
        // hidden midpoint, when startCapture's completion reports the new camera live.
        pendingSwitchTarget = next
        // Stop the running capture BEFORE starting the other camera — restarting a live
        // capturer in place can freeze/black the local feed on flip.
        // Re-checked after the stop (owner audit 2026-10-06 #14): a toggle-off during the flip must win.
        capturer.stopCapture { [weak self] in self?.startCaptureIfWanted(front: next) }
    }

    // MARK: - Camera (each side controls its OWN camera — no permission handshake)

    // Turn MY camera on/off. The video m-line was negotiated at call setup, so this is a pure
    // track-enable + capture start/stop — NO renegotiation. Broadcast my state so the other side
    // shows/hides my video. No prompt: I only ever share MY OWN camera, which is my choice.
    private func setMyCamera(on: Bool) {
        // Audit M-052, 2026-10-07: turning the camera OFF also works while a video call rings out.
        // Off is always safe to honour (it only stops sending); on waits for the call, as before.
        // The doc seeds `cams` from `cameraOn` when it is created, and broadcastCameraState covers
        // a doc that already exists.
        guard state == .active || state == .reconnecting || (state == .outgoing && !on) else { return }
        if on { cameraDenied = false }   // audit M-011: a new try; a refusal sets it again
        // A FALLBACK share owns the track while it runs (the camera button is disabled then; a
        // dual-mode share leaves the camera to the user). Toggling here
        // would disable the track under the share, or announce cams=false over a live screen.
        guard !shareOwnsCamera else { return }
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
        // While HELD the intent is recorded but nothing is sent; unholding starts it (owner audit
        // 2026-10-06 #1). startCameraCapture refuses on its own via cameraShouldRun.
        localVideoTrack?.isEnabled = on && !isHeld
        cameraStarting = on   // r2 E1: `cams` waits for the running session
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
    ///
    /// Audit M-010, 2026-10-07: THE ROUTE NO LONGER FOLLOWS EVERY CAMERA EVENT. It ran on every `cams`
    /// change, and the other side's camera pauses for a weak link, a background or a hold all arrive
    /// as `cams` false, so their network moved MY audio between loudspeaker and earpiece, over a
    /// choice I had just made with the speaker button. Now the speaker default is applied once per
    /// call, on the first time any video shows, and only if the person has not chosen a route
    /// themselves; a camera turning off never moves the route. The mode switch stays as it was.
    private func applyVideoAudioPolicy() {
        let session = AVAudioSession.sharedInstance()
        let videoShowing = cameraOn || remoteCameraOn
        noteVideo()   // both camera paths (mine and theirs) meet here
        // Echo cancellation follows what the audio is actually DOING, not who owns the camera:
        // .videoChat is tuned for the loudspeaker, .voiceChat for the earpiece. The wrong one is the
        // hear-your-own-voice bug.
        // 1:1 audit #2 (owner, 2026-10-08): so the MODE follows the route (updateAudioRoute), not
        // the camera. Setting .videoChat here on every camera event moved an earpiece choice back
        // to the loudspeaker (that mode defaults there) and fought updateAudioRoute's own setMode.
        // Audit M-050, 2026-10-07: no video and the sound is in a device, so a speaker intent left over
        // from the video part is stale. Kept, it put the call on the loudspeaker the moment the
        // AirPods came out. Cleared BEFORE the device guard below, which used to skip this.
        if !videoShowing, audioRoute == .external { wantsSpeaker = false }
        guard videoShowing, !videoSpeakerDefaultApplied, !speakerChosenByUser else { return }
        // An external device ALWAYS wins. Never yank audio out of someone's AirPods. Audit M-049: a
        // device that is merely connected counts too; the default waits for a later video edge.
        guard audioRoute != .external, !externalOutputAround else { return }
        videoSpeakerDefaultApplied = true
        isSpeaker = true
        wantsSpeaker = true            // survives CallKit re-activating and resetting the route
        // #2: the loudspeaker-tuned mode goes with the move, also before route observation runs.
        if session.mode != .videoChat { try? session.setMode(.videoChat) }
        try? session.overrideOutputAudioPort(.speaker)
    }

    /// Audit M-049, 2026-10-07: a headset, AirPods or car is the current output or is connected.
    /// Read live from the session, because the `.outgoing` default runs before route observation
    /// starts. Same port list as `updateAudioRoute`.
    private var externalOutputAround: Bool {
        let session = AVAudioSession.sharedInstance()
        let ports: Set<AVAudioSession.Port> = [.bluetoothHFP, .bluetoothLE, .bluetoothA2DP,
                                               .headphones, .headsetMic, .carAudio]
        return session.currentRoute.outputs.contains { ports.contains($0.portType) }
            || (session.availableInputs ?? []).contains { ports.contains($0.portType) }
    }

    // Tell the other side whether my camera is on — drives their show/hide of MY video.
    private func broadcastCameraState(attempt: Int = 0) {
        guard let id = callId else { return }
        // What we are ACTUALLY sending, not what the user asked for. A camera held down by a capture
        // interruption or a weak link is producing nothing, and announcing it as on is what leaves the
        // other side staring at a frozen face instead of falling back to the avatar. The interruption
        // path already said that was the intent in its own comment; it was still sending `cameraOn`.
        //
        // Audit M-121, 2026-10-07: NOT FIRE-AND-FORGET any more, same rule as the mute signal. A lost
        // write left the other side showing my camera wrong for the rest of the call. Retried a few
        // times while it is the same live call and the value is still the one we meant; recovery
        // from .reconnecting re-sends it too (see `state`).
        let value = camsSignal
        db.collection("calls").document(id).updateData(["cams.\(me)": value]) { [weak self] err in
            guard let self, err != nil, attempt < 3 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self, self.callId == id, self.inLiveCall, self.camsSignal == value else { return }
                self.broadcastCameraState(attempt: attempt + 1)
            }
        }
    }

    /// The `cams.<me>` value: what my video is ACTUALLY carrying. True for the length of a FALLBACK
    /// screen share (dual mode sends the screen on its own track), so the other side's existing video layout shows it; otherwise the real camera state.
    private var camsSignal: Bool {
        shareOwnsCamera || (cameraOn && !cameraStarting && !cameraPausedByBackground && !videoPausedForNetwork && !isHeld)
    }

    /// 1:1 audit r2 E1, 2026-10-08: a camera turned on (tap, or weak-link resume) is not announced
    /// until startCapture's completion sees the session running, so the other side never shows a
    /// black or stale frame as live video. Cleared there, on a turn-off, a denial and at .idle.
    private var cameraStarting = false

    // MARK: - Screen share (1:1)
    //
    // The broadcast extension (one process, shared with group calls) sends JPEG frames over a unix
    // socket in the App Group. ScreenShareSession receives them; ScreenShareCapturer feeds them into
    // the SAME video source the camera uses, so the sender, the track and the SDP never change.
    //   tap Share Screen -> listen + system picker. Pending: nothing in the call changes yet.
    //   first frame / extension "started" -> camera capturer stops, screen capturer goes live,
    //       encoder set for a screen, `screen.<me>` = true and `cams.<me>` = true signalled.
    //   Stop Sharing / socket closed / extension "stopped" / hold / call end -> extension told to
    //       stop, socket closed, camera back only if `cameraOn` (the untouched intent), encoder
    //       restored, `screen.<me>` = false and `cams.<me>` = the real camera state signalled.
    // Audio is not touched anywhere on this path: no session, mode or route change.

    /// The "..." menu's Share Screen / Stop Sharing.
    func toggleScreenShare() {
        if screenSharing { stopScreenShareByUser(); return }
        guard state == .active, connectedDate != nil else { return }
        // A group call's LiveKit room listens on the same socket path while it shares.
        guard !inGroupCall else { return }
        guard openShareSession() else { return }
        // Picker abandoned: back to off, silently (closing the sheet is not a failure).
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, !self.screenSharing else { return }
            self.stopScreenShare(requestExtensionStop: true, signal: false)   // a sheet finished after the wait must not leave the extension recording with no one listening
        }
        screenSharePendingTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: timeout)
        if !ScreenSharePicker.show() {
            stopScreenShare(requestExtensionStop: false, signal: false)
        } else {
            watchPickerReturn()
        }
    }

    /// Opens the extension link for a share (sources, capturer, session) and enters `.picking`.
    /// False if nothing could be opened. Shared by the menu and the Control Center adoption.
    private func openShareSession() -> Bool {
        // A picker opened earlier that never started a broadcast: begin again from scratch.
        stopScreenShare(requestExtensionStop: false, signal: false)
        disarmLateShareStop()   // audit M-106: this new picker's "started" must not be answered with a stop
        screenShareNotice = nil   // a new attempt; the last one's line is old news
        // Screen share v3: dual mode (both phones v3, screen m-line negotiated for sending) feeds a
        // dedicated screencast source on its own track; otherwise the camera's source, as before.
        let dual = dualModeAvailable
        let source: RTCVideoSource
        if dual {
            let s = Self.factory.videoSource(forScreenCast: true)
            screenSource = s
            screenTrack = Self.factory.videoTrack(with: s, trackId: "screen0")
            source = s
        } else {
            guard let s = videoSource else { return false }
            source = s
        }
        shareUsesTrack = dual
        print("[ScreenShare] share requested, mode \(dual ? "track" : "camera")")
        let capturer = ScreenShareCapturer(source: source)
        let session = ScreenShareSession { frame, rotation in
            capturer.push(frame, rotationDegrees: rotation)
        }
        session.onStarted = { [weak self] in self?.beginScreenShare() }
        session.onFirstFrame = { [weak self] in
            guard let self, self.screenSharing else { return }
            self.setScreenSharePhase(.live)
        }
        session.onEnded = { [weak self] reason in self?.screenShareEnded(reason) }
        guard session.start() else {   // App Group not provisioned: nothing to listen on
            shareUsesTrack = false; screenSource = nil; screenTrack = nil
            return false
        }
        screenCapturer = capturer
        screenShareSession = session
        setScreenSharePhase(.picking)
        return true
    }

    /// 1:1 audit #15 (owner, 2026-10-08): ReplayKit says nothing when the sheet is closed without
    /// Start, which left `.picking` up for the full 60 s. When the app is active again and no
    /// broadcast has started a little later, the sheet was closed: end the pending share. The wait
    /// covers the sheet's 3-2-1 countdown (Start tapped, sheet closed before it ran out); a start
    /// that still lands after it is stopped by the late-start guard, as with the 60 s net.
    private func watchPickerReturn() {
        clearPickerReturn()
        guard let pending = screenShareSession else { return }
        screenSharePickerReturn = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self, weak pending] _ in
            self?.clearPickerReturn()
            // 1:1 audit check, 2026-10-08: 6 s covers the 3-2-1 countdown plus the extension's
            // launch; a broadcast already stamping its keepalive is never stopped here.
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self, weak session = pending] in
                guard let self, let session, self.screenShareSession === session,
                      !self.screenSharing, !session.hasStarted,
                      self.screenSharePhase == .picking else { return }
                session.extensionKeepaliveFresh { [weak self, weak session] fresh in
                    guard !fresh, let self, let session, self.screenShareSession === session,
                          !self.screenSharing, !session.hasStarted,
                          self.screenSharePhase == .picking else { return }
                    print("[Call] screen share sheet closed without a start")
                    self.stopScreenShare(requestExtensionStop: true, signal: false)
                }
            }
        }
    }

    private func clearPickerReturn() {
        if let token = screenSharePickerReturn { NotificationCenter.default.removeObserver(token) }
        screenSharePickerReturn = nil
    }

    /// 1:1 audit #37 (owner, 2026-10-08): a broadcast started from Control Center's Screen
    /// Recording menu during a live 1:1 call used to end at once ("The call has ended") because no
    /// session was stamping `appAliveNs`. Now it is adopted as a share: the session opens on the
    /// "started" notification and the first frame begins the share as usual. The extension gives
    /// the app a few seconds to do this (SampleHandler). Not for a share we just abandoned (the
    /// late-start guard stops that one) nor in a group call. Idempotent; call once at launch.
    func installShareAdoption() {
        guard shareAdoption == nil else { return }
        shareAdoption = KSDarwinNotificationCenter.shared.publisher(for: .broadcastStarted)
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self, self.state == .active, self.connectedDate != nil,
                          !self.inGroupCall, self.lateShareStop == nil,
                          self.screenShareSession == nil, !self.screenSharing else { return }
                    print("[Call] adopting a screen share started outside the app")
                    guard self.openShareSession() else { return }
                    // Begins the share now; the session's 10 s first-frame wait is the net.
                    self.screenShareSession?.adoptRunningBroadcast()
                }
            }
    }

    /// The broadcast is really running: switch the call's video from the camera to the screen.
    private func beginScreenShare() {
        guard !screenSharing, let capturer = screenCapturer, screenShareSession != nil else { return }
        // Started into a call that cannot carry it (put on hold, or already ending): end it again.
        guard state == .active || state == .reconnecting, !isHeld else { stopScreenShare(); return }
        screenSharePendingTimeout?.cancel(); screenSharePendingTimeout = nil
        clearPickerReturn()
        // Dual mode: the screen track goes onto the screen transceiver's sender. A track swap, no
        // renegotiation: the m-line was negotiated at setup.
        var screenSender: RTCRtpSender?
        if shareUsesTrack {
            guard let pc, let sender = screenTransceiver(in: pc)?.sender, let track = screenTrack else {
                print("[ScreenShare] dual mode lost its screen sender before the start")
                stopScreenShare(notice: "Couldn't start screen sharing")
                return
            }
            screenSender = sender
            sender.track = track
        }
        screenSharing = true
        setScreenSharePhase(.starting)   // .live once the first frame is decoded (onFirstFrame)
        if screenSender != nil {
            // Dual mode: the camera keeps running exactly as the user had it.
            capturer.setLive(true)
        } else {
            // Camera FIRST, screen second (the reference order): the camera capturer stops, and only
            // then does the screen capturer go live on the same source, so no camera frame lands
            // between screen frames. `cameraOn` is untouched; it is what the stop path restores.
            if let camera = videoCapturer {
                camera.stopCapture { capturer.setLive(true) }
            } else {
                capturer.setLive(true)
            }
            localVideoTrack?.isEnabled = true   // a voice call's track is disabled until now
        }
        // The shared app's sound rides in my mic track while I share (both modes).
        ScreenShareAudioMixer.shared.isMixing = true
        shareQuality.reset(); shareLastSent = nil   // each share starts at the top tier
        applyShareTier()
        broadcastScreenState()
        updateInCallScreenBehavior()
    }

    /// Ends a running share, or abandons a pending one. Idempotent; safe from every exit path.
    /// - requestExtensionStop: ask the extension to finish (ends the system's red indicator).
    /// - signal: write `screen`/`cams` to the call doc and bring the camera back. False once the call
    ///   is over (finishCall runs this before the state reaches .ended, so `cameraShouldRun` would
    ///   still say yes and start a camera nobody will see).
    /// - notice: the line for the call screen when the user did NOT press Stop. Only shown if there
    ///   was a share (or a pending one) to end.
    func stopScreenShare(requestExtensionStop: Bool = true, signal: Bool = true, notice: String? = nil) {
        screenSharePendingTimeout?.cancel(); screenSharePendingTimeout = nil
        clearPickerReturn()
        let hadShare = screenShareSession != nil || screenSharing
        let pendingOnly = screenShareSession != nil && !screenSharing
        screenShareSession?.stop(); screenShareSession = nil
        screenCapturer?.stop(); screenCapturer = nil
        ScreenShareAudioMixer.shared.isMixing = false
        // Dual mode: take the screen off its sender (no renegotiation) and release it.
        let wasTrack = shareUsesTrack
        if wasTrack, let pc, let sender = screenTransceiver(in: pc)?.sender, sender.track != nil {
            sender.track = nil
        }
        screenSource = nil; screenTrack = nil
        setScreenSharePhase(.off)   // every exit converges here, whatever the order
        if let notice, hadShare { screenShareNotice = notice }
        if requestExtensionStop, hadShare {
            KSDarwinNotificationCenter.shared.postNotification(.broadcastRequestStop)
        }
        // Audit M-106: a picker abandoned before its broadcast began can still start one afterwards
        // (the sheet finished after the call ended, or after the 60s wait), and the stop posted just
        // now went out before that extension was listening.
        if requestExtensionStop, pendingOnly { armLateShareStop() }
        guard screenSharing else { shareUsesTrack = false; return }
        screenSharing = false
        shareQuality.reset(); shareLastSent = nil
        applyScreenShareEncoding(false, track: wasTrack)
        shareUsesTrack = false
        if wasTrack {
            // Dual mode only touched the camera on the ladder's bottom tier: bring that back, unless
            // the call is ending (signal false: the state is not .ended yet, see above).
            if signal { applyCameraShareTierPause() } else { cameraPausedForShareTier = false }
            if signal { broadcastScreenState() }
            updateInCallScreenBehavior()
            return
        }
        // The camera comes back only if it was on before the share and nothing else holds it now
        // (hold, weak link, call ending). An interrupted camera is left to its own retry, which
        // re-enables the track once the session is really running.
        let restoreCamera = signal && cameraShouldRun
        localVideoTrack?.isEnabled = restoreCamera && !cameraPausedByBackground
        if restoreCamera { startCameraCapture() }
        // My own feed was fullscreen and there is no camera to show in it now: normal layout.
        if !cameraOn, isLocalExpanded { isLocalExpanded = false }
        if signal { broadcastScreenState() }
        updateInCallScreenBehavior()
    }

    /// The in-app Stop: the pill, the menu, any phase. The user's own choice, so no notice. A share
    /// still in the picker or waiting for its first frame is cancelled the same way (session and
    /// pending wait torn down, the extension told to stop, the late-start guard armed).
    func stopScreenShareByUser() {
        stopScreenShare()
    }

    func clearScreenShareNotice() {
        screenShareNotice = nil
    }

    /// The extension's side ended on its own. What the user is told depends on how far it got:
    /// still in the picker says nothing (closing the sheet is not a failure), never reaching the
    /// first frame is a failed start, and anything after that is a share that stopped.
    private func screenShareEnded(_ reason: ScreenShareSession.EndReason) {
        let notice: String?
        if screenSharePhase == .picking {
            notice = nil
        } else if reason == .noFirstFrame || screenSharePhase == .starting {
            notice = "Couldn't start screen sharing"
        } else {
            notice = "Screen sharing stopped"
        }
        stopScreenShare(notice: notice)
    }

    /// The one place `screenSharePhase` changes. A call that is gone has no share, whatever order the
    /// extension's callbacks land in, so anything but `.off` is refused once the call is over.
    private func setScreenSharePhase(_ phase: ScreenSharePhase) {
        let next: ScreenSharePhase = inLiveCall ? phase : .off
        if next != .live { shareLastSent = nil }
        if next == .off, screenShareLink != .good { screenShareLink = .good }
        guard screenSharePhase != next else { return }
        screenSharePhase = next
    }

    /// Puts the ladder's current tier on the encoder, the capturer and the receive gate (no point
    /// decoding frames the encoder will drop), and on `screenShareLink` for the call screen.
    private func applyShareTier() {
        applyScreenShareEncoding(true)
        applyCameraShareTierPause()
        screenCapturer?.setMaxFramerate(shareFramerate)
        screenShareSession?.setMaxFramerate(shareFramerate)
        let link: ScreenShareLink
        switch shareQuality.index {
        case 0, 1: link = .good
        case 2: link = .constrained
        default: link = .poor
        }
        if screenShareLink != link { screenShareLink = link }
    }

    /// Dual mode: on the ladder's bottom tier the camera stops (track disabled, capture stopped, the
    /// peer told through broadcastCameraState so they see the avatar, not a frozen face), using the
    /// weak-link pause. Back when the tier rises or the share ends. A camera the link monitor had
    /// already paused is left to it.
    private func applyCameraShareTierPause() {
        let wantPaused = screenSharing && shareUsesTrack
            && shareQuality.index >= ScreenShareQuality.tiers.count - 1
        if wantPaused {
            guard !cameraPausedForShareTier, !videoPausedForNetwork, !isHeld else { return }
            pauseVideoForWeakLink()
            if videoPausedForNetwork { cameraPausedForShareTier = true }
        } else if cameraPausedForShareTier {
            cameraPausedForShareTier = false
            resumeVideoAfterWeakLink()
        }
    }

    /// Audit M-106, 2026-10-07: for 60s after a pending share was abandoned, a "broadcast started"
    /// from the extension is answered with a stop request, so a broadcast nobody listens to does not
    /// keep recording with the red indicator up. Not while a new 1:1 share is pending or running
    /// (toggleScreenShare disarms it), and not during a group call, whose share uses the same
    /// extension notifications.
    private func armLateShareStop() {
        lateShareStopExpiry?.cancel()
        lateShareStop = KSDarwinNotificationCenter.shared.publisher(for: .broadcastStarted)
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self, self.lateShareStop != nil, self.screenShareSession == nil,
                          !self.inGroupCall else { return }
                    KSDarwinNotificationCenter.shared.postNotification(.broadcastRequestStop)
                    // Also the shared stop flag, as ScreenShareSession.stop() sets it: an extension
                    // that missed the notification still reads the flag and finishes.
                    ScreenShareIPC.Control()?.requestStop()
                }
            }
        let expiry = DispatchWorkItem { [weak self] in self?.disarmLateShareStop() }
        lateShareStopExpiry = expiry
        DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: expiry)
    }

    private func disarmLateShareStop() {
        lateShareStopExpiry?.cancel(); lateShareStopExpiry = nil
        lateShareStop?.cancel(); lateShareStop = nil
    }

    /// Encoder settings for a screen, and back. A screen keeps its RESOLUTION when the link is weak
    /// (text stays readable, the frame rate drops instead) and takes the ladder's current tier
    /// (ScreenShareQuality: 2.5 Mbps / 30 fps at best). Use Less Data never scales it down; only the
    /// ladder's last tier does. Stopping returns the camera's own settings.
    /// Dual mode (`track`, default `shareUsesTrack`): the tier goes on the SCREEN sender only, and the
    /// camera sender, which keeps running, follows the screen's tier so the screen gets the link
    /// first (the reference app's priority): T0/T1 300 kbps / 15 fps / half size, T2 150 kbps /
    /// 10 fps / third size, T3 paused (applyCameraShareTierPause). The screen also wins the
    /// encoder's bitrate split (priority 4.0 against the camera's 0.5). Both are put back on stop.
    private func applyScreenShareEncoding(_ on: Bool, track: Bool? = nil) {
        guard let pc else { return }
        if track ?? shareUsesTrack {
            if let screen = screenTransceiver(in: pc)?.sender {
                setShareEncoding(on, to: screen, priority: on ? 4.0 : 1.0)
            }
            if let camera = cameraTransceiver(in: pc)?.sender {
                let low = shareQuality.index >= 2
                let params = camera.parameters
                for enc in params.encodings {
                    if on {
                        enc.maxBitrateBps = NSNumber(value: low ? 150_000 : 300_000)
                        enc.maxFramerate = NSNumber(value: low ? 10 : 15)
                        enc.scaleResolutionDownBy = NSNumber(value: low ? 3.0 : 2.0)
                        enc.bitratePriority = 0.5
                    } else {
                        enc.maxFramerate = nil
                        enc.scaleResolutionDownBy = nil
                        enc.bitratePriority = 1.0
                    }
                }
                camera.parameters = params
            }
        } else {
            for sender in pc.senders where sender.track?.kind == "video" { setShareEncoding(on, to: sender) }
        }
        if !on { applyDataSaver(to: pc) }   // the camera's cap, or Use Less Data, exactly as before
    }

    /// The ladder's tier on one sender (on), or the plain camera settings back (off).
    /// `priority`: the encoding's bitratePriority (dual mode only; nil leaves it as it is).
    private func setShareEncoding(_ on: Bool, to sender: RTCRtpSender, priority: Double? = nil) {
        let tier = shareQuality.tier
        let params = sender.parameters
        let preference: RTCDegradationPreference = on ? .maintainResolution : .balanced
        params.degradationPreference = NSNumber(value: preference.rawValue)
        for enc in params.encodings {
            if let priority { enc.bitratePriority = priority }
            if on {
                enc.maxBitrateBps = NSNumber(value: tier.maxBitrate)
                enc.maxFramerate = NSNumber(value: shareFramerate)
                enc.scaleResolutionDownBy = tier.scaleDown > 1 ? NSNumber(value: tier.scaleDown) : nil
            } else {
                enc.maxFramerate = nil
                enc.scaleResolutionDownBy = nil
            }
        }
        sender.parameters = params
    }

    /// The share's frame rate for the current tier. Screen share v3 runs the top tier at 30 fps
    /// (the extension paces to 30); ScreenShareQuality's own T0 value is used when it is higher.
    private var shareFramerate: Int {
        let fps = shareQuality.tier.maxFramerate
        return shareQuality.index == 0 ? max(30, fps) : fps
    }

    /// Tell the other side my screen is (or is no longer) what my video carries, together with the
    /// `cams` value that goes with it, in ONE write so they never see one without the other. Retried
    /// like the mute signal: a lost write would leave them cropping a screen, or fitting a face.
    private func broadcastScreenState(attempt: Int = 0) {
        guard let id = callId else { return }
        let sharing = screenSharing
        var fields: [String: Any] = [
            "screen.\(me)": sharing,
            "cams.\(me)": camsSignal
        ]
        // Screen share v3: how the share is carried, in the same write as `screen` so the viewer
        // never picks the wrong track. Old builds ignore it.
        if sharing { fields["screenMode.\(me)"] = shareUsesTrack ? "track" : "camera" }
        db.collection("calls").document(id).updateData(fields) { [weak self] err in
            guard let self, err != nil, attempt < 3 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self, self.callId == id, self.inLiveCall, self.screenSharing == sharing else { return }
                self.broadcastScreenState(attempt: attempt + 1)
            }
        }
    }

    // MARK: - Screen behavior during calls
    // Voice call held to the ear → PROXIMITY sensor blanks the screen (no cheek-mutes/hangups).
    // Video showing (either side) → screen NEVER dims/locks (SleepBlocker) and proximity stays OFF.
    func updateInCallScreenBehavior() {
        let inCall = state == .active || state == .reconnecting
        // A share counts as video here (keep-awake, no proximity blanking), unlike in the audio policy.
        let videoShowing = cameraOn || remoteCameraOn || screenSharing || remoteScreenSharing
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
        // Not during a share: the camera is stopped then, and disabling the track would cut the screen.
        guard inLiveCall, cameraOn, !cameraPausedByBackground, !shareOwnsCamera else { return }
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
        // intent instead of blindly restoring. cameraShouldRun, not just cameraOn: the foreground
        // backstop used to restart a camera stopped for a weak link or a hold (owner audit 2026-10-06 #14).
        guard cameraShouldRun, let session = videoCapturer?.captureSession else { return }
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
    /// 1:1 audit #29 (owner, 2026-10-08): when this side last saw the path move (a network change, a
    /// drop into Reconnecting, a recovery), and when the weak-link check itself paused the camera.
    private var linkTransitionAt: Date?
    private var weakLinkPausedAt: Date?
    /// 1:1 audit r2 F2, 2026-10-08: a REAL move only (path change, recovery from Reconnecting).
    /// A grace blip stamps `linkTransitionAt` but must not force paused video back on.
    private var linkMovedAt: Date?

    // MARK: - Who is actually talking
    //
    // OWNER, 2026-08-23: the wave on the card must appear only while that person is TALKING. It was a
    // permanent mute light before ("green mic on / grey mic off"), which is a different thing and it
    // sat there for the whole call saying nothing.
    //
    // Group calls get speaking flags for free from their engine (`p.isSpeaking`). A 1:1 call is raw
    // WebRTC and hands us nothing, so it is read out of the connection's own statistics: `audioLevel`
    // on the incoming audio stream is them, `audioLevel` on the local media source is me.
    //
    // ⚠️ IT ONLY RUNS WHILE THE MINIMIZED CARD IS UP, because the card is the only thing that reads
    // these two flags. A stats sweep three times a second for the length of a whole call is heat, and
    // heat on this call path has already been tuned carefully (the thermal caps). Starting with
    // `minimized` and stopping with it keeps the cost where the value is — put a talking indicator on
    // the full call screen one day and this gate is the line to change, deliberately.
    var remoteSpeaking = false
    var localSpeaking = false

    /// HOW LOUD, not just whether — 0…1, smoothed, and what the wave around each face is drawn from.
    ///
    /// Everyone else's talking indicator is a BOOLEAN: their ring switches on and sits there. We
    /// already sample the real level to decide `speaking` at all, so throwing the number away and
    /// keeping only the yes/no was wasting the one thing that makes our version impossible to copy
    /// without doing the same work.
    ///
    /// Measured ABOVE THE ROOM'S OWN FLOOR, so it means the same thing in a quiet bedroom and a loud
    /// kitchen: 0 is the background, 1 is a good clear voice over it. A raw level would just read
    /// "this room is noisy" and the ring would sit half-open all call.
    var remoteLevel: Double = 0
    var localLevel: Double = 0
    private var voiceMonitor: Timer?
    private var remoteQuietSince: Date?
    private var localQuietSince: Date?
    /// ⛔ A FIXED THRESHOLD CALLED A FRIDGE A VOICE. It was a flat 0.02, and `audioLevel` is raw
    /// LOUDNESS — it cannot tell a person from a fan, a television or wind on a microphone. In an
    /// ordinary room the background clears 0.02 on its own, so the mark lit up with nobody speaking
    /// (owner, 2026-08-23: "some times flag sound with out sound, what sound we trach?").
    ///
    /// Two numbers replace it. Nothing under `hardFloor` is ever speech, whatever the room is doing;
    /// above that, a sound has to rise `voiceGap` clear of THAT ROOM'S OWN background, which each
    /// side learns for itself while nobody is talking. A noisy kitchen then needs a louder voice and
    /// a silent bedroom stays sensitive, without either being tuned by hand.
    ///
    /// It cannot fix a television playing speech. That genuinely is a voice, and no level-based test
    /// will ever say otherwise — iOS gives us no voice detection to read, so this is the honest
    /// ceiling rather than a shortcut.
    private static let hardFloor = 0.015
    private static let voiceGap = 0.04

    /// Each side's learned background. Not shared: the two people are in different rooms, which is
    /// the entire reason a single fixed number could never fit both of them.
    private var remoteFloor = 0.0
    private var localFloor = 0.0
    /// Falling silent only counts after this long. Without it the badge strobes in the gaps between
    /// two words, which reads as broken rather than as live.
    private static let speakingHold: TimeInterval = 0.6

    func startVoiceMonitor() {
        guard voiceMonitor == nil, state == .active, minimized else { return }
        // 1:1 audit r2 J3, 2026-10-08: not in the background; didBecomeActive starts it again.
        guard UIApplication.shared.applicationState != .background else { return }
        voiceMonitor = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            self?.sampleVoiceLevels()
        }
    }

    /// 1:1 audit r2 J3, 2026-10-08: stops the poll but keeps the learned floors for this call.
    private func pauseVoiceMonitor() {
        guard voiceMonitor != nil else { return }
        voiceMonitor?.invalidate(); voiceMonitor = nil
        remoteQuietSince = nil; localQuietSince = nil
        remoteSpeaking = false; localSpeaking = false
        remoteLevel = 0; localLevel = 0
    }

    func stopVoiceMonitor() {
        voiceMonitor?.invalidate(); voiceMonitor = nil
        remoteQuietSince = nil; localQuietSince = nil
        // The next call is in a different room; a floor learned in this one would be a lie there.
        remoteFloor = 0; localFloor = 0
        remoteSpeaking = false; localSpeaking = false
        remoteLevel = 0; localLevel = 0
    }

    private func sampleVoiceLevels() {
        guard state == .active, minimized, let pc else { stopVoiceMonitor(); return }
        pc.statistics { [weak self] report in
            var remote = 0.0
            var local = 0.0
            for s in report.statistics.values {
                guard (s.values["kind"] as? String) == "audio",
                      let level = (s.values["audioLevel"] as? NSNumber)?.doubleValue else { continue }
                switch s.type {
                case "inbound-rtp":  remote = max(remote, level)
                case "media-source": local = max(local, level)
                // Older report shape, kept as a fallback: some builds carry the levels on `track`
                // entries instead, and without this branch the badge would simply never appear —
                // a silent nothing-happens that is very hard to tell from "nobody is talking".
                case "track":
                    if (s.values["remoteSource"] as? NSNumber)?.boolValue == true { remote = max(remote, level) }
                    else { local = max(local, level) }
                default: break
                }
            }
            DispatchQueue.main.async { self?.applyVoiceLevels(remote: remote, local: local) }
        }
    }

    private func applyVoiceLevels(remote: Double, local: Double) {
        guard state == .active else { return }
        remoteSpeaking = speakingNow(level: remote, micLive: !remoteMuted, floor: &remoteFloor,
                                     quietSince: &remoteQuietSince, was: remoteSpeaking)
        localSpeaking = speakingNow(level: local, micLive: !isMuted, floor: &localFloor,
                                    quietSince: &localQuietSince, was: localSpeaking)
        remoteLevel = loudness(remote, floor: remoteFloor, speaking: remoteSpeaking, was: remoteLevel)
        localLevel = loudness(local, floor: localFloor, speaking: localSpeaking, was: localLevel)
    }

    /// Above the threshold turns it on immediately; below it turns off only once the hold has run out.
    /// A muted mic is never talking whatever the numbers say — that is the one case where the level
    /// and the truth can disagree.
    /// The 0…1 the wave is drawn from. Zero whenever the person is not talking, so the ring closes
    /// completely in the gaps rather than hovering at some resting size.
    ///
    /// ⚠️ ASYMMETRIC SMOOTHING, and it is the difference between a voice and a strobe. Samples land
    /// every 0.3s, which is far slower than speech moves, so following them exactly would make the
    /// ring jump in steps. Rising fast keeps the ring on the front of each word — a slow attack
    /// reads as lag. Falling slow rides through the gaps between syllables, which are shorter than
    /// one sample and would otherwise punch a hole in the middle of every word.
    private func loudness(_ level: Double, floor: Double, speaking: Bool, was: Double) -> Double {
        guard speaking else { return was * 0.45 }   // ease shut rather than snap to nothing
        // Above the floor, scaled so an ordinary speaking voice reaches most of the way to 1.
        let over = max(0, level - floor) / 0.16
        let target = min(1, over)
        return target > was ? was + (target - was) * 0.65 : was + (target - was) * 0.28
    }

    private func speakingNow(level: Double, micLive: Bool, floor: inout Double,
                             quietSince: inout Date?, was: Bool) -> Bool {
        // A muted mic is never talking, and its silence must NOT teach the floor — otherwise the
        // background it learned while muted is zero, and the first noisy second after unmuting reads
        // as a voice.
        guard micLive else { quietSince = nil; return false }

        // ⚠️ THE GAP SHRINKS IN A QUIET ROOM (owner audit 2026-10-06 #35). A flat `floor + voiceGap`
        // is never below 0.04, so `hardFloor` could never act and a soft-spoken person under 0.04
        // was never detected; their own voice then taught the floor and lifted the bar further.
        // The gap now scales with the background (twice the floor, at least 0.01) and caps at
        // `voiceGap`: a silent room bottoms out at `hardFloor` as the comment above promises, and a
        // room with a floor of 0.02 or more gets exactly the old threshold.
        let gap = min(Self.voiceGap, max(0.01, floor * 2))
        let threshold = max(Self.hardFloor, floor + gap)
        let loud = level >= threshold

        // ⚠️ THE FLOOR TRACKS THE BACKGROUND, NOT THE SOUND. It learns quickly from the moments
        // nobody is talking and barely moves while somebody is, because a floor that chased speech
        // would climb into the voice and then need a shout to clear itself. The slow rate is not
        // zero on purpose: a room that gets permanently louder mid-call still gets followed, it just
        // takes a few seconds rather than a few frames.
        floor += (level - floor) * (loud ? 0.01 : 0.25)
        // A ceiling, so one blast of feedback cannot deafen the detector for the rest of the call.
        floor = max(0, min(floor, 0.35))

        if loud { quietSince = nil; return true }
        guard was else { return false }
        let start = quietSince ?? Date()
        quietSince = start
        return Date().timeIntervalSince(start) < Self.speakingHold
    }

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
        linkTransitionAt = nil; weakLinkPausedAt = nil   // 1:1 audit #29
        linkMovedAt = nil   // 1:1 audit r2 F2
    }

    private func sampleLinkQuality() {
        guard inLiveCall, let pc else { stopLinkMonitor(); return }
        // Only meaningful while we are trying to send video at all. A voice call has nothing to pause,
        // and leaving the windows running would carry a stale verdict into the next camera-on.
        // A screen share is never paused for the link. Its encoder keeps the resolution and drops
        // frame rate instead (maintainResolution), and the camera's windows start fresh when the
        // camera comes back.
        // Audit M-107, 2026-10-07: a share is still never PAUSED, but it is watched now. A share at
        // full rate on a weak link could starve the voice; it walks down the quality ladder instead
        // (owner, 2026-10-08: sampleShareQuality).
        guard cameraOn || screenSharing else { linkPolicy.reset(); return }
        if screenSharing { linkPolicy.reset(); sampleShareQuality(pc); return }
        pc.statistics { [weak self, weak pc] report in
            // The ACTIVE pair's estimate. This is what WebRTC's own congestion controller concluded, so
            // it already folds in loss and round-trip time; a separate packet-loss rule bolted on top
            // would only add noise and a second thing to tune.
            // 1:1 audit #29 (owner, 2026-10-08): the pair the transport actually selected. The max
            // over every succeeded pair could read the dying old path during a network move.
            let stats = report.statistics.values
            let selectedId = stats.first { $0.type == "transport" }?.values["selectedCandidatePairId"] as? String
            let selected = selectedId.flatMap { id in stats.first { $0.type == "candidate-pair" && $0.id == id } }
            let bitrate = selected.flatMap { ($0.values["availableOutgoingBitrate"] as? NSNumber)?.doubleValue }
                ?? stats
                .filter { $0.type == "candidate-pair" && ($0.values["state"] as? String) == "succeeded" }
                .compactMap { ($0.values["availableOutgoingBitrate"] as? NSNumber)?.doubleValue }
                .max()
            DispatchQueue.main.async { self?.applyLinkQuality(bitrate, from: pc) }
        }
    }

    private func applyLinkQuality(_ bitrate: Double?, from source: RTCPeerConnection?) {
        // 1:1 audit check, 2026-10-08: a read from the last call's connection is dropped.
        guard inLiveCall, let source, source === pc else { return }
        // A share has its own ladder (sampleShareQuality); the camera's windows start fresh when it
        // comes back. This only catches a camera read that landed after the share began.
        if screenSharing { linkPolicy.reset(); return }
        guard cameraOn else { return }
        // HOLD OWNS THE PAUSE while it lasts (owner audit 2026-10-06 #1). Hold reuses the weak-link
        // pause flag, so a HEALTHY link read ten seconds into a phone call came back as .resume and
        // put the camera back on mid-call. Stay out of it, and start the windows fresh on unhold.
        guard !isHeld else { linkPolicy.reset(); return }
        // 1:1 audit #29 (owner, 2026-10-08): no verdict while the path is moving. During a
        // reconnect, a restart in flight, or the 8s after a network change, a low estimate is the
        // old path dying, not the new one being weak. And a pause decided before such a move is
        // stale once the move is over: video comes back and the new path is judged on its own.
        let now = Date()
        let moving = state == .reconnecting
            || restartInFlightAt.map { now.timeIntervalSince($0) < 10 } == true
            || linkTransitionAt.map { now.timeIntervalSince($0) < 8 } == true
        if moving, !videoPausedForNetwork { linkPolicy.reset(); return }
        // 1:1 audit r2 F2, 2026-10-08: only a real move (`linkMovedAt`) brings video back here.
        if !moving, videoPausedForNetwork, let p = weakLinkPausedAt, let t = linkMovedAt, t > p {
            weakLinkPausedAt = nil
            linkPolicy.reset()
            resumeVideoAfterWeakLink()
            return
        }
        switch linkPolicy.evaluate(bitrate: bitrate, paused: videoPausedForNetwork, now: now) {
        case .pause:
            pauseVideoForWeakLink()
            if videoPausedForNetwork { weakLinkPausedAt = now }
        case .resume:
            weakLinkPausedAt = nil
            resumeVideoAfterWeakLink()
        case .none:   break
        }
    }

    /// Owner, 2026-10-08: the share adapts to the link instead of one fixed cap. Every 2s (the link
    /// monitor's tick) one stats read feeds ScreenShareQuality: the active pair's available bitrate,
    /// the video sender's real send rate and WebRTC's own "limited by bandwidth" verdict, and the far
    /// side's loss and round-trip time from its receiver reports. Lowered, never ended: a share on a
    /// bad link still shows the screen, at a lower frame rate first.
    private func sampleShareQuality(_ pc: RTCPeerConnection) {
        // Dual mode: only the screen's outbound stream counts (the capped camera runs beside it).
        let dual = shareUsesTrack
        let screenMid: String? = dual ? screenTransceiver(in: pc)?.mid : nil
        pc.statistics { [weak self] report in
            var available: Double?
            var bytesSent: Double?
            var loss: Double?
            var rtt: Double?
            var limited = false
            // Dual mode: the screen's own outbound-rtp ids (by mid, else by its media source's
            // track id "screen0"), so the far side's loss/RTT is read for the screen stream, not
            // the camera's. Nothing matched: every video report counts, as before.
            var screenOutboundIds = Set<String>()
            var screenMatched = false
            var anyLoss: Double?
            var anyRtt: Double?
            if dual {
                let screenSourceIds = Set(report.statistics.values
                    .filter { $0.type == "media-source" && ($0.values["trackIdentifier"] as? String) == "screen0" }
                    .map { $0.id })
                for stat in report.statistics.values where stat.type == "outbound-rtp" {
                    let v = stat.values
                    if let want = screenMid, !want.isEmpty, let mid = v["mid"] as? String {
                        if mid == want { screenOutboundIds.insert(stat.id) }
                    } else if let src = v["mediaSourceId"] as? String, screenSourceIds.contains(src) {
                        screenOutboundIds.insert(stat.id)
                    } else if (v["trackIdentifier"] as? String) == "screen0" {
                        screenOutboundIds.insert(stat.id)
                    }
                }
            }
            for stat in report.statistics.values {
                let v = stat.values
                let kind = (v["kind"] as? String) ?? (v["mediaType"] as? String)
                switch stat.type {
                case "candidate-pair":
                    guard (v["state"] as? String) == "succeeded",
                          let b = (v["availableOutgoingBitrate"] as? NSNumber)?.doubleValue else { continue }
                    available = max(available ?? 0, b)
                case "outbound-rtp" where kind == "video":
                    if !screenOutboundIds.isEmpty {
                        if !screenOutboundIds.contains(stat.id) { continue }
                    } else if let want = screenMid, !want.isEmpty, let mid = v["mid"] as? String, mid != want { continue }
                    if let b = (v["bytesSent"] as? NSNumber)?.doubleValue { bytesSent = (bytesSent ?? 0) + b }
                    if (v["qualityLimitationReason"] as? String) == "bandwidth" { limited = true }
                case "remote-inbound-rtp" where kind == "video":
                    let f = (v["fractionLost"] as? NSNumber)?.doubleValue
                    let r = (v["roundTripTime"] as? NSNumber)?.doubleValue
                    if let f { anyLoss = max(anyLoss ?? 0, f) }
                    if let r { anyRtt = max(anyRtt ?? 0, r) }
                    if let local = v["localId"] as? String, screenOutboundIds.contains(local) {
                        screenMatched = true
                        if let f { loss = max(loss ?? 0, f) }
                        if let r { rtt = max(rtt ?? 0, r) }
                    }
                default:
                    break
                }
            }
            if !screenMatched { loss = anyLoss; rtt = anyRtt }   // no screen report found: as before
            let sample = ScreenShareQuality.Sample(availableBitrate: available, sendBitrate: nil,
                                                   fractionLost: loss, roundTripTime: rtt,
                                                   bandwidthLimited: limited)
            let sent = bytesSent
            DispatchQueue.main.async { self?.applyShareSample(sample, bytesSent: sent) }
        }
    }

    /// Main. Only while frames are flowing: a share still starting has nothing to measure.
    private func applyShareSample(_ sample: ScreenShareQuality.Sample, bytesSent: Double?) {
        guard inLiveCall, screenSharePhase == .live else { shareLastSent = nil; return }
        let now = Date()
        var sample = sample
        if let bytesSent, let last = shareLastSent, bytesSent >= last.bytes {
            let elapsed = now.timeIntervalSince(last.at)
            if elapsed > 0.5 { sample.sendBitrate = (bytesSent - last.bytes) * 8 / elapsed }
        }
        shareLastSent = bytesSent.map { (bytes: $0, at: now) }
        if shareQuality.evaluate(sample) { applyShareTier() }
    }

    private func pauseVideoForWeakLink() {
        // A camera already down for a capture interruption is not ours to take over; that path owns
        // its own resume and would fight us for it.
        // Never under a share that owns the camera (fallback): that would disable the track carrying
        // the screen. A dual-mode share has its own track, so the camera pauses here as usual. (Hold
        // stops the share BEFORE calling in here, so a held call still pauses the camera as before.)
        guard cameraOn, !cameraPausedByBackground, !shareOwnsCamera else { return }
        videoPausedForNetwork = true
        localVideoTrack?.isEnabled = false
        videoCapturer?.stopCapture()   // stop paying for frames the link cannot carry
        broadcastCameraState()         // they get the avatar, not a frozen face
        updateInCallScreenBehavior()
    }

    private func resumeVideoAfterWeakLink() {
        // Never while held, whoever asks (owner audit 2026-10-06 #1). The flag stays up, so the
        // paused state stays true until setHeld(false) lowers isHeld and calls back in here.
        guard !isHeld else { return }
        videoPausedForNetwork = false
        // Re-check intent rather than blindly restoring: the user may have hung up, or turned the
        // camera off themselves, during the ten seconds we spent deciding the link was healthy.
        guard inLiveCall, cameraOn, !cameraPausedByBackground, !shareOwnsCamera else { return }
        localVideoTrack?.isEnabled = true
        // 1:1 audit r2 E1, 2026-10-08: `cams` goes true from startCapture's completion, once the
        // session runs, not on this turn (the other side showed a frozen or black frame).
        cameraStarting = true
        startCameraCapture()
        updateInCallScreenBehavior()
    }

    // Backstop only. If an interruption ended without its notification (or one never fired), returning
    // to the foreground must never leave the camera dark while the intent says it is on. Note it does
    // NOT force the flag first: resumeCameraIfReallyBack decides from the session, so a still-interrupted
    // session correctly does nothing here rather than announcing video that does not exist.
    func appWillEnterForeground() {
        resumeCameraIfReallyBack()
        // A share keeps running in the background. Coming back, make sure its extension is really
        // still there; a socket that died while we were suspended ends it now, with the notice.
        screenShareSession?.checkLiveness()
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
        // Their screen share. Read BEFORE `cams`: the sharer writes both in one update, and the cams
        // change it brings must not be taken for a camera (see the audio policy skip below). A
        // missing key under an existing map means "not sharing" (the map may only hold my own key).
        // Screen share v3: their capability, and how their share is carried. Old builds write
        // neither: no caps = fallback for my shares, no screenMode = their share is on their camera.
        if let caps = d["caps"] as? [String: Any], let theirs = caps[otherUid] as? [String] {
            let v3 = theirs.contains(Self.screenCap)
            if v3 != peerHasScreen2 { peerHasScreen2 = v3 }
        }
        if let modes = d["screenMode"] as? [String: String], let mode = modes[otherUid],
           mode != remoteScreenMode {
            remoteScreenMode = mode == "track" ? "track" : "camera"
        }
        upgradeScreenTransceiverIfDue()
        var screenChanged = false
        if let screens = d["screen"] as? [String: Bool] {
            let on = screens[otherUid] ?? false
            if on != remoteScreenSharing {
                remoteScreenSharing = on
                screenChanged = true
                // Their screen goes BIG: un-swap if I had my own feed fullscreen.
                if on, isLocalExpanded { isLocalExpanded = false }
                // Dual mode: no `cams` flip comes with it, so do here what that flip does in fallback
                // (call screen back up, keep-awake on).
                if remoteScreenMode == "track" {
                    if on, state == .active || state == .reconnecting,
                       !CallPiPController.shared.isSystemPiPActive {   // r2 I2, as the `cams` flip
                        minimized = false
                        if UIApplication.shared.applicationState != .active { postVideoSharingNote() }
                    }
                    updateInCallScreenBehavior()
                }
            }
        }
        if let cams = d["cams"] as? [String: Bool], let on = cams[otherUid], on != remoteCameraOn {
            remoteCameraOn = on
            // THEIR CAMERA COMING ON DEMANDS THE SCREEN BACK (owner's side-by-side reference,
            // 2026-08-12; FaceTime agrees): a voice call becoming video is the one moment in a call
            // that needs eyes. Minimized in the app → the call returns fullscreen by itself.
            // Backgrounded → a "sharing video" notification whose tap lands on the fullscreen call
            // (minimized cleared NOW so the foregrounding presents it without another step).
            // 1:1 audit r2 I2, 2026-10-08: not while the system PiP window is up. It already shows
            // their video; un-minimizing tore down its source view and closed the window.
            if on, state == .active || state == .reconnecting, !CallPiPController.shared.isSystemPiPActive {
                minimized = false
                if UIApplication.shared.applicationState != .active { postVideoSharingNote() }
            }
            // Their video is what the swapped layout is BUILT ON: expanded means my feed is fullscreen
            // and theirs is in the tile. If they kill their camera while we are swapped, that tile has
            // nothing to draw and hides itself - taking the tap target with it and stranding me
            // fullscreen on my own face with no way back. Un-swap instead, so their avatar returns to
            // the big view and I go back to the corner, which is the layout for "their camera is off".
            if on == false, isLocalExpanded { isLocalExpanded = false }
            // A `cams` flip that only comes from their screen share starting or stopping is not a
            // camera: a voice call must not jump to the loudspeaker (or log as video) because they
            // shared their screen. Audio routing stays exactly where it was.
            // Dual mode: their `cams` is their real camera even while they share, so it counts.
            let camsIsTheShare = (screenChanged || remoteScreenSharing) && remoteScreenMode != "track"
            if !camsIsTheShare {
                applyVideoAudioPolicy()    // SAME handling as my own toggle — see applyVideoAudioPolicy
            }
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
    /// Held by the system, which on iOS means one thing in practice: a phone call arrived on the
    /// cellular line and the person chose "Hold & Accept". iOS raises that sheet itself and calls
    /// this through CallKit; the app does not get to decide it.
    ///
    /// ⛔ THE CAMERA USED TO KEEP RUNNING. This method disabled the microphone and nothing else, so
    /// somebody who took a phone call in the middle of a video call went on broadcasting their face
    /// to the other person for the entire length of the phone call — while believing the call was on
    /// hold, and while the other side's screen showed nothing wrong. Their mic was off, so they could
    /// not even be told.
    ///
    /// Held is not the same as the camera being turned off: the intent to be on camera survives, so
    /// unholding restores it. That is exactly what the weak-link pause already does, so this reuses
    /// it rather than inventing a second paused state that could disagree with the first.
    func setHeld(_ held: Bool) {
        guard isHeld != held else { return }
        isHeld = held
        localAudioTrack?.isEnabled = !(isMuted || isHeld)
        if held {
            // A share ENDS on hold (not paused): the person is on a phone call now, and their screen
            // would show it. Stopped first, so the camera logic below sees the plain camera state.
            stopScreenShare(notice: screenSharing ? "Screen sharing stopped" : nil)
            pauseVideoForWeakLink()
            // pauseVideoForWeakLink stands down when a capture interruption already holds the camera,
            // and an interrupted session resumes ITSELF when the interruption ends, which would have
            // been mid-phone-call. Stop it outright; resumeCameraIfReallyBack restarts it on unhold.
            if cameraOn { videoCapturer?.stopCapture() }
        } else {
            resumeVideoAfterWeakLink()
            if cameraPausedByBackground { resumeCameraIfReallyBack() }
        }
        // NOT TRACKING WHO PAUSED IT, on purpose. The only case the two owners can disagree about is
        // a weak link AND a phone call at the same moment, where unholding would restore a camera
        // the network cannot carry. `sampleLinkQuality` is still running and pauses it again within
        // its next tick. A brief flap in a rare combination beats a second paused-state machine that
        // can drift out of step with the first one.
        //
        // The opposite case is now closed too (owner audit 2026-10-06 #1): a GOOD link can no longer
        // lift a hold's pause, because applyLinkQuality and resumeVideoAfterWeakLink both refuse while
        // isHeld, and every camera start checks cameraShouldRun, which includes it.
        broadcastMuteState()
    }

    // What the other side needs to know is simply "can they hear me right now", which is mute OR hold.
    ///
    /// NOT FIRE-AND-FORGET (owner audit 2026-10-06 #36): a write that fails left the other side's
    /// muted icon wrong until the next toggle. A failed write is retried a few times, and only while
    /// the same call is live and the value is still the one we meant to send, so a stale retry can
    /// never overwrite a newer toggle. Recovery from .reconnecting also re-sends (see `state`).
    private func broadcastMuteState(attempt: Int = 0) {
        guard let id = callId else { return }
        let value = isMuted || isHeld
        db.collection("calls").document(id).updateData(["muted.\(me)": value]) { [weak self] err in
            guard let self, err != nil, attempt < 3 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self, self.callId == id, self.inLiveCall,
                      (self.isMuted || self.isHeld) == value else { return }
                self.broadcastMuteState(attempt: attempt + 1)
            }
        }
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
            self?.heartbeatTick()
        }
    }

    /// 1:1 audit #44 (owner, 2026-10-08): one Firestore write every 5s for the whole call kept the
    /// radio awake. While the call is calm (active, media up, no sign of trouble from the other
    /// side) every OTHER tick writes, so 10s. Field, value and the 5s tick are unchanged, and the
    /// liveness check still runs every 5s. Old builds (840-843) end the call only after 15s of our
    /// silence AND only while THEY are reconnecting; when they are, they send a restart offer or
    /// request, `notePeerReconnecting` sees it, and we beat at once and every 5s again for 30s.
    /// Our own drop (not .active, or media down) is never calm either.
    private func heartbeatTick() {
        beatTick += 1
        let troubled = peerTroubleAt.map { Date().timeIntervalSince($0) < 30 } == true
        let calm = state == .active && mediaReady && !troubled
        if !calm || beatTick % 2 == 0 { writeHeartbeat() }
        checkPeerLiveness()
        refreshRelayIfAging()
    }

    /// 1:1 audit #32 (owner, 2026-10-08): relay credentials are minted for 2 hours and the relay
    /// checks them again on every allocation refresh, so a call that outlives the credentials its
    /// connection was built with loses the relay mid-call. 100 minutes after that list was
    /// fetched, fetch a fresh one and restart ICE with it (no media drop; the caller restarts, the
    /// callee asks). Each side watches its own list's age. At most one try per 2 minutes.
    private var relayRefreshTriedAt: Date?
    private func refreshRelayIfAging() {
        guard state == .active, mediaReady, let built = pcIceServersFetchedAt,
              Date().timeIntervalSince(built) > 100 * 60 else { return }
        if let tried = relayRefreshTriedAt, Date().timeIntervalSince(tried) < 120 { return }
        // 1:1 audit r2 J7, 2026-10-08: at most 2 tries per call. A list the connection refuses (or a
        // restart nobody answers) never moves `pcIceServersFetchedAt`, which re-armed this forever.
        if relayRefreshCallId != callId { relayRefreshCallId = callId; relayRefreshTries = 0 }
        guard relayRefreshTries < 2 else { return }
        relayRefreshTries += 1
        relayRefreshTriedAt = Date()
        let id = callId
        print("[Call] relay list is \(Int(Date().timeIntervalSince(built) / 60)) min old, refreshing mid-call")
        Task { [weak self] in
            await self?.refreshIceServers()
            DispatchQueue.main.async {
                guard let self, self.callId == id, self.state == .active,
                      let fresh = self.iceServersFetchedAt, fresh > built else { return }
                // 1:1 audit r2 F4, 2026-10-08: never restart a healthy call onto a list with no relay.
                guard let list = self.fetchedIceServers, Self.hasRelay(list) else { return }
                self.restartOrAsk()
            }
        }
    }
    /// 1:1 audit r2 J7: the call the try count below belongs to, and the count.
    private var relayRefreshCallId: String?
    private var relayRefreshTries = 0

    private var beatTick = 0
    private var peerTroubleAt: Date?

    /// 1:1 audit #44: the other phone is restarting ICE (its restart offer or request reached us).
    private func notePeerReconnecting() {
        peerTroubleAt = Date()
        writeHeartbeat()
    }

    /// 1:1 audit #30 (owner, 2026-10-08): a restart/upgrade description step failed after its
    /// version was latched as applied. Put the latch back (at most 3 times per version) so the next
    /// snapshot of the call doc, at the latest the other side's next beat, tries it again. The
    /// latch still stops a healthy replay from applying twice. Completions run on WebRTC's thread.
    private var restartLatchFailures: [String: Int] = [:]
    private func releaseRestartLatch(_ v: Int, back previous: Int, _ err: Error?) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.appliedRemoteRestart == v else { return }
            let key = "\(self.callId ?? ""):\(v)"
            let n = (self.restartLatchFailures[key] ?? 0) + 1
            self.restartLatchFailures[key] = n
            print("[Call] restart v\(v) step failed (\(n)): \(err?.localizedDescription ?? "no description")")
            guard n < 3 else { return }
            self.appliedRemoteRestart = previous
        }
    }

    private func stopHeartbeat() {
        heartbeatTimer?.invalidate(); heartbeatTimer = nil
        lastPeerBeatAt = nil; lastPeerBeatValue = 0
        lastOwnBeatAckAt = nil
        beatTick = 0; peerTroubleAt = nil   // 1:1 audit #44
        restartLatchFailures = [:]          // 1:1 audit #30
    }

    /// Audit M-040, 2026-10-07: when the server last CONFIRMED one of my own beats. Proof that my
    /// side can reach the signalling at all, which is what the liveness check below needs before it
    /// may blame the other phone.
    private var lastOwnBeatAckAt: Date?

    private func writeHeartbeat() {
        guard let id = callId, state == .active || state == .reconnecting else { return }
        db.collection("calls").document(id).updateData(["hb.\(me)": Date().timeIntervalSince1970]) { [weak self] err in
            // The completion only fires once the server has the write (offline it waits), so a nil
            // error means we were online just now.
            guard let self, err == nil, self.callId == id else { return }
            self.lastOwnBeatAckAt = Date()
        }
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
        // Audit M-040, 2026-10-07: their silence only counts while MY beats are getting through.
        // When it was our own network that dropped, their beats cannot reach us either, and the
        // check ended a call that was about to recover, 15-20s in, well inside the 30s reconnect cap.
        // Now the server must have taken one of my beats more than 10s after their last one: I am
        // demonstrably online and they still say nothing. 10, not 15: my queued beats are confirmed
        // in a burst on reconnect, a moment before the snapshot carrying their newest beat.
        guard let ack = lastOwnBeatAckAt, ack.timeIntervalSince(last) > 10 else { return }
        endReason = .failed
        hangUp()   // ~15s instead of frozen for 30s+
    }
    // The user's EXPLICIT speaker choice. CallKit/WebRTC re-activate the audio session at
    // connect/answer and reset the route to the earpiece — which used to silently erase a speaker
    // tap made during "Calling…" (the "speaker sometimes doesn't work" bug). Intent is remembered
    // here and re-asserted whenever the system resets the route out from under it.
    private var wantsSpeaker = false
    /// The video-call speaker default has been applied for THIS call (owner audit 2026-10-06 #6).
    /// Reset at .idle. See the `.active` branch of `state`.
    private var videoSpeakerDefaultApplied = false
    /// Audit M-010, 2026-10-07: the person picked a route themselves this call (the speaker button,
    /// or a deliberate pick in the system picker). From then on no camera event and no video
    /// default moves the route. Reset at .idle.
    private var speakerChosenByUser = false

    func toggleSpeaker() {
        isSpeaker.toggle()
        wantsSpeaker = isSpeaker
        speakerChosenByUser = true   // audit M-010
        // Use AVAudioSession directly — CallKit owns the session in manual mode and
        // RTCAudioSession.lockForConfiguration() can deadlock when called while CallKit
        // is also configuring the session (e.g. right after answer/connect).
        // 1:1 audit r2 D4, 2026-10-08: the mode IS the choice, as in the reference app. Inside
        // .videoChat the default route is the loudspeaker, so `.none` alone never left it (the
        // video-call ringback is .videoChat since #3). setMode keeps the category and its options.
        let session = AVAudioSession.sharedInstance()
        let wantMode: AVAudioSession.Mode = isSpeaker ? .videoChat : .voiceChat
        if session.mode != wantMode { try? session.setMode(wantMode) }
        try? session.overrideOutputAudioPort(isSpeaker ? .speaker : .none)
    }

    // MARK: - Audio route awareness (smart speaker button)

    // Where call audio is coming out right now. With no external device the speaker button is a
    // plain earpiece/speaker toggle; with AirPods/Bluetooth/wired around, the button shows the
    // live route and opens the NATIVE route picker instead (system behavior).
    enum AudioRoute { case earpiece, speaker, external }
    var audioRoute: AudioRoute = .earpiece
    var externalAudioAvailable = false
    /// When the route last landed on the built-in speaker. The bounce-back guard below reads it —
    /// see the note there.
    private var speakerLandedAt: Date?
    private var routeObserver: NSObjectProtocol?

    func startRouteObservation() {
        guard routeObserver == nil else { return }
        // 1:1 audit #26: the caller's first .active, if the accept path missed it.
        // 1:1 audit r2 D1, 2026-10-08: caller only. The callee's unit starts in didActivate, never
        // inside the Answer action before CallKit hands over the session (the reference app's rule).
        if isCaller { startCallAudioUnitIfDue() }
        updateAudioRoute()
        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
                // The reason tells a person's pick in the system picker apart from a session reset
                // (owner audit 2026-10-06 #7, see updateAudioRoute).
                let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
                self?.updateAudioRoute(reason: raw.flatMap { AVAudioSession.RouteChangeReason(rawValue: $0) })
        }
        startAudioRecoveryObservation()
    }

    // MARK: - Audio recovery

    private var audioInterruptionObserver: NSObjectProtocol?
    private var mediaResetObserver: NSObjectProtocol?

    /// A SAFETY NET UNDER CALLKIT, not a replacement for it. Normally CallKit hands the audio session
    /// back after Siri, an alarm or another app's sound (`didActivate` re-fires and CallKitManager
    /// restarts audio). When it does not, the call stays connected with NO SOUND either way, which
    /// is the worst kind of failure because nothing on screen says anything is wrong. The reference
    /// app only logs these two events; this re-arms our audio when they end.
    ///
    /// The media-services reset is the harsher one: the system audio daemon restarted, every audio
    /// unit in the app is dead, and the session must be rebuilt, so the RTC audio unit is cycled.
    private func startAudioRecoveryObservation() {
        guard audioInterruptionObserver == nil else { return }
        audioInterruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
                guard let self, self.inLiveCall,
                      let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
                // 1:1 audit r2 D2/J2, 2026-10-08: remember the interruption; didActivate clears it.
                if type == .began { self.activatedSinceInterruption = false; return }
                guard type == .ended else { return }
                // Give CallKit its turn first; only step in if audio is still off after it.
                let id = self.callId   // 1:1 audit check, 2026-10-08: never touch the next call
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    // Not while on hold: there the silence is deliberate and CallKit owns the unhold.
                    // 1:1 audit #27 (owner, 2026-10-08): and not for a caller whose call only rings
                    // (#26: the unit waits for the accept there).
                    guard self.callId == id, self.inLiveCall, !self.isHeld, !self.tearingDown,
                          self.callAudioUnitMayStart else { return }
                    // r2 D2/J2: CallKit re-activated the session since the interruption began, so
                    // didActivate already restarted audio (the reference app relies on that alone).
                    // A second stop and start here was an audible gap.
                    if self.activatedSinceInterruption { return }
                    // Re-set the call's category and mode FIRST (audit 05, low): enabling audio alone
                    // skipped the half of didActivate that configures the session, so a speaker call
                    // could come back on the earpiece-tuned echo canceller until the next route event.
                    self.applyCallAudioCategory()
                    // #27: Siri or an alarm never reaches didDeactivate, so the flag was still on and
                    // this net used to step aside, leaving the unit WebRTC stopped at the interruption
                    // down. Cycle it, as the media-reset path below does; a short blip at most.
                    let rtc = RTCAudioSession.sharedInstance()
                    if rtc.isAudioEnabled { rtc.isAudioEnabled = false }
                    rtc.isAudioEnabled = true
                    try? AVAudioSession.sharedInstance().overrideOutputAudioPort(self.isSpeaker ? .speaker : .none)
                }
        }
        mediaResetObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
                guard let self, self.inLiveCall else { return }
                // Audit M-120, 2026-10-07: a reset wipes the session's category and mode with
                // everything else, and only the output port was put back, so the call came back on
                // the default category. Set the call's own category first, as the interruption path does.
                self.applyCallAudioCategory()
                let rtc = RTCAudioSession.sharedInstance()
                rtc.isAudioEnabled = false
                rtc.isAudioEnabled = true
                try? AVAudioSession.sharedInstance().overrideOutputAudioPort(self.isSpeaker ? .speaker : .none)
        }
    }

    private func stopAudioRecoveryObservation() {
        if let o = audioInterruptionObserver { NotificationCenter.default.removeObserver(o); audioInterruptionObserver = nil }
        if let o = mediaResetObserver { NotificationCenter.default.removeObserver(o); mediaResetObserver = nil }
    }

    /// 1:1 audit r2 C4/D5, 2026-10-08: route and device-around for the ring screen, read live,
    /// with none of updateAudioRoute's re-asserts (no route observer runs before .active).
    private func refreshRouteForRing() {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        if outputs.contains(where: { $0.portType == .builtInSpeaker }) { audioRoute = .speaker }
        else if outputs.contains(where: { $0.portType == .builtInReceiver }) || outputs.isEmpty { audioRoute = .earpiece }
        else { audioRoute = .external }
        externalAudioAvailable = externalOutputAround
    }

    private func updateAudioRoute(reason: AVAudioSession.RouteChangeReason? = nil) {
        let session = AVAudioSession.sharedInstance()
        let outputs = session.currentRoute.outputs
        let previous = audioRoute
        if outputs.contains(where: { $0.portType == .builtInSpeaker }) { audioRoute = .speaker }
        else if outputs.contains(where: { $0.portType == .builtInReceiver }) || outputs.isEmpty { audioRoute = .earpiece }
        else { audioRoute = .external }
        updateInCallScreenBehavior()
        // Any external playback device around? Bluetooth headsets surface as available INPUTS
        // during a playAndRecord call; a currently-external route obviously counts too.
        let external: Set<AVAudioSession.Port> = [.bluetoothHFP, .bluetoothLE, .bluetoothA2DP,
                                                  .headphones, .headsetMic, .carAudio]
        let hasExternalInput = (session.availableInputs ?? []).contains { external.contains($0.portType) }
        // Audit round 2 (V1 new bug 1, from M-049), 2026-10-07: a video call that STARTED with AirPods
        // never got its speaker default (the device was connected), so when they came out the call
        // landed on the earpiece: a video call held at arm's length with the sound at the ear. The
        // device leaving is the moment the default is owed, unless the person picked a route
        // themselves. Only on `.oldDeviceUnavailable` landing on the earpiece, and only with no other
        // device still around, so a person's own pick of "iPhone" is never overruled. Proximity is not
        // involved: updateInCallScreenBehavior keeps it off whenever video shows.
        if reason == .oldDeviceUnavailable, audioRoute == .earpiece, !hasExternalInput,
           cameraOn || remoteCameraOn, !speakerChosenByUser, !wantsSpeaker {
            videoSpeakerDefaultApplied = true
            wantsSpeaker = true   // the re-assert below now holds it against session resets
            try? session.overrideOutputAudioPort(.speaker)
            // The follow-up routeChange notification re-runs this and lands in the .speaker branch.
            return
        }
        // The user asked for speaker but a system reset (CallKit re-activation at connect, WebRTC
        // reconfigure) bounced the route back to the earpiece → RE-ASSERT the choice. External devices
        // (AirPods/car) always win — never fight a real device route.
        if wantsSpeaker, audioRoute == .earpiece {
            // ⚠️ UNLESS THE PERSON PICKED "iPhone" (owner audit 2026-10-06 #7). On a video call
            // wantsSpeaker is kept on purpose, and only the in-app toggle could clear it, so choosing
            // the earpiece in the system picker bounced straight back to the speaker. The picker only
            // exists while an external device is around (CallView.speakerCircle), and with one
            // connected a reset lands on the device, not the earpiece. So: device still available,
            // the route MOVED here, and the cause is not a category reset or a device leaving → that
            // is a deliberate pick, and intent follows it.
            let pickReason = reason.map { $0 != .categoryChange && $0 != .oldDeviceUnavailable } ?? false
            let deliberatePick = hasExternalInput && previous != .earpiece && pickReason
            if deliberatePick {
                wantsSpeaker = false
                speakerChosenByUser = true   // audit M-010: their pick, not ours to undo
            } else {
                try? session.overrideOutputAudioPort(.speaker)
                // The follow-up routeChange notification re-runs this and lands in the .speaker branch.
                return
            }
        }
        // ⚠️ AND THE SAME RE-ASSERT AGAINST BLUETOOTH, which is his report (2026-08-14: with AirPods
        // in, picking Speaker in the system picker jumps straight back to the AirPods, but picking
        // iPhone first and Speaker second works).
        //
        // A Bluetooth headset does not merely offer itself, it CLAIMS the route: choosing the
        // built-in speaker while HFP is connected lands on the speaker for a moment and the headset
        // takes it back. Going via iPhone works because that first hop moves the session off the
        // headset, so the second choice has nothing to fight. The rule above already knew this shape
        // and only covered the earpiece.
        //
        // ⚠️ THE TWO-SECOND WINDOW IS THE WHOLE CARE HERE, because the rule it stands beside is the
        // opposite one and both are right: AirPods CONNECTING mid-call must win, and they still do —
        // that is a person putting something in their ear. What must not win is the same headset
        // grabbing back a route the person deliberately moved a moment ago.
        if audioRoute == .external, wantsSpeaker,
           let landed = speakerLandedAt, Date().timeIntervalSince(landed) < 2 {
            try? session.overrideOutputAudioPort(.speaker)
            return
        }
        if audioRoute == .speaker {
            // Stamp only a real ARRIVAL on the speaker (audit 05, low). Every notification that merely
            // found the speaker (our own setMode below, a CallKit re-assert) used to refresh it, so
            // the window above could reject AirPods connecting at any moment near those events. And
            // not again inside an open window, so a headset that keeps reclaiming the route is
            // fought for two seconds at most, never ping-ponged indefinitely.
            let windowOpen = speakerLandedAt.map { Date().timeIntervalSince($0) < 2 } ?? false
            if previous != .speaker, !windowOpen { speakerLandedAt = Date() }
            wantsSpeaker = true
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
        if audioRoute == .external, !(cameraOn || remoteCameraOn),
           !(speakerLandedAt.map { Date().timeIntervalSince($0) < 2 } ?? false) {
            wantsSpeaker = false
        }
        externalAudioAvailable = hasExternalInput || audioRoute == .external
    }

    // MARK: - What the audio is coming out of

    /// The glyph for the CURRENT external route. It used to be one hardcoded `headphones` for
    /// everything, which drew a pair of over-ear cans while the sound was going to AirPods (owner,
    /// 2026-08-23, with the picture: "it has this old earbuds instead modern bluetooth").
    ///
    /// Apple ships no Bluetooth glyph — the mark is trademarked and it is not in SF Symbols — so the
    /// modern way to say "this is going somewhere wireless" is to draw THE DEVICE, which is exactly
    /// what iOS itself does. AirPods get AirPods, a car gets a car, a cable still gets the cans,
    /// because for a wired headset the cans are the true picture rather than an old one.
    ///
    /// Read live from the session on every call: a route can change under us at any moment and the
    /// view re-reads this whenever `audioRoute` moves.
    var externalRouteIcon: String {
        guard let out = AVAudioSession.sharedInstance().currentRoute.outputs.first else { return "headphones" }
        let name = out.portName.lowercased()
        switch out.portType {
        case .carAudio:
            return "car.fill"
        case .bluetoothA2DP, .bluetoothHFP, .bluetoothLE:
            if name.contains("airpods max") { return Self.symbol("airpodsmax", or: "headphones") }
            if name.contains("airpods pro") { return Self.symbol("airpodspro", or: "headphones") }
            if name.contains("airpod")      { return Self.symbol("airpods.gen3", or: "airpods") }
            if name.contains("beats")       { return Self.symbol("beats.headphones", or: "headphones") }
            // Some other wireless headset. Cans are honest here — it could be anything, and guessing
            // earbuds would draw a picture of a device the person is not wearing.
            return "headphones"
        default:
            return "headphones"   // wired, or an oddity: the cable really is a pair of headphones
        }
    }

    /// ⚠️ A MISSING SF SYMBOL RENDERS AS NOTHING AT ALL — no crash, no warning, just a blank circle
    /// where the button was. These names are device-specific and come and go between SF Symbols
    /// releases, so every one of them is checked before it is handed to the view.
    private static func symbol(_ name: String, or fallback: String) -> String {
        UIImage(systemName: name) != nil ? name : fallback
    }

    // Ringback the CALLER hears while waiting (generated tone, looped). Allow mixing so the
    // player outputs while CallKit owns the session (the WebRTC unit stays off until the accept, #26).
    private func startRingback() {
        guard ringbackPlayer == nil else { return }
        let s = RTCAudioSession.sharedInstance()
        s.lockForConfiguration()
        // KEEP BLUETOOTH (audit). CallKit's didActivate sets .playAndRecord with
        // [.allowBluetooth, .allowBluetoothA2DP], then calls straight into here — and options are
        // REPLACED, not merged, so starting the ringback with only [.mixWithOthers] tore the HFP
        // route down for the rest of every OUTGOING call. AirPods died the moment you dialled, while
        // answering a call was fine, because this path only runs for the caller.
        // 1:1 audit #3 (owner, 2026-10-08): the mode follows the speaker choice and the override is
        // put back after. A fixed .voiceChat dropped a video call's ringback to the earpiece while
        // the button said Speaker. 1:1 audit #1/#26: no `isAudioEnabled` here any more; the player
        // does not need the WebRTC unit, and turning it on opened the mic while it only rang.
        try? s.setCategory(.playAndRecord, mode: isSpeaker ? .videoChat : .voiceChat,
                           options: [.mixWithOthers, .allowBluetooth, .allowBluetoothA2DP])
        s.unlockForConfiguration()
        try? AVAudioSession.sharedInstance().overrideOutputAudioPort(isSpeaker ? .speaker : .none)
        ringbackPlayer = try? AVAudioPlayer(data: RingbackTone.wavData())
        ringbackPlayer?.numberOfLoops = -1
        ringbackPlayer?.prepareToPlay()
        ringbackPlayer?.play()
        armRingbackWatchdog()
    }
    private func stopRingback() {
        ringbackWatchdog?.invalidate(); ringbackWatchdog = nil
        // A fallback armed by the ringing signal must die with the stop too, or an accept that lands
        // inside its 1.2s window is followed by a ring nothing is left to stop.
        ringbackFallback?.invalidate(); ringbackFallback = nil
        let wasPlaying = ringbackPlayer != nil
        ringbackPlayer?.stop(); ringbackPlayer = nil
        // HAND THE SESSION BACK TO THE CALL (owner audit 2026-10-06 #8). startRingback swapped the
        // options to include .mixWithOthers and nothing ever swapped them back, so the CALLER's whole
        // call stayed mixable: music in another app kept playing under it, while the callee's call
        // (no ringback) was exclusive. Only when the ringback ends because they ACCEPTED: a ringback
        // that ends with the call (cancel, no answer) is followed by the end tone, which wants the
        // mixable session anyway.
        if wasPlaying, calleeAccepted { applyCallAudioCategory() }
        // 1:1 audit #26 (owner, 2026-10-08): both accept paths stop the ringback, so the caller's
        // audio unit starts here.
        if calleeAccepted { startCallAudioUnitIfDue() }
    }

    /// 1:1 audit #26 (owner, 2026-10-08): false while the caller's call only rings. The WebRTC
    /// audio unit (and with it the mic indicator and AirPods' call mode) waits for the accept,
    /// like the reference app; the track itself was already silent until then. Read by didActivate.
    var callAudioUnitMayStart: Bool { !(isCaller && state == .outgoing && !calleeAccepted) }

    /// 1:1 audit check, 2026-10-08: set at the top of finishCall, cleared at the .idle reset.
    private var tearingDown = false

    /// 1:1 audit r2 D2/J2, 2026-10-08: CallKit activated the session since the last interruption
    /// began. Cleared at .began and at .idle, set in audioSessionActivated.
    private var activatedSinceInterruption = false

    /// 1:1 audit r2 C5, 2026-10-08: CallKit took the session away. Needs a call from
    /// CallKitManager's didDeactivate (cross-builder).
    func audioSessionDeactivated() {
        callAudioLive = false
    }

    /// Turns the WebRTC audio unit on once the call may have it (#26). Also covers a call CallKit
    /// never activated, which the old ringback used to switch on as a side effect. Idempotent.
    private func startCallAudioUnitIfDue() {
        guard inLiveCall, !isHeld, !tearingDown, callAudioUnitMayStart else { return }
        let rtc = RTCAudioSession.sharedInstance()
        if !rtc.isAudioEnabled { rtc.isAudioEnabled = true }
    }

    /// The call's own session setup: the category and Bluetooth options CallKit's didActivate sets,
    /// WITHOUT the .mixWithOthers the ringback and tones need. Mode follows where the sound comes out,
    /// the same rule as updateAudioRoute (loudspeaker → .videoChat, anything else → .voiceChat).
    /// The speaker override is re-applied after, since a category change can drop it.
    private func applyCallAudioCategory() {
        let session = AVAudioSession.sharedInstance()
        let onSpeaker = session.currentRoute.outputs.contains { $0.portType == .builtInSpeaker }
        let s = RTCAudioSession.sharedInstance()
        s.lockForConfiguration()
        try? s.setCategory(.playAndRecord, mode: onSpeaker ? .videoChat : .voiceChat,
                           options: [.allowBluetooth, .allowBluetoothA2DP])
        s.unlockForConfiguration()
        try? session.overrideOutputAudioPort(isSpeaker ? .speaker : .none)
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

    // Called by CallKit the instant it activates the audio session. The session may not be live at
    // startCall: on some devices a player started early is SILENT until this fires, on others it is
    // already audible, and the old unconditional stop+start gave the audible case a hear-it, cut,
    // hear-it-again stutter (user report). So nothing is started before this point (see
    // beginOutgoingMedia): the one start happens here, into a live session, from the top.
    //
    // ⛔ AND ONLY ONCE THE OTHER PHONE IS ACTUALLY RINGING (owner, 2026-10-07: "when I turn on the
    // speaker the ringing sound starts"). The ringback had been playing through the earpiece from
    // the first second of "Calling…", inaudible at arm's length, and the loudspeaker merely made it
    // heard. Checked against the reference app's call audio source on 2026-10-07: while DIALING it
    // plays one short connecting cue and nothing more; its looped ringback starts on REMOTE RINGING.
    // The 2026-07-22 note that said the reference rings from the start was wrong. "Calling…" is
    // quiet now; the ring begins when `ringingAt` lands (`calleeRinging`), started by whichever of
    // the two, that signal or this activation, arrives second.
    func audioSessionActivated() {
        // 1:1 audit r2 C5, 2026-10-08: a late activation for a call already reset to idle must not
        // leave callAudioLive on for the next dial.
        guard inLiveCall else { return }
        activatedSinceInterruption = true   // r2 D2/J2
        ringbackFallback?.invalidate(); ringbackFallback = nil
        callAudioLive = true
        startRingbackIfDue()
    }

    /// The one gate every ringback start goes through: an outgoing call whose other phone has
    /// reported ringing and has NOT accepted yet, with no player already up. `!calleeAccepted`
    /// because the accept can land first (over the data channel, or in the same snapshot as
    /// `ringingAt`) while `state` is still `.outgoing`: the old code had a playing tone for
    /// `stopRingback` to stop at that point; this one would have started it for the first time.
    private func startRingbackIfDue() {
        guard state == .outgoing, calleeRinging, !calleeAccepted, ringbackPlayer == nil else { return }
        startRingback()
    }

    /// Belt for the case CallKit never activates the session (activation failure, or a device that
    /// simply does not call back): a short wait after the other phone reports ringing, then the
    /// ringback starts anyway rather than leave the caller in silence. Cancelled the moment a real
    /// activation arrives. Armed by the `ringingAt` signal, not by the dial (see audioSessionActivated).
    private var ringbackFallback: Timer?
    private func armRingbackFallback() {
        ringbackFallback?.invalidate()
        ringbackFallback = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: false) { [weak self] _ in
            self?.startRingbackIfDue()
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
        // 1:1 audit #3 (owner, 2026-10-08): mode and override follow the speaker choice, as in
        // startRingback, so a busy tone on a speaker call is not dropped to the earpiece.
        // 1:1 audit #1: no `isAudioEnabled = true` here. Nothing ever switched it back off for a
        // session CallKit had not activated (a ring that was never answered).
        try? s.setCategory(.playAndRecord, mode: isSpeaker ? .videoChat : .voiceChat,
                           options: [.mixWithOthers, .allowBluetooth, .allowBluetoothA2DP])
        s.unlockForConfiguration()
        try? AVAudioSession.sharedInstance().overrideOutputAudioPort(isSpeaker ? .speaker : .none)
        tonePlayer = try? AVAudioPlayer(data: data)
        tonePlayer?.numberOfLoops = loops
        tonePlayer?.prepareToPlay()
        tonePlayer?.play()
    }
    private func stopTone() {
        tonePlayer?.stop(); tonePlayer = nil
        // 1:1 audit #1 (owner, 2026-10-08): the end of the tone window, or idle. The call is over, so
        // the WebRTC unit is off even when CallKit never activated (and so never deactivates) a
        // session for it; the next call must not find it on before its own activation.
        if state == .ended || state == .idle { RTCAudioSession.sharedInstance().isAudioEnabled = false }
    }

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
            self.ringOutChecked()
        }
        noAnswerWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 45, execute: w)   // ~45s, like big apps
    }

    /// THE RING-OUT, DECIDED ON THE SERVER (audit M-037, 2026-10-07). The 45s timer used to write
    /// `ended/missed` blind, so a person who tapped Accept at 44.6s had their answered call ended
    /// under them, and the two phones then logged "missed" and "answered" into one row. Now one
    /// transaction reads the doc: an accept already there means the call was picked up, so the
    /// ring-out stands aside and the accepted-connect timer takes over; otherwise the doc is ended
    /// with `cancelledAt`, the callee's proof that the caller gave up first (`cancelledBeforeAccept`).
    /// A doc that never reached the server, or a transaction that cannot run (offline), falls back
    /// to the old blind end, which is what happened before.
    private func ringOutChecked() {
        guard callDocCreated, let id = callId else { endReason = .missed; hangUp(); return }
        let attempt = dialAttempt
        let ref = db.collection("calls").document(id)
        db.runTransaction({ txn, errPtr -> Any? in
            let snap: DocumentSnapshot
            do { snap = try txn.getDocument(ref) } catch {
                errPtr?.pointee = error as NSError
                return nil
            }
            let d = snap.data() ?? [:]
            if (d["status"] as? String) == "ended" { return "ended" }
            if d["acceptedAt"] != nil { return "accepted" }
            txn.updateData(["status": "ended", "endReason": EndReason.missed.rawValue,
                            "cancelledAt": FieldValue.serverTimestamp()], forDocument: ref)
            return "rangOut"
        }) { [weak self] result, err in
            guard let self, self.callId == id, self.dialAttempt == attempt, self.state == .outgoing else { return }
            switch result as? String {
            case "accepted":
                // Picked up in the last instant. The listener applies the accept itself; give the
                // answer the same short window any accepted call gets.
                if !self.calleeAccepted { self.startAcceptedConnectTimeout() }
            case "ended":
                break   // the other side ended it first; the doc listener runs that end
            case "rangOut":
                self.endReason = .missed
                self.finishCall(updateRemote: false, clearCallKit: true, localUser: false)
            default:
                if err != nil { self.endReason = .missed; self.hangUp() }
            }
        }
    }

    /// ACCEPTED, BUT THE MEDIA NEVER CAME UP (audit M-008, 2026-10-07). The answer landing cancelled
    /// both the no-answer and the accepted-connect timers, and reconnect only starts on
    /// `disconnected`/`failed`; a connection that sat in `checking` left both people on
    /// "Connecting..." forever with the mic open. One timer per accepted call: no media by then is a
    /// failed call. Cancelled the moment the call really starts (`beginConnectedCallIfAccepted`) and
    /// with every other timer. A path that IS up but is waiting on the accept latch is left alone:
    /// audio is flowing there, and ending it would cut a working call.
    private var acceptedMediaWork: DispatchWorkItem?
    private func startAcceptedMediaTimeout() {
        guard connectedDate == nil, let id = callId else { return }
        acceptedMediaWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self, self.callId == id, self.connectedDate == nil, !self.mediaReady,
                  self.state == .active || self.state == .reconnecting else { return }
            self.endReason = .failed
            self.hangUp()
        }
        acceptedMediaWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 35, execute: w)
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
        acceptedMediaWork?.cancel(); acceptedMediaWork = nil   // audit M-008
        iceRestartWork?.cancel(); iceRestartWork = nil
        iceRestartRetryWork?.cancel(); iceRestartRetryWork = nil
        reconnectGiveUpWork?.cancel(); reconnectGiveUpWork = nil
        // 1:1 audit check, 2026-10-08: a leftover item made the next call's first drop a no-op.
        reconnectGraceWork?.cancel(); reconnectGraceWork = nil
        restartDeferWork?.cancel(); restartDeferWork = nil
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
        // 1:1 audit #7 (owner, 2026-10-08): the LABEL waits out the same grace as the restart. A
        // `disconnected` blip that heals inside it never shows "Reconnecting...", and the recovery
        // back to .active (with its one-time writes) never runs for it. `failed` (delay 0) is at once.
        if state == .active, delay > 0 {
            linkTransitionAt = Date()   // #29: the weak-link check stays out of the blip
            guard reconnectGraceWork == nil else { return }
            let id = callId
            let w = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.reconnectGraceWork = nil
                guard self.callId == id, self.state == .active, !self.mediaReady else { return }
                self.enterReconnecting(restartAfter: 0)
            }
            reconnectGraceWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
            return
        }
        reconnectGraceWork?.cancel(); reconnectGraceWork = nil
        if state == .active {
            state = .reconnecting
            reconnectStartedAt = Date()
            linkTransitionAt = Date()   // #29
            refreshIceServersForReconnect()   // audit M-009: a relay for the restart, if we lack one
        }
        // Hard cap: if we still haven't recovered, end as Failed.
        if reconnectGiveUpWork == nil { armReconnectGiveUp(after: 30) }
        // The caller drives the ICE restart (avoids glare). The callee used to just wait for the
        // caller's own ICE to notice, which it may not for many seconds when only the CALLEE's
        // network moved; now it asks, and the caller restarts at once (see `requestIceRestart`).
        // Owner audit 2026-10-06 #33: the callee asks after the SAME wait as the caller restarts. It
        // used to ask at once, so every sub-second `disconnected` blip that would have healed by
        // itself forced a full restart on the caller, one per blip. Re-arming on each new event
        // (cancel below) is the debounce: only a drop that outlasts the wait sends a request.
        iceRestartWork?.cancel()
        let r = DispatchWorkItem { [weak self] in
            guard let self, self.state == .reconnecting else { return }
            self.restartOrAsk()
            self.scheduleIceRestartRetry()
        }
        iceRestartWork = r
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: r)
    }

    /// The caller restarts ICE itself; the callee asks the caller to (see `requestIceRestart`).
    private func restartOrAsk() {
        if isCaller { restartIce() } else { requestIceRestart() }
    }

    /// One restart offer can be lost (signalling write on a dying network, or the answer never
    /// comes back). Re-offer every 8s while still reconnecting, up to the 30s give-up cap, instead
    /// of sitting out the whole cap on a single attempt. #33: the callee's REQUEST is retried the
    /// same way; it was sent once, and a lost write left the call on "Reconnecting" for the cap.
    private func scheduleIceRestartRetry() {
        iceRestartRetryWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self, self.state == .reconnecting else { return }
            // 1:1 audit #9 (owner, 2026-10-08): a restart that is WORKING is left alone. Its answer
            // is in (caller: nothing in flight) and ICE is checking the new routes; a fresh restart
            // now would throw those checks away with new credentials. Wait one more round instead.
            if self.restartIsWorking {   // 1:1 audit r2 F1/F3: one test for every restart path
                self.scheduleIceRestartRetry()
                return
            }
            self.restartOrAsk()
            self.scheduleIceRestartRetry()
        }
        iceRestartRetryWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: w)
    }

    /// 1:1 audit #7 / #9 (owner, 2026-10-08): the grace before a `disconnected` shows as Reconnecting,
    /// when this drop began, and since when ICE has been checking (set by the ICE delegate).
    private var reconnectGraceWork: DispatchWorkItem?
    private var reconnectStartedAt: Date?
    private var iceCheckingSince: Date?
    /// 1:1 audit r2 F3, 2026-10-08: when the latest restart was applied here (caller: its answer;
    /// callee: its offer). A new restart sent while ICE is already checking fires no new
    /// `.checking`, so the 12 s are measured from the later of the two.
    private var restartAppliedAt: Date?

    /// 1:1 audit r2 F1/F3, 2026-10-08: a restart is WORKING: its answer is in (caller: nothing in
    /// flight) and ICE has been checking for under 12 s since the latest answer. A new restart
    /// now would throw those checks away with new credentials.
    private var restartIsWorking: Bool {
        let answered = !isCaller || restartInFlightAt == nil
        guard answered, let c = iceCheckingSince else { return false }
        let since = max(c, restartAppliedAt ?? c)
        return Date().timeIntervalSince(since) < 12
    }

    /// 1:1 audit #9 (owner, 2026-10-08): the give-up was a flat 30s from the first drop. On a long,
    /// slow link (USA to Uganda via Doha) a reconnect that needs 35s was ended as Failed. At 30s the
    /// call now gets more time, in 15s steps up to 60s in all, but only while there is a sign it is
    /// coming back: the other phone's beat is still arriving (they are alive and signalling works),
    /// or ICE is checking new routes. Nothing of the sort: Failed at 30s exactly as before.
    private func armReconnectGiveUp(after seconds: Double) {
        reconnectGiveUpWork?.cancel()
        let id = callId
        let g = DispatchWorkItem { [weak self] in
            guard let self, self.callId == id, self.state == .reconnecting else { return }
            let now = Date()
            let elapsed = self.reconnectStartedAt.map { now.timeIntervalSince($0) } ?? 60
            let peerAlive = self.lastPeerBeatAt.map { now.timeIntervalSince($0) < 12 } == true   // 1:1 audit check, 2026-10-08: calm beat is 10 s
                && self.lastPeerBeatValue != 0
            let checking = self.iceCheckingSince != nil
            // 1:1 audit r2 F5, 2026-10-08: a failed DTLS transport never comes back; no extension.
            if elapsed < 60, peerAlive || checking, !self.transportFailed {
                print("[Call] reconnect: still trying at \(Int(elapsed))s (peerAlive \(peerAlive), checking \(checking))")
                self.armReconnectGiveUp(after: min(15, 60 - elapsed))
                return
            }
            self.endReason = .failed
            self.hangUp()
        }
        reconnectGiveUpWork = g
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: g)
    }

    /// Callee side: ask the caller for an ICE restart. A counter, not a flag, so every request is a
    /// new value the caller's listener can tell apart from the last one it served.
    private func requestIceRestart() {
        guard !isCaller, let id = callId, state == .active || state == .reconnecting else { return }
        restartRequestsSent += 1
        db.collection("calls").document(id).updateData(["restartRequest": restartRequestsSent])
    }

    /// Owner audit 2026-10-06 #15: the path dropped while the phone was still ringing (a pre-negotiated
    /// call). Set by the ICE delegate, cleared when the path comes back and at the end of every call.
    private var iceDroppedDuringRing = false
    /// Audit M-042, 2026-10-07: the connection failed with ICE still up (a DTLS failure). Set by the
    /// connection-state delegate, cleared at the end of every call.
    private var transportFailed = false

    /// Called when the call goes `.active`: a path that died during the ring and never came back
    /// gets the ordinary reconnect (Reconnecting label, restart, 30s cap) instead of a call that
    /// "connects" onto nothing. Async, because it changes `state` and runs from inside its didSet.
    private func reconnectIfDroppedDuringRing() {
        guard iceDroppedDuringRing else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.iceDroppedDuringRing, self.state == .active, !self.mediaReady else { return }
            self.iceDroppedDuringRing = false
            self.enterReconnecting(restartAfter: 0)
        }
    }

    private func recovered() {
        iceRestartWork?.cancel(); iceRestartWork = nil
        iceRestartRetryWork?.cancel(); iceRestartRetryWork = nil
        reconnectGiveUpWork?.cancel(); reconnectGiveUpWork = nil
        reconnectGraceWork?.cancel(); reconnectGraceWork = nil   // 1:1 audit #7: healed inside the grace
        reconnectStartedAt = nil
        if state == .reconnecting {
            linkTransitionAt = Date()   // #29: a new path, judged on its own
            linkMovedAt = Date()        // 1:1 audit r2 F2: a real recovery
            state = .active
        }
    }

    // MARK: - Network switch watcher

    /// ICE only learns a path died after its own checks time out, several seconds of silence on a
    /// Wi-Fi -> cellular walk-out. The OS knows the moment the interface changes, so restart ICE
    /// then, while the old path may still be carrying audio. A restart does not drop media: the
    /// old pair keeps flowing until a new one is nominated, so there is no "Reconnecting" flash.
    private func startPathMonitor() {
        guard pathMonitor == nil else { return }
        let m = NWPathMonitor()
        m.pathUpdateHandler = { [weak self] path in
            // The interface the traffic actually goes out on. Same key = same route, nothing to do.
            // Owner audit 2026-10-06 #34: this used to key on EVERY usable interface, so cellular
            // flapping in the background while on Wi-Fi, or a spare interface coming and going,
            // restarted ICE although the route in use never moved. The first available interface
            // is the one the system routes through; its name tells two of one type apart.
            // 1:1 audit #19 (owner, 2026-10-08): plus the interface's own address and the gateway.
            // "wifi:en0" alone is the same for two different Wi-Fi networks, so a move from home to
            // the office (new address, same radio) never restarted ICE early.
            let first = path.availableInterfaces.first
            let key = path.status == .satisfied
                ? first.map { "\($0.type):\($0.name):\(Self.interfaceAddress($0.name)):\(path.gateways.map { "\($0)" }.sorted())" } ?? "none"
                : "none"
            let onWifi = path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet)
            DispatchQueue.main.async {
                guard let self else { return }
                defer {
                    self.lastPathKey = key
                    if self.lastPathWasWifi == nil, key != "none" { self.lastPathWasWifi = onWifi }
                }
                guard let last = self.lastPathKey, last != key, key != "none",
                      self.state == .active || self.state == .reconnecting else { return }
                // 1:1 audit #8: Use Less Data and the video ceiling follow the network the call is
                // on now, both ways (Wi-Fi to cellular and back), not the one it started on.
                if self.lastPathWasWifi != onWifi {
                    self.lastPathWasWifi = onWifi
                    self.applyDataSaver(to: self.pc, onWifi: onWifi)
                }
                self.linkTransitionAt = Date()   // #29
                self.linkMovedAt = Date()        // 1:1 audit r2 F2: a real network move
                if self.isCaller { self.restartIce() } else { self.requestIceRestart() }
            }
        }
        m.start(queue: DispatchQueue(label: "call.path"))
        pathMonitor = m
    }

    private func stopPathMonitor() {
        pathMonitor?.cancel(); pathMonitor = nil
        lastPathKey = nil
        lastPathWasWifi = nil   // 1:1 audit #8
    }

    /// 1:1 audit #8 (owner, 2026-10-08): whether the call's route was Wi-Fi at the last path update.
    private var lastPathWasWifi: Bool?

    /// 1:1 audit #19 (owner, 2026-10-08): the IPv4 address(es) on one interface, for the path key.
    /// 1:1 audit check, 2026-10-08: IPv6 is left out. Temporary (privacy) IPv6 addresses rotate
    /// on their own, and each rotation restarted ICE; the gateways and the name still tell an
    /// IPv6-only move apart. Empty when nothing can be read: the key then falls back to the old one.
    private static func interfaceAddress(_ name: String) -> String {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let start = head else { return "" }
        defer { freeifaddrs(head) }
        var v4: [String] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = start
        while let p = cursor {
            defer { cursor = p.pointee.ifa_next }
            guard let sa = p.pointee.ifa_addr, String(cString: p.pointee.ifa_name) == name else { continue }
            guard Int32(sa.pointee.sa_family) == AF_INET else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            // Not the deprecated String(cString:) on an array.
            let text = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            v4.append(text)
        }
        return v4.sorted().joined(separator: ",")
    }

    /// Audit M-117, 2026-10-07: when the caller's last restart offer went out; cleared when its
    /// answer is applied and at the end of the call.
    private var restartInFlightAt: Date?

    /// 1:1 audit #20 (owner, 2026-10-08): a restart asked for inside the 6s one-at-a-time window
    /// (a real network change, or the callee's request, a moment after our own restart) used to be
    /// dropped, and the offer in flight had been gathered on the old network. It now runs once when
    /// the window closes, unless ICE has come up since it was asked for.
    private var restartDeferWork: DispatchWorkItem?
    /// When ICE last went connected/completed (set by the ICE delegate).
    private var lastIceConnectedAt: Date?

    private func deferRestartPastWindow(sentAt t: Date) {
        guard restartDeferWork == nil else { return }
        let asked = Date()
        let id = callId
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.restartDeferWork = nil
            guard self.callId == id, self.state == .active || self.state == .reconnecting else { return }
            if let c = self.lastIceConnectedAt, c > asked { return }   // healed since: nothing to redo
            // 1:1 audit r2 F1, 2026-10-08: never over a restart that is working, and not when an
            // answer landed since and the call is healthy (ICE stayed connected through a move).
            if self.restartIsWorking { return }
            if let a = self.restartAppliedAt, a > asked, self.state == .active, self.mediaReady { return }
            print("[Call] restart: running the one held back by the in-flight window")
            self.restartIce()
        }
        restartDeferWork = w
        let wait = max(0, 6 - Date().timeIntervalSince(t)) + 0.2
        DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: w)
    }

    // Caller-only: renegotiate ICE (new credentials + candidates), media keeps flowing
    // on recovery. Cheaper than a full re-offer — DTLS/SRTP keys are preserved.
    /// `iceRestart: false` (screen share v3): the same caller re-offer without new ICE credentials,
    /// used once to open the screen m-line. Old callees answer it like any restart offer.
    private func restartIce(iceRestart: Bool = true) {
        guard isCaller, let pc = pc, let id = callId else { return }
        // Audit M-117, 2026-10-07: the path monitor, the callee's request and our own ICE drop can all
        // fire within a second, and each new offer invalidates the answer the last one is waiting
        // for, so the restarts kept cancelling each other. One at a time: a restart whose answer has
        // not landed and that is under 6s old covers the others. The 8s retry is outside the window.
        // Only ICE restarts take this slot. The screen m-line upgrade (iceRestart false) is tracked
        // in `screenUpgradeInFlightVersion` and never blocks a restart: a restart sent over it gets
        // a newer version, so the upgrade's late answer fails the `v == negotiationVersion` check
        // and is dropped, and the restart's offer already carries the sendrecv screen m-line.
        if iceRestart {
            if let t = restartInFlightAt, Date().timeIntervalSince(t) < 6 {
                deferRestartPastWindow(sentAt: t)   // 1:1 audit #20
                return
            }
            restartDeferWork?.cancel(); restartDeferWork = nil
            restartInFlightAt = Date()
            applyNewerIceServers(to: pc)   // audit M-009: a relay that arrived after the call started
        }
        negotiationVersion += 1
        let v = negotiationVersion
        screenUpgradeInFlightVersion = iceRestart ? nil : v
        let constraints = RTCMediaConstraints(mandatoryConstraints: iceRestart ? ["IceRestart": "true"] : nil,
                                              optionalConstraints: nil)
        pc.offer(for: constraints) { [weak self] sdp, _ in
            guard let self, let sdp, let pc = self.pc else { return }
            // A newer offer (an ICE restart sent over the screen upgrade) replaced this one: drop it,
            // so a stale version can never overwrite the newer `restartOffer` on the call doc.
            guard v == self.negotiationVersion else { return }
            // createOffer rebuilds the codec list from scratch, so a restart offer that skipped this
            // would flip the order back to opus-first and drop RED for the rest of the call, right at
            // the moment the network is already bad enough to need a reconnect.
            let local = self.withOpusDtxAndRed(sdp)
            pc.setLocalDescription(local) { _ in
                guard v == self.negotiationVersion else { return }   // superseded, see above
                // #27: sealed on a sealed call; the version stays readable (ordering, not secret).
                // 1:1 audit r2 G9: a failed seal is retried, never sent plain.
                self.writeSignalSdp(local.sdp, version: v, field: "restartOffer",
                                    ref: self.db.collection("calls").document(id)) {
                    [weak self] in self?.negotiationVersion == v
                }
            }
        }
    }

    /// 1:1 audit r2 G9, 2026-10-08: write a restart offer/answer. On a sealed call a seal that fails
    /// (key dropped from memory) re-warms the key and tries again a second later, up to 5 times,
    /// while `current()` holds; the other phone refuses a plaintext SDP on a sealed call, so the
    /// old plaintext fallback only lost the reconnect. Unsealed calls write plaintext as before.
    private func writeSignalSdp(_ sdp: String, version v: Int, field: String, ref: DocumentReference,
                                attempt: Int = 1, current: @escaping () -> Bool) {
        if let enc = sealSignal(sdp) { ref.updateData([field: ["enc": enc, "version": v] as [String: Any]]); return }
        guard sealSignalling else { ref.updateData([field: ["sdp": sdp, "version": v] as [String: Any]]); return }
        guard attempt < 5 else { print("[Call] G9: \(field) could not be sealed, not sent"); return }
        warmSignalKey()
        let id = callId
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.callId == id, id == ref.documentID, current() else { return }
            self.writeSignalSdp(sdp, version: v, field: field, ref: ref, attempt: attempt + 1, current: current)
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

    /// 2026-09-26 block rebuild: a call to somebody I blocked. A UIKit alert on whatever is on top,
    /// for the same reason as `GroupCallService.presentOverTop` (a dozen dial sites, some in sheets).
    /// Unblocking does not ring them: the person presses Call again, knowing they have unblocked.
    @MainActor
    static func offerUnblock(uid: String, name: String, tries: Int = 4) {
        guard let top = WebLink.topViewController(), !(top is UIAlertController) else { return }
        if top.isBeingPresented || top.isBeingDismissed {
            guard tries > 0 else { return }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 300_000_000)
                offerUnblock(uid: uid, name: name, tries: tries - 1)
            }
            return
        }
        let who = name.isEmpty ? "this person" : name
        let alert = UIAlertController(title: "Unblock \(who)?",
                                      message: "You blocked \(who). Unblock them to call.",
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Unblock", style: .default) { _ in
            Task { await BlockList.shared.setBlocked(uid, false) }
        })
        top.present(alert, animated: true)
    }

    /// Owner audit 2026-10-06 #10: which dial this is. The mic prompt and the TURN wait can outlive a
    /// cancel, and a cancel-then-redial put the state back to `.outgoing` before the first dial's
    /// waits woke, so a state check alone let BOTH dials run: two call docs, the first person rung
    /// for a call nobody controlled. Every deferred step of a dial compares this instead.
    private var dialAttempt = 0
    /// When the current dial was placed (audit M-155, 2026-10-07). Read only by the double-tap test.
    private var dialStartedAt: Date?
    /// The other person's name as THEY published it, never my nickname for them (audit M-151,
    /// 2026-10-07). "Add people" writes the peer into a shared room doc that everyone invited reads,
    /// and `otherName` is my private label. Set wherever `otherName` is set.
    private var otherRawName = ""
    /// Set the moment the dial's create transaction is sent (audit M-112, 2026-10-07). Before it,
    /// the other phone cannot see this dial at all, so a crossing call from the same person must
    /// win instead of being busied by a call that does not exist yet. Cleared in `finishCall`.
    private var dialCreateStarted = false
    /// 1:1 audit #25 (owner, 2026-10-08): crossing calls I won while my own create was still in
    /// flight. Their busy waits for my doc to exist; if the create fails they are let ring here.
    private var pendingGlareBusy: Set<String> = []

    /// Wins a glare tiebreak against `docId` (#25). "Create started" is not "my call exists": the
    /// loser is busied now only if my doc is already there, otherwise when the create lands.
    private func glareBusy(_ docId: String) {
        guard callDocCreated else { pendingGlareBusy.insert(docId); return }
        db.collection("calls").document(docId)
            .updateData(["status": "ended", "endReason": EndReason.busy.rawValue, "glare": true])
    }

    /// Sends the busy held back by `glareBusy` (#25): my create landed, or the dial ended under it.
    private func flushGlareBusy() {
        let ids = pendingGlareBusy
        pendingGlareBusy = []
        for id in ids {
            db.collection("calls").document(id)
                .updateData(["status": "ended", "endReason": EndReason.busy.rawValue, "glare": true])
        }
    }

    /// My create failed (#25): the crossing calls I held back were never busied, so they may ring
    /// here once this dial is over (the idle re-arm reads them fresh).
    private func releaseGlareLosers() {
        guard !pendingGlareBusy.isEmpty else { return }
        pendingGlareBusy = []
        recheckIncomingWhenIdle = true
    }
    /// The live "Ringing" row write (audit M-109, 2026-10-07). The final record and the row delete
    /// both wait on it, so a slow ringing write can never land after them and leave a row behind.
    private var ringRowTask: Task<Void, Never>?

    func startCall(to uid: String, name: String, photo: String? = nil, video: Bool = false,
                   fromProfile: Bool = false) {
        guard !uid.isEmpty, !me.isEmpty else { return }   // never start with an empty caller id
        // Owner audit 2026-10-06 #31: the 1-2s `.ended` tail is cosmetic (see observeIncoming), so a
        // call placed inside it takes over instead of being dropped; and a call placed while another
        // is live says so, with the same notice the group-call side already shows, instead of a
        // button that silently does nothing.
        closeEndedTail()
        // A SECOND TAP ON THE SAME CALL BUTTON (audit M-155, 2026-10-07): the first tap has just
        // started this very call, and answering the second with "You're already in a call" put a
        // busy alert over the call screen that was opening. Same person, under a second: ignore it.
        if state == .outgoing, otherUid == uid, let t = dialStartedAt, Date().timeIntervalSince(t) < 1 { return }
        // 1:1 audit r2 B4, 2026-10-08: a call button for the person this call is already with
        // brings the call back, before any other check, as the reference app does.
        if otherUid == uid, state == .outgoing || state == .active || state == .reconnecting {
            minimized = false
            return
        }
        guard state == .idle else {
            MainActor.assumeIsolated { GroupCallService.presentOverTop(GroupCallService.busyNotice) }
            return
        }
        // 2026-09-24 decision D25: a 1:1 call and a group call never run at once. Refused with a
        // message while a group call is live or joining. Every caller of startCall is a view, so this
        // runs on the main actor, where GroupCallService lives.
        // Waiting at a link's door counts too (audit M-016, 2026-10-07): on approval the room
        // connects and publishes the mic, so a 1:1 placed during the wait would be heard there.
        let inGroupCall = MainActor.assumeIsolated { () -> Bool in
            let group = GroupCallService.shared
            guard group.isActive || group.connecting || group.waitingForApproval else { return false }
            GroupCallService.presentOverTop(GroupCallService.busyNotice)
            return true
        }
        if inGroupCall { return }
        // ONE central block gate (audit). The profile's call tiles learned to hide while blocked, but
        // every other dial site — the Calls tab row button, its long-press menu, New Call, Calls
        // search — still rang a person the user had blocked. Gating here covers all of them at once
        // and cannot be missed by a future entry point.
        // 2026-09-26 block rebuild: my account list decides, so a person blocked with no chat is
        // covered too; and the answer is a question, not silence: "Unblock <name>?", the way the
        // reference apps meet a call to somebody you blocked.
        let blocked = BlockList.snapshot.contains(uid)
            || (ConversationsRepository.shared.conversations
                .first { $0.id == ChatService.convId(me, uid) }?.isBlockedByMe(me) ?? false)
        guard !blocked else {
            MainActor.assumeIsolated { Self.offerUnblock(uid: uid, name: name) }
            return
        }
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
        // 1:1 audit r2 B7, 2026-10-08: no network, no dial. Said at once, with no system call and
        // no Recents entry, instead of "Calling..." until the create fails.
        guard NetworkState.shared.isOnline else {
            MainActor.assumeIsolated {
                GroupCallService.presentOverTop(GroupCallService.Notice(
                    title: "No Internet Connection", message: "Connect to the internet to make a call."))
            }
            return
        }
        // 1:1 audit r2 B1/B2, 2026-10-08: microphone (and camera for video) settled BEFORE any
        // CallKit call or call doc exists, as the reference app does. A prompt re-enters startCall.
        guard callPermissionsReady(uid: uid, name: name, photo: photo, video: video, fromProfile: fromProfile) else { return }
        // 1:1 audit r2 B5, 2026-10-08: an account known to be deleted is not rung at all.
        guard !Self.isGoneAccount(uid) else {
            MainActor.assumeIsolated { GroupCallService.presentOverTop(Self.goneNotice) }
            return
        }
        cameraOn = video   // a video call = my camera on from the start (the callee's is independent)
        startedAsVideo = video
        noteVideo()
        isCaller = true
        otherUid = uid
        resolvePeerTrust()   // decide direct-vs-relay now, while we are off the WebRTC threads
        warmSignalKey(fresh: true)   // #27: the callee's key, fresh, while the dial waits on TURN
        otherName = Self.displayName(for: uid, fallback: name)
        otherRawName = name   // audit M-151: never the nickname
        otherPhotoUrl = photo
        dialAttempt &+= 1
        let attempt = dialAttempt
        dialStartedAt = Date()   // audit M-155
        dialCreateStarted = false   // audit round 2 (V1 on M-112): never inherited from an earlier dial
        state = .outgoing
        checkAccountExists(uid, attempt: attempt)   // 1:1 audit r2 B5
        // iOS's own call UI and the recents list get the nickname too — the lock screen saying one
        // name while the app says another is worse than either being wrong on its own.
        // 1:1 audit r2 B3/G4, 2026-10-08: the peer's uid decides Recents; a start iOS refuses ends
        // THIS dial only, as "Call failed" (not a silent close).
        CallKitManager.shared.startOutgoing(name: otherName, video: video, peerUid: uid) { [weak self] in
            self?.failOutgoing(attempt: attempt)
        }   // native call UI + audio session (#32: as video)
        CallKitManager.shared.reportConnecting()

        ensureMicPermission { [weak self] granted in
            guard let self else { return }
            // #10: a late answer to the mic prompt belongs to the dial that asked. A "denied" landing
            // after a cancel-and-redial used to end the NEW call.
            guard self.dialAttempt == attempt else { return }
            guard granted else { self.endForDeniedMic(); return }   // no mic -> don't start a dead call
            // TURN creds must be in hand BEFORE makePeerConnection reads `config` — see awaitIceServers.
            Task { @MainActor in
                await self.awaitIceServers()
                await self.awaitPeerTrust()   // 2026-09-24 fix-all #231
                await self.awaitRelayForStranger()
                let keyOk = await self.ensureSignalKey(uid)   // 1:1 audit r2 G2, 2026-10-08
                // cancelled while we waited, or cancelled and redialled (#10: same state, other call)
                guard self.state == .outgoing, self.dialAttempt == attempt else { return }
                // 2026-09-24 audit: no relay for a stranger → fail, never go direct.
                if self.strangerWithoutRelay { self.endReason = .failed; self.hangUp(); return }
                // 1:1 audit r2 G2, 2026-10-08: no key for them = no call, never unsealed signalling.
                if !keyOk {
                    self.endReason = .failed; self.hangUp()
                    GroupCallService.presentOverTop(GroupCallService.Notice(
                        title: "Can't call right now.", message: "Try again."))
                    return
                }
                self.beginOutgoingMedia(to: uid, attempt: attempt)
            }
        }
    }

    /// Owner audit 2026-10-06 #9: a dial that broke on THIS phone (no offer, no local description,
    /// the call doc refused or unreachable) is a failed call, not the other person's "No answer".
    /// Only while it is still the same dial; a late error must not end a newer call.
    private func failOutgoing(attempt: Int) {
        guard Thread.isMainThread else { DispatchQueue.main.async { self.failOutgoing(attempt: attempt) }; return }
        guard dialAttempt == attempt, state == .outgoing else { return }
        endReason = .failed
        hangUp()
    }

    // The media half of startCall, split out so the TURN wait can sit between the mic prompt and here.
    private func beginOutgoingMedia(to uid: String, attempt: Int) {
            // RINGBACK IS STARTED BY THE AUDIO SESSION, NOT HERE (2026-07-29), AND NOT BEFORE THE
            // OTHER PHONE RINGS (2026-10-07). Starting it at this point plays into a session CallKit
            // has not activated yet: on some devices that is silent, on others briefly audible, and
            // every scheme that then corrected it on activation was either a stutter (stop+start) or
            // a permanent silence (leave-a-"playing"-but-mute-player alone; AVAudioPlayer reports
            // isPlaying = true even when the session was dead, which is the bug the user heard: one
            // blip, then nothing for the rest of the call). One start, on a live session, once
            // `ringingAt` has landed, is the only version with no failure mode. See
            // audioSessionActivated for the gate, and the fallback that covers an activation that never comes.
            self.startNoAnswerTimeout() // give up after ~45s -> Missed
            self.mark("dialled")   // the caller's origin: everything on this side is measured from here
            let ref = self.db.collection("calls").document()
            self.callId = ref.documentID
            self.pc = self.makePeerConnection()
            let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
            // #9: no peer connection, no offer, no local description = nothing ever left this phone.
            // The dial's OWN connection is held here, so a late completion can never act on the
            // connection of a newer dial (#10).
            guard let dialPc = self.pc else { self.failOutgoing(attempt: attempt); return }
            dialPc.offer(for: constraints) { [weak self] sdp, err in
                guard let self else { return }
                guard err == nil, let sdp else { self.failOutgoing(attempt: attempt); return }
                guard let pc = self.pc, pc === dialPc else { return }   // this dial already torn down
                let local = self.withOpusDtxAndRed(sdp)
                pc.setLocalDescription(local) { err in
                    if err != nil { self.failOutgoing(attempt: attempt); return }
                    var data: [String: Any] = [
                        "caller": self.me,
                        "callee": uid,
                        "callerName": ProfileStore.shared.me?.name ?? "Caller",
                        "callerPhoto": ProfileStore.shared.me?.photoUrl ?? "",
                        "type": self.cameraOn ? "video" : "voice",
                        "status": "ringing",
                        "cams": [self.me: self.cameraOn],   // seed my camera state (per-side)
                        "caps": [self.me: [Self.screenCap]],   // screen share v3 capability
                        "createdAt": FieldValue.serverTimestamp(),
                    ]
                    // Muted during "Calling..." (audit M-051, 2026-10-07): say so from the first doc,
                    // so the callee's muted icon is right from the first frame of the call.
                    if self.isMuted || self.isHeld { data["muted"] = [self.me: true] }
                    // Owner audit 2026-10-06 #27: the offer goes out sealed, and that decides the
                    // whole call (see `sealSignalling`). Keys come from memory or disk only (warmed
                    // at dial), so this never waits on the network. No key for the callee yet = the
                    // old plaintext offer and no `sig`, so the call still connects.
                    if let enc = Crypto.shared.encryptForConversationIfCached(ChatService.convId(self.me, uid), local.sdp) {
                        self.sealSignalling = true
                        data["offerEnc"] = enc
                        data["sig"] = 2
                    } else {
                        // 1:1 audit r2 G2, 2026-10-08: never a plaintext offer; the key was
                        // checked before the dial (`ensureSignalKey`), so this is a lost key.
                        self.sealSignalling = false
                        print("call: G2 no key for the callee at offer time, dial failed")
                        self.failOutgoing(attempt: attempt)
                        return
                    }
                    // ⛔ ONLINE-ONLY CREATE (owner audit 2026-10-06 #9). A plain setData made offline is
                    // QUEUED, never errors, and never completes: the caller sat on "Calling" for 45s,
                    // logged a "Missed call", and when the network came back the queued create
                    // flushed and the server rang the other phone for a call long over (the push
                    // fires on create, and the end queued behind it is too late to stop it). A
                    // transaction is never queued: it reaches the server or it fails, so an offline
                    // dial ends as "Call failed" in seconds and can never ring anyone later. Same
                    // single write, same rules, one round trip like the ack this used to wait for.
                    let createData = data   // a constant for the transaction block (#27 made `data` a var)
                    // Audit M-112: from here the other phone may see it. Set on main and only for the
                    // dial that is still current (round 2, V1): this completion runs on the WebRTC
                    // thread, and a stand-down that finished just before it left the flag true for
                    // the next dial.
                    DispatchQueue.main.async {
                        if self.dialAttempt == attempt, self.state == .outgoing { self.dialCreateStarted = true }
                    }
                    self.db.runTransaction({ txn, _ -> Any? in
                        txn.setData(createData, forDocument: ref)
                        return nil
                    }) { [weak self] _, err in
                        guard let self else { return }
                        // write failed -> don't leave the caller ringing into the void, and say Failed
                        if let err {
                            // 1:1 audit #25 (owner, 2026-10-08): no call of mine exists, so a crossing
                            // call I won is not busied; it rings here once this dial is over.
                            if self.dialAttempt == attempt { self.releaseGlareLosers() }
                            // Reported first (owner, 2026-10-08): a refused session starts recovery.
                            // A block refuses with the same code; recovery then finds nothing wrong.
                            Self.reportToRecovery(err, "call create")
                            // ⛔ EXCEPT A RULE REFUSAL. The rules refuse this create when the callee
                            // blocked me, and a block must stay indistinguishable from a call nobody
                            // took (block rebuild 2026-09-26). "Call failed" there would name it, so a
                            // refusal ends exactly as it always did: "Couldn't reach them", the ended
                            // tone, a missed row. 7 = permissionDenied by wire number, as PushManager.
                            // `.declined` because finishCall turns a never-placed .none/.missed into
                            // .failed; the caller's screen, tone and row treat .declined exactly like
                            // .missed (declines are hidden everywhere, owner 2026-08-12).
                            // ⛔ BUT NO ROW (audit M-013, 2026-10-07). The record goes into the chat both
                            // people share, so the "missed row" above landed in the callee's chat, Calls
                            // tab and badge: a refused caller could fill the history of the person who
                            // refused them, one row per retry. The screen and tone stay as they were.
                            let ns = err as NSError
                            if ns.domain == FirestoreErrorDomain, ns.code == 7 {
                                if self.dialAttempt == attempt, self.state == .outgoing {
                                    self.endReason = .declined
                                    self.recordWritten = true
                                    self.hangUp()
                                }
                                return
                            }
                            self.failOutgoing(attempt: attempt)
                            return
                        }
                        if self.state != .outgoing || self.dialAttempt != attempt {
                            // Caller hung up while the create was in flight: finishCall's update hit a
                            // not-yet-existing doc, so end it here or it would ring the callee later.
                            // As a ring the caller gave up on (audit M-037, 2026-10-07): `missed` plus
                            // `cancelledAt`, the same end the no-answer timeout writes, not `hangup`.
                            ref.updateData(["status": "ended", "endReason": EndReason.missed.rawValue,
                                            "cancelledAt": FieldValue.serverTimestamp()])
                            return
                        }
                        self.callDocCreated = true
                        self.flushGlareBusy()   // 1:1 audit #25: my call exists now, the loser may stand down
                        // THE LIVE RING ROW (owner's 2026-08-12 reference): the chat shows the call
                        // while it happens — "Ringing" now, finalised in place by recordCall.
                        self.liveRingRowId = ref.documentID
                        let ringCid = [self.me, uid].sorted().joined(separator: "_")
                        // Held (audit M-109): finishCall's record and row delete wait on this write.
                        self.ringRowTask = Task { await ChatService.recordCallRinging(cid: ringCid, callId: ref.documentID,
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

    /// Mic refused (either side). Ends as a failure, never a miss or a decline, and flags it so the
    /// call screen can say why. Same teardown as every other end, through hangUp.
    private func endForDeniedMic() {
        guard state != .ended, state != .idle else { return }
        micDenied = true
        endReason = .failed
        hangUp()
    }

    /// 1:1 audit r2 B5, 2026-10-08: accounts this phone has seen deleted (no users doc, or `isHidden`
    /// during the deletion grace period). A call to one rang 45 s into nothing and logged a missed row.
    private static let goneLock = NSLock()
    nonisolated(unsafe) private static var goneAccounts: Set<String> = []
    @MainActor static var goneNotice: GroupCallService.Notice {
        GroupCallService.Notice(title: "Can't Call", message: "This account no longer exists.")
    }

    static func isGoneAccount(_ uid: String) -> Bool {
        goneLock.lock(); defer { goneLock.unlock() }
        return goneAccounts.contains(uid)
    }

    /// Any screen that learns an account is deleted (or back) may tell this too.
    static func noteAccount(_ uid: String, gone: Bool) {
        guard !uid.isEmpty else { return }
        goneLock.lock(); defer { goneLock.unlock() }
        if gone { goneAccounts.insert(uid) } else { goneAccounts.remove(uid) }
    }

    /// 1:1 audit r2 B5: one server read of the callee's profile during the dial. Deleted: the dial
    /// ends at once with "This account no longer exists", no row, and the next tap is refused up front.
    private func checkAccountExists(_ uid: String, attempt: Int) {
        Task { [weak self] in
            guard let snap = try? await Firestore.firestore().collection("users").document(uid)
                    .getDocument(source: .server) else { return }
            let gone = !snap.exists || (snap.data()?["isHidden"] as? Bool) == true
            await MainActor.run {
                Self.noteAccount(uid, gone: gone)
                guard gone, let self, self.dialAttempt == attempt, self.state == .outgoing,
                      !self.calleeAccepted else { return }
                self.recordWritten = true   // no "Missed call" row for a call nobody could take
                self.finishCall(updateRemote: true, clearCallKit: true, localUser: true)
                GroupCallService.presentOverTop(Self.goneNotice)
            }
        }
    }

    /// 1:1 audit r2 B1/B2, 2026-10-08: the reference app's pre-dial check. True when the microphone
    /// (and for video the camera) is granted. A refusal shows an alert with a Settings button and
    /// places nothing; an unanswered permission is asked here and, once answered, the dial starts
    /// again through `startCall` (every gate runs again). A video call with the camera refused
    /// offers a voice call instead. Never with a call object, CallKit call or call doc in existence.
    private func callPermissionsReady(uid: String, name: String, photo: String?, video: Bool,
                                      fromProfile: Bool) -> Bool {
        let redial: (Bool) -> Void = { [weak self] asVideo in
            DispatchQueue.main.async {
                self?.startCall(to: uid, name: name, photo: photo, video: asVideo, fromProfile: fromProfile)
            }
        }
        switch AVAudioApplication.shared.recordPermission {
        case .granted: break
        case .undetermined:
            AVAudioApplication.requestRecordPermission { ok in
                DispatchQueue.main.async {
                    if ok { redial(video) } else { Self.presentPermissionAlert(camera: false, voiceInstead: nil) }
                }
            }
            return false
        default:
            Self.presentPermissionAlert(camera: false, voiceInstead: nil)
            return false
        }
        guard video else { return true }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { ok in
                DispatchQueue.main.async {
                    if ok { redial(true) } else { Self.presentPermissionAlert(camera: true, voiceInstead: { redial(false) }) }
                }
            }
            return false
        default:
            Self.presentPermissionAlert(camera: true, voiceInstead: { redial(false) })
            return false
        }
    }

    /// 1:1 audit r2 B1/B2: "access is off" with a Settings button (and "Voice Call" for a refused
    /// camera). A UIKit alert on whatever is on top, the `offerUnblock` pattern.
    private static func presentPermissionAlert(camera: Bool, voiceInstead: (() -> Void)?, tries: Int = 4) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { presentPermissionAlert(camera: camera, voiceInstead: voiceInstead, tries: tries) }
            return
        }
        MainActor.assumeIsolated {
            guard let top = WebLink.topViewController(), !(top is UIAlertController) else { return }
            if top.isBeingPresented || top.isBeingDismissed {
                guard tries > 0 else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    presentPermissionAlert(camera: camera, voiceInstead: voiceInstead, tries: tries - 1)
                }
                return
            }
            let alert = UIAlertController(
                title: camera ? "Camera Access Is Off" : "Microphone Access Is Off",
                message: camera ? "Allow Kulan to use the camera in Settings to make video calls."
                                : "Allow Kulan to use the microphone in Settings to make calls.",
                preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            if let voiceInstead {
                alert.addAction(UIAlertAction(title: "Voice Call", style: .default) { _ in voiceInstead() })
            }
            alert.addAction(UIAlertAction(title: "Settings", style: .default) { _ in
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            })
            top.present(alert, animated: true)
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
        let attachedAs = me
        ringingWatchId = id
        ringingWatcher = db.collection("calls").document(id).addSnapshotListener { [weak self] snap, err in
            guard let self else { return }
            // NOT THIS ACCOUNT'S CALL (audit M-157, 2026-10-07). The rules let only the caller and the
            // callee read a call doc, so a ring this account may not read is a push that reached a
            // phone signed into somebody else (a token left behind by a sign-out). The ghost-call
            // guard below needs the doc and never got it, so the phone rang its full 60s. Only when
            // the listener was attached as a signed-in user who is still signed in: a cold launch
            // before auth loads must never end a real call this way.
            if let err = err as NSError?, err.domain == FirestoreErrorDomain, err.code == 7,
               !attachedAs.isEmpty, attachedAs == self.me, self.callId == id, self.state == .incoming {
                self.ringingWatcher?.remove(); self.ringingWatcher = nil
                // Owner, 2026-10-08: a refused SESSION (not a foreign ring) looks the same here and
                // used to kill real rings. Fresh token and one server read first: end quietly only if
                // that read is still refused or the doc is really gone; otherwise listen again.
                Task { @MainActor [weak self] in
                    _ = try? await Auth.auth().currentUser?.getIDTokenResult(forcingRefresh: true)
                    var stillGone = false
                    do {
                        let fresh = try await Firestore.firestore().collection("calls").document(id).getDocument(source: .server)
                        stillGone = !fresh.exists
                    } catch {
                        let ns = error as NSError
                        stillGone = ns.domain == FirestoreErrorDomain && ns.code == 7
                    }
                    guard let self, self.callId == id, self.state == .incoming else { return }
                    let firstRecheck = self.ringRechecked.insert(id).inserted
                    if stillGone || !firstRecheck {
                        print("[Recovery] ring watch: call doc still refused or gone, ending quietly")
                        self.recordWritten = true
                        self.finishCall(updateRemote: false, clearCallKit: true, localUser: true)
                    } else {
                        print("[Recovery] ring watch: call doc readable again, re-attaching")
                        self.watchRingingCancel(id)
                    }
                }
                return
            }
            // Any other error leaves this watcher dead (owner, 2026-10-08). The registration is kept,
            // not cleared: non-nil still means "this ring is still wanted", and every end clears it.
            if let err {
                guard self.ringingWatcher != nil, self.ringingWatchId == id else { return }
                self.callListenerFailed(err, "call ring watch", callId: id) { [weak self] in
                    guard let self, self.ringingWatcher != nil, self.ringingWatchId == id else { return }
                    self.watchRingingCancel(id)
                }
                return
            }
            guard let d = snap?.data() else { return }
            if self.callId == id, self.currentCallCreatedAt == nil {
                self.currentCallCreatedAt = (d["createdAt"] as? Timestamp)?.dateValue()   // audit M-005/M-035
            }
            // Audit M-039: `ringingAt` is THIS phone's own server-timestamp write from a moment ago,
            // so the gap to the local clock is the clock's error. Learnt once per call.
            if self.callId == id, self.state == .incoming, let rt = (d["ringingAt"] as? Timestamp)?.dateValue() {
                self.learnClockSkew(serverNow: rt, callId: id)
            }
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
            // Accepted on this phone but `observeCallDoc` not attached yet (audit M-110, 2026-10-07):
            // the slow answer path keeps this watcher until then, so a caller who hangs up during
            // the answer build is heard here instead of by nobody.
            let endedWhileAnswering = self.state == .active && self.wasAccepted && self.callId == id
            if (d["status"] as? String) == "ended", self.state == .incoming || endedWhileAnswering {
                self.ringingWatcher?.remove(); self.ringingWatcher = nil
                let reason = EndReason(rawValue: d["endReason"] as? String ?? "") ?? .hangup
                if self.state == .incoming, self.endRingQuietlyIfSettledElsewhere(d, reason: reason) { return }
                self.remoteEnded(reason: reason)
                return
            }
            if endedWhileAnswering { return }   // the rest of this watcher is about a ringing phone
            // A RING THAT IS ALREADY OVER (owner audit 2026-10-06 #28). The listener path ignores a
            // doc older than `staleRingAge`, but a VoIP push carries no age, so a push delivered late
            // for a caller who died mid-ring (their doc still says "ringing", nothing will ever say
            // "ended") rang for our full 60s ring-out. iOS still makes us report it; this first
            // snapshot is the earliest we can read its age, and we end it here, the same way the
            // ring-out would have: written as ended, logged as missed.
            // ⚠️ ON THIS PHONE ONLY (audit M-039, 2026-10-07). The age is server time against this
            // phone's clock, and a callee whose clock ran fast ended EVERY pushed ring here, writing
            // `ended` into a live call and ending the caller's call too. The age now allows for the
            // learnt clock error and a wider slack (`ringAge`), and the end is local: no doc write and
            // no row. A real dead ring is ended on the server by the sweep, which finalises its row.
            if self.state == .incoming, self.callId == id, !self.wasAccepted,
               let ts = (d["createdAt"] as? Timestamp)?.dateValue(),
               Self.ringAge(ts) > Self.staleRingAge {
                self.ringingWatcher?.remove(); self.ringingWatcher = nil
                self.endReason = .missed
                self.recordWritten = true
                self.finishCall(updateRemote: false, clearCallKit: true, localUser: false)
                return
            }
            // ACCEPTED ON ANOTHER OF MY DEVICES, before it could claim (audit M-036, 2026-10-07):
            // `acceptedAt` is a plain write that lands ahead of the claim, and this phone has not
            // accepted (`wasAccepted` is false), so another one did. Same stand-down as below.
            if self.state == .incoming, !self.wasAccepted, d["acceptedAt"] != nil {
                self.ringingWatcher?.remove(); self.ringingWatcher = nil
                self.recordWritten = true
                self.endedElsewhere = true
                self.finishCall(updateRemote: false, clearCallKit: true, localUser: true)
                return
            }
            // ANSWERED ELSEWHERE. `voipTokens` (users/{uid}/push/tokens) is an array and every signed-in device of mine rings, but
            // this watcher only ever handled "ended" and a callee mismatch — "active" matched neither, so
            // the OTHER phones kept ringing forever after I picked up on one. This watcher is removed the
            // moment THIS device answers (see completeAnswer), so still being .incoming while the doc says
            // active means someone else took it. Stop ringing without touching the doc: the device that
            // answered owns the call now, and writing anything here would fight it.
            // ⛔ NOT WHEN WE ARE THE ONES WHO MADE IT ACTIVE. This branch means "another of my
            // devices picked up", and it infers that purely from the doc going active while this
            // phone is still ringing. Pre-negotiation publishes from this very phone during the
            // ring, so without this guard the phone reads its own write as somebody else answering
            // and ends its own call. Belt as well as braces: buildAnswer no longer writes the
            // status early either, and either fix alone would do.
            // 2026-09-24 audit: a claim by another of my devices is proof, not inference, so it
            // stops this phone ringing even while its own pre-negotiation is in flight (the branch
            // below skips every other signal in that case, and pre-negotiation never writes status).
            if Self.answeredOnOtherDevice(d), self.state == .incoming, !self.wasAccepted {
                self.ringingWatcher?.remove(); self.ringingWatcher = nil
                self.recordWritten = true
                self.endedElsewhere = true   // #20: iOS Recents says "answered elsewhere", not missed
                self.finishCall(updateRemote: false, clearCallKit: true, localUser: true)
            } else if self.preNegotiated, !self.wasAccepted, self.state == .incoming {
                // our own pre-negotiation is in flight — nobody else has answered anything
            } else if (d["status"] as? String) == "active", self.state == .incoming {
                self.ringingWatcher?.remove(); self.ringingWatcher = nil
                // No tone (localUser: true) — I did answer, just on my other phone — and no doc write,
                // which would fight the device that owns the call now. recordWritten is forced so we do
                // NOT log a missed call: the answering device writes the real record for this same
                // callId, and ours would overwrite it with "missed".
                self.recordWritten = true
                self.endedElsewhere = true   // #20
                self.finishCall(updateRemote: false, clearCallKit: true, localUser: true)
            }
        }
    }

    /// App-wide listener: ring when someone calls me.
    func observeIncoming() {
        incomingListener?.remove(); incomingListener = nil
        observeRecoveryIfNeeded()
        guard !me.isEmpty else { return }
        incomingWanted = true
        incomingDead = false
        incomingHeardServer = false
        incomingAttach += 1
        let attach = incomingAttach
        Task { await refreshIceServers() }   // warm the TURN list at launch so the first call has it

        incomingListener = db.collection("calls")
            .whereField("callee", isEqualTo: me)
            .whereField("status", isEqualTo: "ringing")
            .addSnapshotListener(includeMetadataChanges: true) { [weak self] snap, err in
                guard let self else { return }
                // ENDED IN AN ERROR (owner, 2026-10-08): the listener is dead and this phone would
                // never ring again this session. Dropped, reported, and attached again.
                if let err { self.incomingFailed(err, attach: attach); return }
                // NOT FROM THE CACHE (audit M-113, 2026-10-07). After a spell offline the first
                // snapshot is this phone's cached copy, and a doc that was "ringing" when the phone
                // went offline rang CallKit for a call long over. Wait for the server to confirm; the
                // metadata changes are included so that confirmation arrives even when nothing in the
                // docs changed.
                // Owner, 2026-10-08: skipping the cache copy is safe after a reconnect only because
                // the server's own snapshot follows on this same listener, and that one is always
                // processed. A listener that never hears the server (stalled, or died) is the real
                // danger, so `incomingHeardServer` records it and foreground / recovery attach anew.
                guard let snap, !snap.metadata.isFromCache else { return }
                if attach == self.incomingAttach { self.incomingHeardServer = true; self.incomingRetryStep = 0 }
                let docs = snap.documents
                guard !docs.isEmpty else { return }
                // EVERY RINGING DOC, NOT `documents.first` (owner audit 2026-10-06 #11). The query has
                // no order, so `.first` is whichever doc id sorts first: a zombie (caller crashed
                // mid-ring) could be that one, hit the age check below and `return`, and the live call
                // sitting second in the same snapshot was never rung or busied at all. Now: drop the
                // zombies, keep only each caller's NEWEST doc (an older one from the same person is a
                // call they already gave up on), and settle them oldest first, so when two different
                // people ring at once the first one rings and the second is busied.
                let now = Date()
                func created(_ doc: QueryDocumentSnapshot) -> Date {
                    (doc.data()["createdAt"] as? Timestamp)?.dateValue() ?? now
                }
                // H3: ignore zombie ringing docs (caller crashed mid-ring) so they don't re-ring forever.
                // Audit M-039: the age allows for this phone's learnt clock error (`ringAge`).
                let fresh = docs.filter { Self.ringAge(created($0)) <= Self.staleRingAge }
                var newestPerCaller: [String: QueryDocumentSnapshot] = [:]
                var superseded: [QueryDocumentSnapshot] = []
                for doc in fresh {
                    let caller = doc.data()["caller"] as? String ?? ""
                    if let kept = newestPerCaller[caller] {
                        if created(kept) >= created(doc) { superseded.append(doc); continue }
                        superseded.append(kept)
                    }
                    newestPerCaller[caller] = doc
                }
                // An older ring from someone who has since rung again is a call they gave up on
                // (audit M-006, 2026-10-07). End it quietly, as missed, so it cannot come back as
                // the only doc in a later snapshot and be rung, or tear down the newer call. Never
                // the call this phone is in.
                for doc in superseded where doc.documentID != self.callId {
                    doc.reference.updateData(["status": "ended", "endReason": EndReason.missed.rawValue])
                }
                for doc in newestPerCaller.values.sorted(by: { created($0) < created($1) }) {
                    self.handleRingingDoc(doc)
                }
            }
    }

    // MARK: - Listener recovery (owner, 2026-10-08)

    /// The incoming listener ended in an error. Drop it, tell SessionRecovery, and attach again:
    /// a refusal waits for `recovered` (or foreground); anything else retries after 5s, 15s, 30s,
    /// then every 60s while the app is open.
    private func incomingFailed(_ err: Error, attach: Int) {
        guard attach == incomingAttach else { return }   // an older listener, already replaced
        incomingListener?.remove(); incomingListener = nil
        incomingDead = true
        Self.reportToRecovery(err, "incoming calls")
        guard !Self.isRefusal(err) else { return }
        let delays: [Double] = [5, 15, 30, 60]
        let delay = delays[min(incomingRetryStep, delays.count - 1)]
        incomingRetryStep += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.incomingWanted, self.incomingDead, attach == self.incomingAttach else { return }
            print("[Recovery] incoming calls: attached again after \(Int(delay))s")
            self.observeIncoming()
        }
    }

    /// A live call's listener (ring watch, call doc, candidates) ended in an error. Report it; a
    /// refusal is attached again by `recovered`, anything else after 3s, while the same call lives.
    private func callListenerFailed(_ err: Error, _ what: String, callId id: String?, reattach: @escaping () -> Void) {
        Self.reportToRecovery(err, what)
        guard !Self.isRefusal(err) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.callId == id, self.state != .idle, self.state != .ended else { return }
            print("[Recovery] \(what): attached again after 3s")
            reattach()
        }
    }

    /// Recovery observers, registered once from observeIncoming (the shell calls it at launch).
    private func observeRecoveryIfNeeded() {
        guard !recoveryObserved else { return }
        recoveryObserved = true
        NotificationCenter.default.addObserver(forName: SessionRecovery.recovered, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            // Every listener comes back, healthy or not: removing and re-adding one is cheap and
            // the contract says re-attach when unsure.
            if self.incomingWanted {
                print("[Recovery] incoming calls: attached again after recovery")
                self.observeIncoming()
            }
            self.reattachCallListeners("recovery")
        }
        NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            guard let self, self.incomingWanted, self.incomingDead || !self.incomingHeardServer else { return }
            print("[Recovery] incoming calls: attached again on foreground")
            self.observeIncoming()
        }
    }

    /// Attach the live call's listeners again. Safe on a healthy one: the doc handler's steps are
    /// each latched (calleeAccepted, remoteDescription, appliedRemoteRestart, restartRequestsSeen,
    /// state), and candidates already applied are skipped by `appliedCandidateIds`.
    private func reattachCallListeners(_ why: String) {
        guard state != .idle, state != .ended, let id = callId else { return }
        if ringingWatcher != nil, ringingWatchId == id {
            print("[Recovery] call ring watch: attached again after \(why)")
            watchRingingCancel(id)
        }
        if let ref = callDocWatch, ref.documentID == id {
            print("[Recovery] call signalling: attached again after \(why)")
            observeCallDoc(ref)
        }
        if let col = candidatesWatch, col.parent?.documentID == id {
            print("[Recovery] call routes: attached again after \(why)")
            observeRemoteCandidates(col)
        }
    }

    /// 7 = permission denied, 16 = unauthenticated, by wire number as elsewhere in this file.
    private static func isRefusal(_ err: Error) -> Bool {
        let ns = err as NSError
        return ns.domain == FirestoreErrorDomain && (ns.code == 7 || ns.code == 16)
    }

    /// Console only, never on screen. SessionRecovery decides whether the error is one it acts on.
    private static func reportToRecovery(_ err: Error, _ from: String) {
        print("[Recovery] \(from) failed:", err)
        Task { @MainActor in SessionRecovery.noteRefusal(err, from) }
    }

    /// A ring older than this is over: the caller's own no-answer timeout (45s) has already ended
    /// it, or the caller died mid-ring and never will. Five seconds of slack for the two phones'
    /// clocks, since `createdAt` is the server's time and the comparison uses this phone's.
    /// (Was a separate 60 on the listener; shared now with the push path, owner audit 2026-10-06 #28.)
    /// 120 since audit M-039 (2026-10-07): a callee whose clock ran 50s fast never rang at all. The
    /// age is now measured with the learnt clock error taken off (`ringAge`), and the slack is wide
    /// enough for a phone that has not learnt it yet. A dead ring older than this is still ended on
    /// the server by the five-minute sweep; this test only keeps one from ringing here.
    private static let staleRingAge: TimeInterval = 120

    /// This phone's clock minus the server's, learnt from a server timestamp this phone wrote a
    /// moment ago (audit M-039, 2026-10-07). Zero until the first call teaches it. The error it
    /// carries (the write's round trip) only ever makes a ring look younger, the safe direction.
    private static var clockSkew: TimeInterval = 0
    private var skewLearntFor: String?
    private func learnClockSkew(serverNow: Date, callId: String) {
        guard skewLearntFor != callId else { return }
        skewLearntFor = callId
        Self.clockSkew = Date().timeIntervalSince(serverNow)
    }
    /// How old a server-stamped ring is, in server time.
    private static func ringAge(_ created: Date) -> TimeInterval {
        Date().timeIntervalSince(created) - clockSkew
    }

    /// The current call doc's server `createdAt`, when this phone has seen it (audit M-005, M-006,
    /// M-035, 2026-10-07). The "same person calling again" rules used to act on arrival order alone,
    /// so an OLDER leftover doc, or a late push for the caller's previous call, tore down the newer
    /// call. They act now only for a doc created after this one. Cleared in `finishCall`.
    private var currentCallCreatedAt: Date?

    /// Is this ringing doc newer than the call this phone is in? Unknown on either side counts as
    /// newer, which is the rule as it was before ordering existed. A doc whose `createdAt` is still
    /// a pending server stamp was written just now, so it is newer too.
    private func isNewerThanCurrent(_ d: [String: Any]) -> Bool {
        guard let current = currentCallCreatedAt,
              let created = (d["createdAt"] as? Timestamp)?.dateValue() else { return true }
        return created > current
    }

    /// The last finished 1:1 call ids, newest last (audit M-036, 2026-10-07). A push held by APNs, or
    /// a doc whose end write was lost, used to ring a call this phone had already finished and then
    /// log it "missed" over the real row. A ring for one of these never rings and never records.
    private var finishedCallIds: [String] = []
    private func rememberFinished(_ id: String) {
        finishedCallIds.removeAll { $0 == id }
        finishedCallIds.append(id)
        if finishedCallIds.count > 20 { finishedCallIds.removeFirst(finishedCallIds.count - 20) }
    }

    /// A ring that ended for a reason that has nothing to do with this phone missing it: ends it
    /// with no tone, no doc write and no row. Returns false when the end is an ordinary one.
    ///  · `busy` on the callee side means ANOTHER of my devices was in a call and busied the shared
    ///    doc (audit M-043, 2026-10-07). This free device used to stop with a busy tone.
    ///  · an accept or another device's claim on the doc means the call was answered elsewhere and
    ///    has since ended (audit M-036): logging "missed" here would overwrite the real row.
    private func endRingQuietlyIfSettledElsewhere(_ d: [String: Any], reason: EndReason) -> Bool {
        guard !isCaller, state == .incoming, !wasAccepted else { return false }
        // 1:1 audit r2 C2, 2026-10-08: declined on my other device ends quietly too, as the cancel
        // push path does, and both tell iOS "declined elsewhere".
        if reason == .busy || reason == .declined {
            recordWritten = true
            endReason = reason
            declinedElsewhere = true
            finishCall(updateRemote: false, clearCallKit: true, localUser: true)
            return true
        }
        if d["acceptedAt"] != nil || Self.answeredOnOtherDevice(d) {
            recordWritten = true
            endedElsewhere = true
            finishCall(updateRemote: false, clearCallKit: true, localUser: true)
            return true
        }
        return false
    }

    /// Doc ids whose block/privacy gate is still reading, so a second snapshot that carries the same
    /// ringing doc does not start a second gate (and ring it twice, or busy it against itself).
    private var gatingIncoming = Set<String>()

    /// Is a group / ad-hoc / link call live or still joining? (Decision D25: a 1:1 call and a group
    /// call never run at once.) Both incoming paths run on the main thread: Firestore delivers on
    /// the main queue, PushKit is registered on `.main`, and the gate hops back with main.async.
    private var inGroupCall: Bool {
        // `assumeIsolated` traps off the main thread. Both callers are on main today; if that ever
        // changes, answering "not busy" (the old behaviour) beats crashing during an incoming ring.
        guard Thread.isMainThread else { return false }
        // `waitingForApproval` too (audit M-016, 2026-10-07): parked at a link's door is a call this
        // phone has claimed, and approval connects it with the mic live.
        return MainActor.assumeIsolated {
            GroupCallService.shared.isActive || GroupCallService.shared.connecting
                || GroupCallService.shared.waitingForApproval
        }
    }

    /// The ad-hoc room I am in, when the person calling is one of its members (audit M-091,
    /// 2026-10-07). Such a caller is somebody who dropped out of this very call and is trying to
    /// get back to me; "busy" left them outside with no sign on my screen. Main thread only.
    /// ONLY SOMEONE WHO WAS IN THE ROOM (audit round 2, V1 on M-091, 2026-10-07). `members` is
    /// everyone invited, so an invitee who declined or never answered and then rang me 1:1 was put
    /// live into the group call, mic on, without being asked. `joinedUids` is everyone who ever
    /// connected to this room; anyone else is answered busy as before.
    private func adhocRoomIncluding(_ caller: String) -> (roomId: String, name: String)? {
        guard Thread.isMainThread, !caller.isEmpty else { return nil }
        return MainActor.assumeIsolated { () -> (roomId: String, name: String)? in
            let group = GroupCallService.shared
            guard case .adhoc(let roomId)? = group.activeRoom, roomId.hasPrefix("adhoc_"),
                  group.joinedUids.contains(caller),
                  let member = group.members.first(where: { $0.uid == caller }) else { return nil }
            return (roomId, Self.displayName(for: caller, fallback: member.name))
        }
    }

    /// Send a caller who belongs to my ad-hoc room back into it (audit M-091, 2026-10-07): the same
    /// `moveTo` + `ended` write "Add people" uses, which the calling phone already follows, and a
    /// note on my screen. No busy, no row: nobody missed anything.
    private func sendBackToRoom(docId: String, roomId: String, name: String) {
        db.collection("calls").document(docId)
            .updateData(["moveTo": roomId, "status": "ended", "endReason": EndReason.hangup.rawValue])
        MainActor.assumeIsolated { GroupCallService.shared.showToast("\(name) is rejoining the call") }
    }

    /// Settle a ringing doc against whatever call this phone is already in. Returns true when the doc
    /// has been dealt with (it IS the current call, it was busied, or glare decided it); false when
    /// this phone is free to ring it. Shared by the listener and by its gate's completion, so a call
    /// that arrives while the gate is reading is busied too, not dropped (owner audit 2026-10-06 #11).
    private func settleAgainstCurrentCall(docId: String, data d: [String: Any]) -> Bool {
        let caller = d["caller"] as? String ?? ""
        // BOTH "SAME PERSON AGAIN" RULES BELOW ARE FOR A NEWER CALL ONLY (audit M-006, 2026-10-07).
        // A leftover older doc from the same caller (their end write was lost) reached them after
        // the callee answered the newer one, and tore that answered call down to ring a dead one.
        // An older doc is a call they already gave up on: end it quietly, leave this call alone.
        if docId != callId, !caller.isEmpty, caller == otherUid,
           [.incoming, .active, .reconnecting].contains(state), !isNewerThanCurrent(d) {
            db.collection("calls").document(docId)
                .updateData(["status": "ended", "endReason": EndReason.missed.rawValue])
            return true
        }
        // THE SAME PERSON CALLING AGAIN WHILE WE ARE CONNECTED TO THEM means their side of our
        // call is gone (app killed, phone restarted, network lost long enough to give up),
        // and only ours is still holding on. Answering that with "busy" left them unable to
        // reach us until our side timed out. The reference engine's rule ("ReCall"): drop the
        // old call quietly and take the new one. Only while connected: a ring-time crossing
        // is glare and is settled below.
        if state == .active || state == .reconnecting, docId != callId,
           !caller.isEmpty, caller == otherUid {
            finishCall(updateRemote: true, clearCallKit: true, localUser: true)
        }
        // THE SAME PERSON CALLING AGAIN WHILE THEIR LAST CALL IS STILL RINGING HERE (owner audit
        // 2026-10-06 #11). They cancelled and redialled, and the new doc beat the old one's "ended"
        // to this phone; or their app died mid-ring and they called back. Either way the old ring is
        // dead. It was answered "busy": they heard a busy tone from someone whose phone was ringing
        // for them, and both sides got a phantom missed row. Drop the old ring as a miss (it was
        // one; no tone, the person did nothing) and let the new one ring. Not once accepted.
        if state == .incoming, !wasAccepted, docId != callId, !caller.isEmpty, caller == otherUid {
            endReason = .missed
            finishCall(updateRemote: true, clearCallKit: true, localUser: true)
        }
        // H4: already in a LIVE call → send this new caller a busy signal instead of dropping
        // them silently. `.ended` is NOT a live call: it is a cosmetic 1-2s tail before idle
        // (see finishCall), and treating it as busy meant an instant redial — or a third
        // person calling in that window — was rejected with a busy nobody was busy for, plus
        // a phantom missed row (audit).
        // A GROUP CALL IS A LIVE CALL TOO (owner audit 2026-10-06 #2). Only startCall checked it,
        // so a 1:1 call rang during a group call and could be answered: two calls, two audio
        // sessions, the mic published to both.
        let inLiveCall = [.outgoing, .incoming, .active, .reconnecting].contains(state)
        guard inLiveCall || inGroupCall else { return false }
        guard docId != callId else { return true }
        // GLARE: we dialled each other at the same moment, so we are each other's
        // "incoming call while busy" and both sides sent busy — killing BOTH calls and
        // leaving two Missed rows in one chat. Break the tie on the only thing both
        // phones already agree on: the two uids. Lower uid keeps its outgoing call and
        // busies the other; higher uid gives up its own so the survivor can ring here.
        // Only once my own dial has been sent (audit M-112, 2026-10-07): before that the other
        // phone cannot see it, nothing will make them stand down, and busying their real call for
        // a dial still waiting on the mic prompt or the relay killed the only call that existed.
        // Until then my pending dial yields, exactly as the higher uid does.
        if state == .outgoing, !caller.isEmpty, caller == otherUid {
            if me < caller, dialCreateStarted {
                // `glare` tells the loser this busy is a tiebreak, not a busy line
                // (see observeCallDoc), in case it hears this before it sees our call.
                glareBusy(docId)   // 1:1 audit #25: held until my own doc exists
                return true
            }
            standDownForGlare(rearmListener: true)
            return true
        }
        // In a multi-person call with this caller in it: send them back in, not "busy" (M-091).
        if !inLiveCall, let back = adhocRoomIncluding(caller) {
            sendBackToRoom(docId: docId, roomId: back.roomId, name: back.name)
            return true
        }
        db.collection("calls").document(docId)
            .updateData(["status": "ended", "endReason": EndReason.busy.rawValue])
        // A busy call left NO trace on this phone: the caller got a Missed row, I got
        // nothing and never learned they tried. Log it here (same deterministic doc id
        // the caller uses, same "missed" outcome, so the two writes agree).
        if !caller.isEmpty {
            let cid = [me, caller].sorted().joined(separator: "_")
            let isVideo = (d["type"] as? String) == "video"
            Task {
                await ChatService.recordCall(cid: cid, callId: docId,
                                             callerUid: caller, outcome: "missed",
                                             video: isVideo, durationSec: 0)
            }
        }
        return true
    }

    /// One ringing doc from the incoming listener: settle it against the current call, then gate it,
    /// then ring it.
    /// 1:1 audit r2 G8: rings held for the server's screening, and ones the 2 s read let through.
    private var screenWaiting: Set<String> = []
    private var screenWaitDone: Set<String> = []

    private func handleRingingDoc(_ doc: QueryDocumentSnapshot) {
        let d = doc.data()
        // A later snapshot of the call this phone is already in (settle answered this first, below).
        guard doc.documentID != self.callId else { return }
        // A call this phone already finished, or one another of my devices accepted: never rung,
        // never recorded (audit M-036, 2026-10-07).
        if finishedCallIds.contains(doc.documentID) || d["acceptedAt"] != nil
            || Self.answeredOnOtherDevice(d) { return }
        guard !self.gatingIncoming.contains(doc.documentID) else { return }
        // 1:1 audit r2 G8, 2026-10-08: the open app rang every create before the server's checks
        // (rate limit, block, privacy) could end it. A young doc rings once the server has passed
        // it (`screenedAt`, written by onCallCreated before the push; this listener sees that
        // write). An older server never writes it: after 2 s one server read decides, and only a
        // doc still ringing goes on.
        if d["screenedAt"] == nil, !screenWaitDone.contains(doc.documentID),
           let created = (d["createdAt"] as? Timestamp)?.dateValue(), Self.ringAge(created) < 4 {
            let id = doc.documentID
            if screenWaiting.insert(id).inserted {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                    guard let self, self.screenWaiting.remove(id) != nil, self.callId != id,
                          !self.finishedCallIds.contains(id) else { return }
                    self.db.collection("calls").document(id).getDocument(source: .server) { [weak self] snap, _ in
                        guard let self, let fresh = snap?.data(), (fresh["status"] as? String) == "ringing",
                              fresh["acceptedAt"] == nil, self.callId != id else { return }
                        self.screenWaitDone.insert(id)
                        self.handleRingingDoc(doc)
                    }
                }
            }
            return
        }
        screenWaiting.remove(doc.documentID)
        screenWaitDone.remove(doc.documentID)
        self.gatingIncoming.insert(doc.documentID)
        let caller = d["caller"] as? String ?? ""
        // THE SHARED GATE, not a second copy of it. This path had its own inline version of
        // the blocked + Calls-privacy check, with the same discarded read error — so the
        // comment on `callAllowed` claiming both paths shared it was simply untrue, and the
        // false-decline bug lived here twice. Silent block and Calls privacy both still
        // apply; the difference is that a read which FAILS no longer reads as a refusal.
        // ⛔ AND IT RUNS BEFORE THE BUSY DECISION NOW (audit M-014, 2026-10-07). Busy was decided
        // first, so a blocked or privacy-refused caller heard "busy" exactly when I was on another
        // call (a refusal heard as presence, which unmasks the silent block) and my phone wrote a
        // "Missed call" into the chat with them. A refused caller now gets the same silent decline
        // whether I am free or not.
        self.callAllowed(from: caller) { allowed in
            guard allowed else {
                self.gatingIncoming.remove(doc.documentID)
                self.db.collection("calls").document(doc.documentID)
                    .updateData(["status": "ended", "endReason": EndReason.declined.rawValue,
                                 "refused": true])   // audit M-013: the caller writes no row for it
                return
            }
            // WHO IS CALLING, FROM THEIR PROFILE, NOT FROM THE DOC (audit M-058, 2026-10-07). The
            // doc's `callerName`/`callerPhoto` are the caller's own words (the server corrects them
            // a moment later, after this first snapshot was read), so a caller could ring with any
            // name and picture they liked. The last copy of their profile this phone saw is a
            // local read; the doc's name is the fallback only for somebody never seen before, and
            // the server's copy then replaces it. The doc's photo url is never used.
            Task { @MainActor in
                let cached = await ProfileStore.shared.cachedPeer(caller)
                self.gatingIncoming.remove(doc.documentID)
                self.ringFromListener(doc, data: d, caller: caller, profile: cached)
            }
        }
    }

    /// The ring step of `handleRingingDoc`, once the gate has said yes and the caller's profile has
    /// been looked up. Split out only so it can run after that lookup (audit M-058, 2026-10-07).
    private func ringFromListener(_ doc: QueryDocumentSnapshot, data d: [String: Any], caller: String,
                                  profile: UserProfile?) {
        do {
            // THE BUSY DECISION, TAKEN AGAIN NOW (owner audit 2026-10-06 #11). It was made
            // only before this async read; a call I started, a push that rang, or a group
            // call I joined while it was reading left this doc to fall through the idle
            // guard below: never busied, never ended, and the caller rang out for 45s.
            if self.settleAgainstCurrentCall(docId: doc.documentID, data: d) { return }
            // A callback inside the 1-2s `.ended` tail was dropped here, and this doc never
            // changes again, so the listener never rang it (audit 2026-09-24).
            self.closeEndedTail()
            guard self.state == .idle else { return }
            self.callId = doc.documentID
            self.currentCallCreatedAt = (d["createdAt"] as? Timestamp)?.dateValue()   // audit M-006
            self.otherUid = caller
            self.resolvePeerTrust()
            self.warmSignalKey()   // #27: the caller's key, to open the sealed offer
            let publishedName = profile?.name ?? (d["callerName"] as? String ?? "Caller")
            self.otherRawName = publishedName
            self.otherName = Self.displayName(for: caller, fallback: publishedName)
            self.otherPhotoUrl = self.peerPhoto(caller)
            if profile == nil { self.refreshCallerProfile(caller, callId: doc.documentID) }
            self.isCaller = false
            let isVideoCall = (d["type"] as? String == "video")
            // Camera-on-answer model (user choice): accepting a video call opens MY camera immediately —
            // both sides see each other the instant the call connects.
            self.cameraOn = isVideoCall
            self.startedAsVideo = isVideoCall
            self.noteVideo()
            // cache → answer with no server round-trip. #27: opened here if sealed (`readOffer`).
            if let sdp = self.readOffer(d) { self.pendingOffer = ["sdp": sdp, "type": "offer"] }
            if let cams = d["cams"] as? [String: Bool], let on = cams[caller] { self.remoteCameraOn = on }
            if let screens = d["screen"] as? [String: Bool] { self.remoteScreenSharing = screens[caller] ?? false }
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
            self.mark("ring")
            // ⛔ PRE-NEGOTIATE HERE TOO. A call arrives by two different routes — a VoIP
            // push when the app is closed, and this listener when it is open — and the
            // first version of pre-negotiation was wired only into the push path, because
            // that is where the offer prefetch lives. The app-open path already HAS the
            // offer (cached two lines above), so it needed no prefetch and silently got no
            // pre-negotiation either. Measured on two phones: every mark from the ring
            // window was missing and the wait was unchanged. The path that needed the fix
            // least is the one that got it.
            if let sdp = self.pendingOffer?["sdp"] {
                self.preNegotiate(callId: doc.documentID, offerSdp: sdp)
            } else if d["offerEnc"] != nil {
                // #27: sealed, and the caller's key is still on its way (warmed above). The push
                // path's ring-time retry reads it again once the key lands and pre-negotiates.
                self.prefetchOffer(callId: doc.documentID, attempt: 1)
            }
            self.watchRingingCancel(doc.documentID)   // tear down if the caller cancels before I answer
            self.armCalleeRingTimeout(doc.documentID) // and end as MISSED if nobody ever does either
        }
    }

    /// The caller's picture from what their profile says and lets me see (audit M-058, 2026-10-07),
    /// never from a url the caller wrote into the call doc. Nil when this phone knows of none.
    private func peerPhoto(_ uid: String) -> String? {
        ProfilePhotoIndex.header(uid: uid, fallbackPhoto: nil, fallbackPoster: nil,
                                 iAmContact: PrivacyPrefs.isContact(uid)).photoUrl
    }

    /// A caller this phone had never loaded: read their profile from the server during the ring and
    /// put their real name and picture on the call (audit M-058, 2026-10-07). Only while it is still
    /// the same call. The system ring keeps the name it was reported with.
    private func refreshCallerProfile(_ uid: String, callId: String) {
        Task { @MainActor in
            guard let p = await ProfileStore.shared.fetch(uid), self.callId == callId else { return }
            self.otherRawName = p.name
            self.otherName = Self.displayName(for: uid, fallback: p.name)
            self.otherPhotoUrl = self.peerPhoto(uid)
        }
    }

    /// 1:1 audit r2 G5, 2026-10-08: the caller's name for a pushed ring, from this phone's own
    /// stores (no name travels in the push): the chat's copy of their name, from the live list or
    /// the list saved on disk (a cold launch has no list yet). The nickname is applied on top by
    /// `displayName`. Nil when this phone has never seen them.
    static func cachedCallerName(_ uid: String) -> String? {
        let me = Auth.auth().currentUser?.uid ?? ""
        guard !uid.isEmpty, !me.isEmpty else { return nil }
        let cid = ChatService.convId(me, uid)
        var conv: Conversation? = Thread.isMainThread
            ? ConversationsRepository.shared.conversations.first(where: { $0.id == cid }) : nil
        if conv == nil { conv = ConversationsDiskCache.shared.load(uid: me).first(where: { $0.id == cid }) }
        guard let n = conv?.names[uid], !n.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return n
    }

    /// 1:1 audit r2 G5: the pushed caller's real name from their profile (this phone's copy, else
    /// the server's), put on the call and on the system call screen while it still rings.
    private func refreshPushedCaller(_ uid: String, callId: String) {
        Task { @MainActor in
            var p = await ProfileStore.shared.cachedPeer(uid)
            if p == nil { p = await ProfileStore.shared.fetch(uid) }
            guard let p, self.callId == callId, self.otherUid == uid else { return }
            let shown = Self.displayName(for: uid, fallback: p.name)
            self.otherRawName = p.name
            if self.otherPhotoUrl == nil { self.otherPhotoUrl = self.peerPhoto(uid) }
            guard shown != self.otherName, !shown.isEmpty else { return }
            self.otherName = shown
            CallKitManager.shared.updateCallerName(callId: callId, name: shown)
        }
    }

    /// I lose a glare tiebreak: cancel MY outgoing call so theirs can ring here.
    /// `rearmListener`: re-arm the incoming listener once we are actually idle. Required on the
    /// listener path — their doc does not change when I stand down, so no further snapshot would
    /// ever arrive and I would sit idle while their phone rings on alone. The push path rings the
    /// call itself, so it passes false.
    private func standDownForGlare(rearmListener: Bool) {
        if rearmListener { recheckIncomingWhenIdle = true }
        endReason = .hangup
        // Standing down in glare is bookkeeping, not a missed call. Without this the loser wrote a
        // call record whose outcome reads "missed" on the WINNER's phone — a red missed row for the
        // person they are connecting with a second later (audit). Same suppression the
        // answered-elsewhere path already uses.
        recordWritten = true
        finishCall(updateRemote: true, clearCallKit: true, localUser: true)
    }

    /// Skip the cosmetic `.ended` tail so a NEW call can take over at once: end the old system call
    /// now and reset to idle. No-op in any other state. (Audit 2026-09-24.)
    private func closeEndedTail() {
        guard state == .ended else { return }
        // 1:1 audit r2 C3, 2026-10-08: the reason the call really ended, held back for the tone.
        CallKitManager.shared.reportEnded(pendingKitEnd ?? .remote)
        pendingKitEnd = nil
        state = .idle
    }

    /// Set up an incoming call from a VoIP push (app may be cold-launching) so that a
    /// subsequent CallKit answer connects. No ringing here — CallKit shows the ring.
    func prepareIncoming(callId: String, name: String, uid: String, photo: String?, video: Bool = false) {
        // 1:1 audit r2 A3, 2026-10-08: a cold launch from a VoIP push builds no UI, so the block list
        // was never started and the phone-side block check read an empty list. Idempotent; it puts
        // the saved copy from disk in place at once.
        BlockList.shared.start()
        // Busy: a VoIP push arriving mid-call must NOT overwrite the live call's identity/state (C3).
        // CRITICAL: only busy a DIFFERENT call. When the app is foreground, the Firestore listener
        // rings first and this push arrives seconds later FOR THE SAME CALL — busying it here made
        // the call end itself after ~2s of ringing (and the repeated instant-kills got our VoIP
        // pushes throttled by Apple → "sometimes doesn't ring, sometimes late").
        // GLARE ON THE PUSH PATH (audit 2026-09-24). The listener path breaks a simultaneous dial on
        // the uids; this path had no tiebreak, so when the push beat the listener, the phone that
        // should have stood down busied the winner's call instead, and both calls died.
        // A RING FOR A CALL THIS PHONE ALREADY FINISHED (audit M-036, 2026-10-07): a push APNs held
        // back, or a repeat. Never rung, never recorded. PushManager still reports it right after
        // this returns, as iOS requires; with no system call up that report is a real ring, so it is
        // ended on the next turn of the main queue, the same way the group-busy case below does it.
        if finishedCallIds.contains(callId) {
            if state == .idle {
                DispatchQueue.main.async {
                    if CallKitManager.shared.activeCallId == callId { CallKitManager.shared.reportEnded() }
                }
            }
            return
        }
        // M-112 (2026-10-07): the tiebreak applies only once my own dial has been sent; see
        // settleAgainstCurrentCall.
        if state == .outgoing, !uid.isEmpty, uid == otherUid, callId != self.callId {
            if me < uid, dialCreateStarted {
                glareBusy(callId)   // 1:1 audit #25: held until my own doc exists
                return
            }
            standDownForGlare(rearmListener: false)   // I lose: drop my call, ring theirs below
        }
        // THE SAME PERSON CALLING AGAIN, BY PUSH (audit M-005 and M-035, 2026-10-07). Two rules lived
        // here and in the listener: a redial while their last call still rings replaces the ring
        // ("owner audit 2026-10-06 #11"), and a call while we are connected to them replaces the
        // call ("ReCall"; the push path lacked it and answered busy). But a push carries no age, and
        // acting on arrival order meant a LATE push for the caller's previous call ended the redial
        // that was ringing and rang the dead call. So the current call stays put, and the pushed doc
        // is read from the server first: it replaces the current call only if it is still ringing
        // and newer (`arbitratePushedRedial`). PushManager's report after this returns lands as the
        // transient one, since a system call is already up.
        if !uid.isEmpty, uid == otherUid, callId != self.callId,
           (state == .incoming && !wasAccepted) || state == .active || state == .reconnecting {
            arbitratePushedRedial(callId: callId, name: name, uid: uid, photo: photo, video: video)
            return
        }
        // The 1-2s `.ended` tail is not a live call (see observeIncoming). A callback inside it
        // was busied here, and CallKit then rang that busied call with nothing left to end it.
        closeEndedTail()
        // A live or joining group call is busy too (owner audit 2026-10-06 #2, decision D25).
        let groupBusy = inGroupCall
        guard state == .idle, !groupBusy else {
            // A group call holds no CallKit call, so PushManager's report right after this returns
            // (iOS requires it) becomes a REAL ring rather than the transient busy one. End it on the
            // next turn of the main queue, once it exists.
            if groupBusy, state == .idle {
                DispatchQueue.main.async {
                    if CallKitManager.shared.activeCallId == callId { CallKitManager.shared.reportEnded() }
                }
            }
            // ⛔ THE PRIVACY GATE BEFORE THE BUSY (audit M-014, 2026-10-07), as on the listener path:
            // a refused caller is declined silently whether I am free or not, instead of hearing a
            // busy line exactly when I am on a call. A caller who belongs to my multi-person call is
            // sent back into it rather than busied (audit M-091).
            if callId != self.callId {
                callAllowed(from: uid) { [weak self] ok in
                    guard let self else { return }
                    let ref = self.db.collection("calls").document(callId)
                    guard ok else {
                        ref.updateData(["status": "ended", "endReason": EndReason.declined.rawValue, "refused": true])
                        return
                    }
                    if self.state == .idle || self.state == .ended, let back = self.adhocRoomIncluding(uid) {
                        self.sendBackToRoom(docId: callId, roomId: back.roomId, name: back.name)
                        return
                    }
                    ref.updateData(["status": "ended", "endReason": EndReason.busy.rawValue])
                }
            }
            return
        }
        self.cameraOn = video   // camera-on-answer model: accepting a video call opens my camera immediately
        self.startedAsVideo = video
        self.noteVideo()
        self.callId = callId
        self.otherName = Self.displayName(for: uid, fallback: name)
        self.otherRawName = name   // audit M-151: the push carries the server's copy of their name
        self.otherUid = uid
        self.resolvePeerTrust()
        self.warmSignalKey()   // #27: the caller's key, to open the sealed offer during the ring
        // 1:1 audit r2 G5, 2026-10-08: the push carries no name or photo any more. The photo comes
        // from what this phone knows of the caller's profile, and the name is corrected from the
        // profile during the ring (also on the system call screen).
        self.otherPhotoUrl = (photo?.isEmpty == false) ? photo : (uid.isEmpty ? nil : self.peerPhoto(uid))
        if !uid.isEmpty { self.refreshPushedCaller(uid, callId: callId) }
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
            // STILL REFUSED AFTER A FAST ANSWER (owner audit 2026-10-06 #30). This bailed unless the
            // call was still ringing, and a lock-screen answer inside the read had already moved it
            // to .active, so a blocked caller who rang a killed app connected. The refusal now
            // applies to the same call whether it is ringing or already answered; only the
            // ring-time work below still needs it to be ringing.
            guard let self, self.callId == callId,
                  [.incoming, .active, .reconnecting].contains(self.state) else { return }
            guard ok else {
                // Refuse WITHOUT ever having marked it ringing: from the caller's side this is the
                // same silent non-answer the foreground listener path produces.
                self.db.collection("calls").document(callId)
                    .updateData(["status": "ended", "endReason": EndReason.declined.rawValue,
                                 "refused": true])   // audit M-013: the caller writes no row for it
                self.recordWritten = true   // a blocked call leaves no trace, same as the listener path
                self.finishCall(updateRemote: false, clearCallKit: true, localUser: true)
                return
            }
            guard self.state == .incoming else { return }   // answered during the read: nothing left to do here
            self.markRinging()   // allowed — only now does the caller hear it ring
            self.mark("ring")
            // ⭐ THE OFFER, FETCHED WHILE IT IS STILL RINGING.
            //
            // The foreground listener path has cached it since it was written (`pendingOffer`, in
            // observeIncoming), so answering a call that rang while the app was open takes the fast
            // path in `answer()`. This path — a VoIP push, app killed, which is how most real
            // incoming calls arrive — cached nothing, so `answer()` fell through to
            // `fetchOfferWithRetry` and paid a round trip to Doha AFTER the finger landed, with up
            // to three attempts over three seconds if the radio was still waking up. That wait is
            // spent staring at "Connecting…".
            //
            // Nothing here is new work: it is the same read, moved into the ring, where the phone
            // is awake and doing nothing anyway. By pickup the fast path applies to both routes in.
            self.prefetchOffer(callId: callId, attempt: 1)
        }
    }

    /// A push from the person this phone is already ringing or talking to, for a DIFFERENT call
    /// (audit M-005 and M-035, 2026-10-07). Read that call from the server and decide on it:
    ///  · still ringing and newer than the current call: they redialled (or their side of our call
    ///    died and they called back). Drop the current call quietly and ring the new one.
    ///  · still ringing but older: a call they already gave up on. End it quietly, as missed.
    ///  · already over, or unreadable: nothing to do; the current call carries on.
    /// Only while the current call is still the one that was up when the push landed.
    /// 1:1 audit #6 (owner, 2026-10-08): the read is retried (3 tries, 1s then 2s apart, like
    /// `fetchOfferWithRetry`). A push wakes a radio that is often not up yet, and one failed read used
    /// to drop the redial with no ring at all. If every try fails while the current call is still
    /// only RINGING (not answered), the new push is taken as the redial and rung, since a person
    /// calling again is far likelier than a late push. If that guess is wrong, the new call's own
    /// cancel watch ends it as soon as the server is reachable. A live call is never dropped on a guess.
    private func arbitratePushedRedial(callId newId: String, name: String, uid: String, photo: String?, video: Bool,
                                       attempt: Int = 1, current pinned: String?? = nil) {
        let current = pinned ?? self.callId
        let ref = db.collection("calls").document(newId)
        ref.getDocument(source: .server) { [weak self] snap, err in
            guard let self else { return }
            guard current != nil, self.callId == current, self.otherUid == uid else { return }
            let unreadable = err != nil || snap == nil
            if unreadable, attempt < 3 {
                print("[Call] redial push: read failed (try \(attempt)), retrying")
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(attempt)) { [weak self] in
                    self?.arbitratePushedRedial(callId: newId, name: name, uid: uid, photo: photo, video: video,
                                                attempt: attempt + 1, current: .some(current))
                }
                return
            }
            if unreadable {
                // Out of tries: ring the redial over a still-ringing call only (see above).
                guard self.state == .incoming, !self.wasAccepted else { return }
                print("[Call] redial push: unreadable after \(attempt) tries, ringing the new call")
            } else {
                guard let d = snap?.data(), (d["status"] as? String) == "ringing" else { return }
                guard self.isNewerThanCurrent(d) else {
                    ref.updateData(["status": "ended", "endReason": EndReason.missed.rawValue])
                    return
                }
            }
            if self.state == .incoming, !self.wasAccepted {
                self.endReason = .missed
                self.finishCall(updateRemote: true, clearCallKit: true, localUser: true)
            } else if self.state == .active || self.state == .reconnecting {
                self.finishCall(updateRemote: true, clearCallKit: true, localUser: true)
            } else {
                return
            }
            // Now idle: ring it the way a fresh push would, and report it to the system ourselves,
            // since the push's own report was the transient one.
            self.prepareIncoming(callId: newId, name: name, uid: uid, photo: photo, video: video)
            if self.callId == newId {
                CallKitManager.shared.reportIncoming(callId: newId, name: self.otherName, video: video, callerUid: uid)
            }
        }
    }

    /// Pull the offer into `pendingOffer` during the ring. Retried, because the push can beat the
    /// caller's own write of the offer onto the document, and a ring lasts long enough to try again.
    ///
    /// Every exit is silent on purpose. This is an optimisation, not a step: if it never lands,
    /// `answer()` falls back to the fetch it always did and the call is exactly as it was before.
    private func prefetchOffer(callId: String, attempt: Int) {
        guard attempt <= 4, pendingOffer == nil else { return }
        db.collection("calls").document(callId).getDocument(source: .server) { [weak self] snap, _ in
            guard let self else { return }
            // Still the same call, still ringing. A late reply must not write over a call that has
            // since been answered, cancelled or replaced by a different one.
            guard self.state == .incoming, self.callId == callId, self.pendingOffer == nil else { return }
            // #27: a sealed offer whose key is not here yet reads as "not yet"; `readOffer` has
            // started the key warm and the retry below picks it up.
            if let d = snap?.data(), let offerSdp = self.readOffer(d) {
                let offer = ["sdp": offerSdp, "type": "offer"]
                self.pendingOffer = offer
                self.mark("offerReady")   // if this lands before "answerTapped", the prefetch paid off
                // Take the type and the camera state from the document too. The push payload is the
                // caller's word for these; the document is the record.
                if let t = d["type"] as? String {
                    self.startedAsVideo = (t == "video")
                    self.cameraOn = self.startedAsVideo
                    self.noteVideo()
                }
                if let cams = d["cams"] as? [String: Bool], let on = cams[self.otherUid] {
                    self.remoteCameraOn = on
                }
                if let screens = d["screen"] as? [String: Bool] {
                    self.remoteScreenSharing = screens[self.otherUid] ?? false
                }
                // ⭐ AND NOW BUILD THE WHOLE CONNECTION, WHILE IT IS STILL RINGING. See the
                // pre-negotiation note above `mediaReady`. The microphone stays off until accept.
                self.preNegotiate(callId: callId, offerSdp: offer["sdp"] ?? "")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.prefetchOffer(callId: callId, attempt: attempt + 1)
            }
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
        // ⛔ AN ACCEPTED CHAT IS THE CONTACT — owner, 2026-09-11: "make it can call and message who
        // know the pin". A Chat PIN marks the conversation accepted before a word is exchanged, so
        // "carries a last message" said no to the very person the pin let in; and it said yes to a
        // stranger whose one unanswered request was that message. Same test as `decideAllowed`
        // on the other phone and `PrivacyPrefs.isContact` everywhere else.
        if !conv.startedBy.isEmpty { return conv.accepted }
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
        // 1:1 audit r2 A4, 2026-10-08: the ring is already up with the caller's name, so a slow
        // radio must not keep a refused caller ringing for seconds. After 1.5 s the cached copy
        // decides (a missing one rings, as below); the live answer is then ignored. Main queue only.
        var settled = false
        let finish: (Bool) -> Void = { ok in
            guard !settled else { return }
            settled = true
            completion(ok)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            guard !settled else { return }
            ref.getDocument(source: .cache) { [weak self] cached, _ in
                guard let self else { return }
                let ok = (cached?.exists == true) ? self.decideAllowed(cached) : true
                DispatchQueue.main.async { finish(ok) }
            }
        }
        ref.getDocument { [weak self] cs, err in
            guard let self else { return }
            guard err == nil, cs != nil else {
                ref.getDocument(source: .cache) { [weak self] cached, _ in
                    guard let self else { return }
                    guard let cached, cached.exists else {
                        DispatchQueue.main.async { finish(true) }   // unknown → let it ring
                        return
                    }
                    DispatchQueue.main.async { finish(self.decideAllowed(cached)) }
                }
                return
            }
            DispatchQueue.main.async { finish(self.decideAllowed(cs)) }
        }
    }

    /// The gate's actual decision, split out so the live read and the cache fallback cannot drift.
    private func decideAllowed(_ cs: DocumentSnapshot?) -> Bool {
        // 2026-09-26 block rebuild: my account list (the caller is the other half of the pair id),
        // then the chat's old copy. The server already refuses such a call; this is the phone's wall.
        let caller = cs?.documentID.split(separator: "_").map(String.init).first { $0 != me } ?? ""
        let blocked = (!caller.isEmpty && BlockList.snapshot.contains(caller))
            || (((cs?.data()?["blockedBy"] as? [String: Any])?[me] as? Bool) ?? false)
        let audience = PrivacyPrefs.mine("calls")   // same default as the settings screen — see PrivacyPrefs
        // An ACCEPTED chat, not "a last message" — the same test as `iAmContactOf` on the caller's
        // phone, so a Chat PIN opens calls the moment it opens the chat, and a stranger's one
        // unanswered request does not (owner, 2026-09-11). A chat from before requests existed
        // has no `startedBy` and keeps the old test.
        let d = cs?.data() ?? [:]
        let startedBy = d["startedBy"] as? String ?? ""
        let isContact = cs?.exists == true
            && (startedBy.isEmpty ? !((d["lastMessage"] as? String ?? "").isEmpty)
                                  : (d["accepted"] as? Bool ?? false))
        return !blocked && (audience == .everyone || (audience == .contacts && isContact))
    }

    /// Build the answering connection DURING THE RING, so the accept has nothing left to do.
    ///
    /// Everything `buildAnswer` does, minus the one thing that must wait for a person: the
    /// microphone. `callDocCreated` is set here because our candidates can and should go out now —
    /// the whole point is that both sides finish their checks before the tap.
    private func preNegotiate(callId: String, offerSdp: String) {
        guard !preNegotiated, !offerSdp.isEmpty, state == .incoming, self.callId == callId else { return }
        preNegotiated = true
        mark("preNegotiateStart")
        Task { @MainActor in
            await self.awaitIceServers()
            await self.awaitPeerTrust()   // 2026-09-24 fix-all #231
            // Still the same call, still nobody has answered or hung up.
            guard self.state == .incoming, self.callId == callId, self.pc == nil else { return }
            // 2026-09-24 audit: no relay yet for a stranger → skip pre-negotiation. Resetting the
            // flag sends answer() down the normal path, which retries the fetch and refuses there.
            if self.strangerWithoutRelay { self.preNegotiated = false; return }
            self.mark("preRelayCredsReady")
            self.callDocCreated = true      // the doc exists — the caller made it — so candidates may fly
            self.buildAnswer(ref: self.db.collection("calls").document(callId), offerSdp: offerSdp)
        }
    }

    /// False when there is no call left to answer (1:1 audit #23, owner 2026-10-08): CallKit then
    /// fails the action and closes the system call instead of showing a connected call with nothing
    /// behind it (the call ended inside its tone window, or the service is idle).
    @discardableResult
    func answer() -> Bool {
        guard let id = callId, state != .idle, state != .ended else { return false }
        mark("answerTapped")   // everything after this is time the user spends watching "Connecting…"

        // ⭐ THE FAST PATH: the connection was built while it rang, so accepting is now three things
        // — say yes, open the microphone, and start the call if the path is already up. No SDP, no
        // relay fetch, no waiting for candidates to cross an ocean.
        if preNegotiated, pc != nil {
            state = .active
            wasAccepted = true
            db.collection("calls").document(id).updateData(acceptFields())
            claimAnswer(db.collection("calls").document(id))   // 2026-09-24 audit: one device wins
            // 2026-09-24 fix-all #230: the answer built during the ring goes out now, from the
            // device that accepted, through the claim transaction (a loser stands down unsent).
            // Not held yet (the SDP is still being made) → buildAnswer sees wasAccepted and writes it.
            if let held = heldPreAnswer {
                heldPreAnswer = nil
                var data = held
                data["status"] = "active"
                data["cams.\(me)"] = cameraOn
                writeAnswerWithRetry(ref: db.collection("calls").document(id), data: data, attempt: 1)
            }
            ringingWatcher?.remove(); ringingWatcher = nil
            startAcceptedMediaTimeout()   // audit M-008
            if cameraOn { prepareLocalVideo() }
            ensureMicPermission { [weak self] granted in
                // 1:1 audit r2 C1, 2026-10-08: a late answer to the prompt belongs to THIS call only.
                guard let self, self.callId == id, self.wasAccepted else { return }
                guard granted else { self.endForDeniedMic(); return }
                // ⛔ THE MICROPHONE OPENS HERE AND NOWHERE EARLIER. Until this line the track has
                // been disabled since it was created, so the connection that has been up for the
                // last ten seconds has been carrying silence.
                // Held too (audit M-119, 2026-10-07): a mic prompt answered after a phone-call
                // hold began opened the mic in the middle of the hold.
                self.localAudioTrack?.isEnabled = !(self.isMuted || self.isHeld)
                // Down the direct connection, which beats the Firestore write to the caller by the
                // better part of a second. The `acceptedAt` write above still happens and is still
                // what the caller ultimately trusts; this only usually arrives first.
                self.sendAcceptOverChannel()
                self.beginConnectedCallIfAccepted()
            }
            return true
        }
        // The ring watcher STAYS until observeCallDoc is attached in buildAnswer (audit M-110,
        // 2026-10-07). It used to go here, and the mic prompt, the offer fetch and the relay wait
        // all sit before buildAnswer: a caller hanging up in that window was heard by nobody.
        callDocCreated = true   // callee: the caller already created the doc, so candidates can write now
        state = .active   // present the call screen immediately; SDP fills in below
        // THE INSTANT ACCEPT SIGNAL (the standard messenger order, owner's side-by-side report): tell the caller
        // the call was picked up NOW, before permissions, TURN, or the peer connection. A plain
        // update queues and retries on its own, unlike the answer transaction below — so even when
        // the heavy chain stalls, the caller stops ringing and shows "Connecting…" instead of
        // ringing out on a call that was answered.
        db.collection("calls").document(id).updateData(acceptFields())
        claimAnswer(db.collection("calls").document(id))   // 2026-09-24 audit: one device wins
        wasAccepted = true
        startAcceptedMediaTimeout()   // audit M-008
        // Video call: warm the camera NOW, in parallel with permissions/TURN/SDP (the reference apps' order),
        // so the local video is live the moment the connection comes up.
        if cameraOn { prepareLocalVideo() }
        ensureMicPermission { [weak self] granted in
            // 1:1 audit r2 C1, 2026-10-08: a late answer to the prompt belongs to THIS call only.
            guard let self, self.callId == id, self.wasAccepted else { return }
            guard granted else { self.endForDeniedMic(); return }
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
        return true
    }

    // Build the answering peer connection from the caller's offer, publish the answer + my camera state.
    // The TURN wait sits HERE rather than in answer(), because this is the one place that builds the
    // peer connection and so the last point at which `config` can still pick up real relay servers.
    /// The cold-launch offer fetch, allowed to try three times. The guard on `state` matters: the
    /// caller can cancel while we retry, and a late success must not answer a call that is over.
    private func fetchOfferWithRetry(ref: DocumentReference, attempt: Int) {
        ref.getDocument(source: .server) { [weak self] snap, _ in
            guard let self else { return }
            // Cancelled / ended while retrying, or a NEWER call is up now (audit M-038, 2026-10-07:
            // "some call is active" is not "this call is active").
            guard self.state == .active, self.callId == ref.documentID else { return }
            if let d = snap?.data(), let sdp = self.readOffer(d) {   // #27: sealed or plaintext
                self.startedAsVideo = (d["type"] as? String == "video")
                self.cameraOn = self.startedAsVideo   // accepting a video call opens the camera
                if let cams = d["cams"] as? [String: Bool], let on = cams[self.otherUid] { self.remoteCameraOn = on }
                if let screens = d["screen"] as? [String: Bool] { self.remoteScreenSharing = screens[self.otherUid] ?? false }
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
        mark("offerInHand")   // gap from answerTapped = what the offer fetch cost, if anything
        Task { @MainActor in
            await self.awaitIceServers()
            await self.awaitPeerTrust()   // 2026-09-24 fix-all #231
            await self.awaitRelayForStranger()
            self.mark("relayCredsReady")   // gap from offerInHand = what the TURN fetch cost
            guard self.state == .active, self.callId == ref.documentID else { return }   // ended while we waited (M-038)
            // 2026-09-24 audit: no relay for a stranger → fail, never go direct.
            if self.strangerWithoutRelay { self.endReason = .failed; self.hangUp(); return }
            self.buildAnswer(ref: ref, offerSdp: offerSdp)
        }
    }

    private func buildAnswer(ref: DocumentReference, offerSdp: String) {
        mark("buildingAnswer")
        pc = makePeerConnection()   // cameraOn is already known → the local video track is added if it's a video call
        guard let pc else { hangUp(); return }
        // THIS CALL AND THIS CONNECTION (audit M-038, 2026-10-07). Every step below completes on
        // its own time, and used to check only that SOME connection existed: a finished call's late
        // completion answered on the next call's connection, or set `endReason` and hung up a call
        // it never belonged to. Each step now acts only for the call and connection it started on.
        let builtFor = ref.documentID
        let builtPc = pc
        let stillOurs: () -> Bool = { [weak self] in
            guard let self else { return false }
            return self.callId == builtFor && self.pc === builtPc && self.state != .ended && self.state != .idle
        }
        let remote = RTCSessionDescription(type: .offer, sdp: offerSdp)
        pc.setRemoteDescription(remote) { [weak self] _ in
            guard let self, stillOurs(), let pc = self.pc else { return }
            self.flushPendingCandidates()   // caller's candidates were buffered until now (C1)
            // Screen share v3: a second video m-line in the offer is the caller's screen slot; ours
            // sends too. An old caller's offer has one, and this does nothing.
            self.acceptScreenTransceiver(pc)
            let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
            pc.answer(for: constraints) { answerSdp, _ in
                // NO SILENT DEATHS past this point (the 12:27 call: he accepted, this chain died
                // quietly, and both phones sat frozen until the timeout). A failure here ends the
                // call promptly on both sides instead of stranding two people mid-answer.
                guard let answerSdp else {
                    DispatchQueue.main.async { guard stillOurs() else { return }; self.endReason = .failed; self.hangUp() }
                    return
                }
                let local = self.withOpusDtxAndRed(answerSdp)
                pc.setLocalDescription(local) { _ in
                    // ⛔ "status": "active" IS ONLY WRITTEN BY A REAL ACCEPT. Writing it during
                    // pre-negotiation made the phone hang up on itself: `watchRingingCancel` treats
                    // status==active while still .incoming as "answered on my OTHER device, stop
                    // ringing", ends the call with localUser: true, and that lands as `declined`.
                    // Shipped for one build and it killed every incoming call — 685ms and 0ms to
                    // "declined" in the timeline, with the ring-time marks proving pre-negotiation
                    // had just run. The answer SDP itself is safe to publish early; the STATUS is a
                    // statement that a person picked up, and that was never true yet.
                    //
                    // 2026-09-24 fix-all #230: and the answer SDP is no longer published before the
                    // accept either. With two of my own devices ringing, BOTH pre-negotiated and
                    // wrote an answer; the caller applies only the first one it sees, so if I
                    // picked up on the other phone that phone's answer was ignored and the call had
                    // no audio. A pre-negotiated answer is now held here and written by `answer()`
                    // on the device that accepts (through the same claim transaction), and a device
                    // that loses the claim stands down with its answer never sent. The cost is one
                    // write round trip after the tap; the connection, the gathered candidates and
                    // the published candidates are all still ready.
                    DispatchQueue.main.async {
                        guard stillOurs() else { return }   // audit M-038
                        // #27: sealed when the offer was (`readOffer` decided), else the old field.
                        var data: [String: Any] = self.sealSignal(local.sdp).map { enc -> [String: Any] in ["answerEnc": enc] }
                            ?? ["answer": ["sdp": local.sdp, "type": "answer"]]
                        data["cams.\(self.me)"] = self.cameraOn   // publish my camera state (per-side)
                        data["caps.\(self.me)"] = [Self.screenCap]   // screen share v3 capability
                        guard self.wasAccepted else { self.heldPreAnswer = data; return }
                        data["status"] = "active"
                        self.writeAnswerWithRetry(ref: ref, data: data, attempt: 1)
                    }
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
                }
            }
        }
        // Accepted already (the slow path): the doc listener takes over from the ring watcher here,
        // not earlier (audit M-110). During the ring the watcher stays; `answer()` removes it.
        if state == .active { ringingWatcher?.remove(); ringingWatcher = nil }
        observeCallDoc(ref)
        observeRemoteCandidates(ref.collection("callerCandidates"))
    }

    /// 2026-09-24 audit: TWO OF MY OWN DEVICES ANSWERING IN THE SAME INSTANT. Each running app gets
    /// one id, and the accept claims the call doc for it in a transaction. Transactions serialise, so
    /// exactly one device wins; the other reads the winner's claim and stands down through the same
    /// "answered elsewhere" path the ring watcher already uses. Before this, both went .active, both
    /// opened the mic, and the loser sat in "Reconnecting…" until the 30s cap.
    private static let deviceClaim = UUID().uuidString

    private static func answeredOnOtherDevice(_ d: [String: Any]?) -> Bool {
        guard let owner = d?["answeredDevice"] as? String, !owner.isEmpty else { return false }
        return owner != deviceClaim
    }

    /// Claim the answer for this device. Best effort: the plain `acceptedAt` write beside it still
    /// carries the accept if this transaction cannot run (offline), exactly as before.
    /// 1:1 audit r2 A1 (2026-10-08): the accept stamp carries a hash of THIS device's VoIP token,
    /// exactly as written to `voipTokens`, so the server's "answered elsewhere" cancel push skips the
    /// phone that answered and stops only my other devices (the reference app's behaviour).
    private func acceptFields() -> [String: Any] {
        var fields: [String: Any] = ["acceptedAt": FieldValue.serverTimestamp()]
        if let token = Push.latestVoipToken, !token.isEmpty {
            fields["answeredTokenHash"] = SHA256.hash(data: Data(token.utf8))
                .map { String(format: "%02x", $0) }.joined()
        }
        return fields
    }

    private func claimAnswer(_ ref: DocumentReference) {
        let peer = otherUid, video = startedAsVideo || everVideo   // for acceptLostToCancel, read while live
        ref.firestore.runTransaction({ txn, errPtr -> Any? in
            do {
                let snap = try txn.getDocument(ref)
                if (snap.data()?["status"] as? String) == "ended" {
                    return Self.cancelledBeforeAccept(snap.data()) ? "cancelled" : "ended"
                }
                if Self.answeredOnOtherDevice(snap.data()) { return "taken" }
            } catch {
                errPtr?.pointee = error as NSError
                return nil
            }
            txn.updateData(["answeredDevice": Self.deviceClaim], forDocument: ref)
            return nil
        }, completion: { [weak self] result, error in
            if let error { Self.reportToRecovery(error, "call answer claim") }   // owner, 2026-10-08
            if (result as? String) == "taken" { self?.standDownAnsweredElsewhere(ref.documentID) }
            if (result as? String) == "cancelled" {
                self?.acceptLostToCancel(ref.documentID, peer: peer, video: video)
            }
        })
    }

    /// The doc was ended by the CALLER giving up (cancel, or their no-answer timeout: both write
    /// `missed`) before my accept ever reached it (no `acceptedAt`). Only then did nobody pick up.
    /// `cancelledAt` first (audit M-037, 2026-10-07): the caller now ends an unaccepted ring in a
    /// transaction that stamps it only when no accept was there. The old test needed `acceptedAt`
    /// to be absent, and this phone's own `acceptedAt` write (sent on the tap, before the claim)
    /// usually landed on the ended doc first, so it could never say "cancelled". Kept as the
    /// fallback for callers on older builds, which write no `cancelledAt`.
    private static func cancelledBeforeAccept(_ d: [String: Any]?) -> Bool {
        if d?["cancelledAt"] != nil { return true }
        return d?["acceptedAt"] == nil && (d?["endReason"] as? String) == EndReason.missed.rawValue
    }

    /// ACCEPT TAPPED JUST AS THE CALLER CANCELLED (owner audit 2026-10-06 #12). `wasAccepted` is set
    /// on the tap, before anything knows whether the call is still live, and `finishCall` logs any
    /// accepted call as "answered". So a cancelled call that nobody ever spoke on was logged
    /// "answered" here and "missed" by the caller, into the same row, and whichever merge landed
    /// last won. The claim / answer transaction is the one place that reads the doc AT the accept,
    /// and when it says the caller had already given up, the call was a miss. Still live → clear
    /// the latch and write the record here ("missed", what the caller writes too) so the teardown
    /// cannot write "answered". Already torn down (the end snapshot beat this reply) → the
    /// "answered" row is already written; overwrite it with the same "missed".
    private func acceptLostToCancel(_ id: String, peer: String, video: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !peer.isEmpty, !self.me.isEmpty else { return }
            if self.callId == id, self.state != .ended, self.state != .idle {
                self.wasAccepted = false
                self.recordWritten = true
            }
            let cid = [self.me, peer].sorted().joined(separator: "_")
            Task {
                await ChatService.recordCall(cid: cid, callId: id, callerUid: peer, outcome: "missed",
                                             video: video, durationSec: 0)
            }
        }
    }

    /// The existing "answered elsewhere" stand-down (see watchRingingCancel), usable after this
    /// phone has already gone .active. No doc write (it would fight the device that owns the call)
    /// and no call record (the winner writes the real one for this same callId).
    private func standDownAnsweredElsewhere(_ id: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.callId == id, self.state != .ended, self.state != .idle else { return }
            self.ringingWatcher?.remove(); self.ringingWatcher = nil
            self.recordWritten = true
            self.endedElsewhere = true   // #20
            self.finishCall(updateRemote: false, clearCallKit: true, localUser: true)
        }
    }

    /// Set right before finishing a ring that another of my devices answered, so the system call
    /// is reported "answered elsewhere" (owner audit 2026-10-06 #20). Read and cleared by finishCall.
    private var endedElsewhere = false
    /// 1:1 audit r2 C2, 2026-10-08: the ring was declined or busied on another of my devices, so
    /// iOS is told "declined elsewhere" (the reference app's rule). Read and cleared by finishCall.
    private var declinedElsewhere = false

    /// The "I answered" write, no longer allowed to die silently (the 12:27 call: it never landed,
    /// the caller rang out on an answered call, and nothing anywhere noticed). Still a transaction —
    /// answering an ENDED call must stay refused (the caller-cancelled race this has always
    /// guarded). On error: three attempts over ~3s, then end the call honestly on both sides. A
    /// transaction that HANGS outright (dead socket, no completion at all) is bounded by the
    /// caller's accepted-connect timeout, which fails the call from the other side.
    private func writeAnswerWithRetry(ref: DocumentReference, data: [String: Any], attempt: Int) {
        let peer = otherUid, video = startedAsVideo || everVideo   // for acceptLostToCancel, read while live
        ref.firestore.runTransaction({ txn, errPtr -> Any? in
            // ⚠️ A FAILED READ IS NOT "THE CALLER CANCELLED". The old `try?` collapsed the two, so
            // one transient read hiccup returned success-with-no-writes, the retry path (which
            // keys on `error`) never fired, and the answer was silently never written — the 2:47
            // two-phone failure, proven from the live doc: offer, acceptedAt and 26 callee
            // candidates all present (plain writes flowing), answer absent. Only a genuinely READ
            // "ended" status may stand down; a read error must surface as an error and retry.
            do {
                let snap = try txn.getDocument(ref)
                if (snap.data()?["status"] as? String) == "ended" {
                    return Self.cancelledBeforeAccept(snap.data()) ? "cancelled" : "ended"
                }
                // 2026-09-24 audit: another of MY devices already claimed this answer. Writing ours
                // would overwrite its SDP and leave this phone in a call nobody hears.
                if Self.answeredOnOtherDevice(snap.data()) { return "taken" }
            } catch {
                errPtr?.pointee = error as NSError
                return nil
            }
            var write = data
            if data["status"] != nil { write["answeredDevice"] = Self.deviceClaim }
            txn.updateData(write, forDocument: ref)
            return nil
        }, completion: { [weak self] result, error in
            guard let self else { return }
            if (result as? String) == "ended" { return }   // caller cancelled — the end path owns this
            if (result as? String) == "cancelled" {        // …and the accept never counted (#12)
                self.acceptLostToCancel(ref.documentID, peer: peer, video: video)
                return
            }
            if (result as? String) == "taken" { self.standDownAnsweredElsewhere(ref.documentID); return }
            guard let error else { return }                // landed
            Self.reportToRecovery(error, "call answer")    // owner, 2026-10-08
            // Call already over, or a newer call is up (audit M-038, 2026-10-07): nothing to save,
            // and a failure here must never end a call it does not belong to.
            let sameCall: () -> Bool = { [weak self] in
                guard let self else { return false }
                return self.state == .active && self.callId == ref.documentID
            }
            guard sameCall() else { return }
            guard attempt < 3 else {
                // LAST RESORT, evidence-driven: tonight's failures had plain writes working while
                // the transaction path did not. Read once outside a transaction, then write plain.
                // The race this reopens (caller cancels in the same instant) is milliseconds wide
                // and its cost is a stale doc; the cost of NOT trying is a dead answered call.
                ref.getDocument(source: .server) { [weak self] snap, _ in
                    guard let self, sameCall() else { return }
                    if let d = snap?.data(), (d["status"] as? String) != "ended" {
                        ref.updateData(data) { [weak self] err in
                            if let err { Self.reportToRecovery(err, "call answer") }
                            guard let self, err != nil, sameCall() else { return }
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
                guard let self, sameCall() else { return }
                self.writeAnswerWithRetry(ref: ref, data: data, attempt: attempt + 1)
            }
        })
    }

    // MARK: - Signalling observers

    private func observeCallDoc(_ ref: DocumentReference) {
        callDocListener?.remove()   // a re-attach (owner, 2026-10-08) replaces the old one
        // 1:1 audit #31 (owner, 2026-10-08): and leaves the list too, or every re-attach grew it.
        if let old = callDocListener { listeners.removeAll { $0 === old } }
        callDocWatch = ref
        let l = ref.addSnapshotListener { [weak self] snap, err in
            guard let self else { return }
            if let err {
                self.callListenerFailed(err, "call signalling", callId: ref.documentID) { [weak self] in
                    guard let self, self.callDocWatch?.documentID == ref.documentID else { return }
                    self.observeCallDoc(ref)
                }
                return
            }
            guard let d = snap?.data() else { return }

            // MOVED ONTO A MULTI-PERSON CALL ("Add people" on the other side). Read before the
            // "ended" branch below: the same write carries `status: ended`, and taken as an end it
            // would play the tone and show "Call ended" over a call that is carrying on elsewhere.
            if let roomId = d["moveTo"] as? String, roomId.hasPrefix("adhoc_"),
               self.state != .ended, self.state != .idle {
                self.followMove(to: roomId)
                return
            }

            // Remote ended (hang up / decline / unreachable) — play the matching tone,
            // then tear down. Do this first and bail.
            if (d["status"] as? String) == "ended", self.state != .ended, self.state != .idle {
                // GLARE, heard from this side first (audit 2026-09-24): the other phone won the
                // tiebreak and busied my call before my listener saw theirs. Taken as a busy line it
                // played the busy tone, logged a missed row, and the tail then dropped their call.
                if (d["glare"] as? Bool) == true, self.isCaller, self.state == .outgoing {
                    self.standDownForGlare(rearmListener: true)
                    return
                }
                let reason = EndReason(rawValue: d["endReason"] as? String ?? "") ?? .hangup
                // A ringing callee whose call was busied by another of my devices, or answered
                // elsewhere and then ended (audit M-043, M-036, 2026-10-07): quiet, no row.
                if !self.isCaller, self.state == .incoming, self.endRingQuietlyIfSettledElsewhere(d, reason: reason) { return }
                // The callee's phone refused this caller (block or Calls privacy). No row: it
                // would land in the chat of the person who refused (audit M-013, 2026-10-07).
                // Old callee builds never send `refused`, and log as before.
                if self.isCaller, (d["refused"] as? Bool) == true, self.connectedDate == nil { self.recordWritten = true }
                self.remoteEnded(reason: reason)
                return
            }
            if self.callId == ref.documentID, self.currentCallCreatedAt == nil {
                self.currentCallCreatedAt = (d["createdAt"] as? Timestamp)?.dateValue()   // audit M-005/M-006
            }
            // Audit M-039: the caller's first look at its own doc; `createdAt` was stamped by the
            // server a moment ago, so the gap to this clock is the clock's error. Once per call.
            if self.isCaller, self.state == .outgoing, let ct = (d["createdAt"] as? Timestamp)?.dateValue() {
                self.learnClockSkew(serverNow: ct, callId: ref.documentID)
            }

            // Caller: the callee's device is now ringing → "Calling…" becomes "Ringing…", and THIS is
            // when the ringback starts (the reference app rings on remote ringing, not on the dial;
            // owner, 2026-10-07). Into the live session if CallKit has handed it over; otherwise a
            // short fallback starts it anyway. Whichever of the two signals lands second does the start.
            if self.isCaller, d["ringingAt"] != nil, !self.calleeRinging, self.state == .outgoing {
                self.calleeRinging = true
                if self.callAudioLive { self.startRingbackIfDue() } else { self.armRingbackFallback() }
            }
            // Caller: they TAPPED ACCEPT — flip to "Connecting…" and stop the ring immediately,
            // seconds before the SDP answer can arrive. The no-answer timeout is replaced by a
            // SHORT one: an accepted call whose answer never lands must fail fast (his 12:27 call
            // rang the full timeout on a call that was picked up), not sit "Ringing" for 45s.
            // ⛔ NO `state == .outgoing` HERE ANY MORE, and that clause is precisely what broke the
            // caller's screen. It was safe when the answer SDP could only arrive AFTER a human
            // accepted — the caller was necessarily still .outgoing at that moment. Pre-negotiation
            // publishes the answer DURING the ring, the caller applies it and flips itself .active
            // straight away, so by the time the real `acceptedAt` lands the guard is already false:
            // `calleeAccepted` never got set, the call never started, and the caller sat on
            // "Connecting…" through an entire working conversation with audio flowing both ways.
            // Reported live, mid-call: "it shows me connecting still, he doesn't see it at all".
            //
            // `!calleeAccepted` alone is the correct latch — it is what makes this run once.
            if self.isCaller, d["acceptedAt"] != nil, !self.calleeAccepted, self.state != .ended {
                // THE MARK THAT SETTLES WHAT THE CALLER'S REMAINING BLINK ACTUALLY IS. The caller
                // starts its timer on whichever lands second: the media path coming up, or the news
                // that a human accepted, which has to cross from Uganda to the USA through Doha.
                // Against `mediaReady` this says outright which one the user is waiting on — and if
                // it is this one, no amount of media tuning will ever shorten it.
                self.mark("acceptSeen")
                self.calleeAccepted = true
                self.wasAccepted = true
                self.stopRingback()
                self.noAnswerWork?.cancel()
                self.startAcceptedConnectTimeout()
                // The path is very often ALREADY UP by now: the callee pre-negotiated during the
                // ring, so ICE connected while the phone was still ringing and this accept is the
                // second of the two events, not the first. Start the call here rather than waiting
                // for a media event that has already been and gone.
                self.beginConnectedCallIfAccepted()
            }
            // Caller applies the answer once it arrives → connected.
            // #27: the sealed answer first; the plaintext one only on an unsealed call.
            if self.isCaller, self.pc?.remoteDescription == nil,
               let sdp = self.signalSdp(sealed: d["answerEnc"], plain: (d["answer"] as? [String: String])?["sdp"]) {
                self.noAnswerWork?.cancel()
                self.acceptedConnectWork?.cancel()
                self.stopRingback()
                self.pc?.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: sdp)) { _ in
                    self.flushPendingCandidates()
                }
                self.state = .active   // show the call screen; reportConnected fires on real ICE connect (H1)
                self.startAcceptedMediaTimeout()   // audit M-008: both timers above are gone now
            }
            // Callee applies an ICE-restart OFFER (reconnection) and answers it.
            if !self.isCaller, let ro = d["restartOffer"] as? [String: Any],
               let v = (ro["version"] as? NSNumber)?.intValue, v > self.appliedRemoteRestart,
               let pc = self.pc,
               let sdp = self.signalSdp(sealed: ro["enc"], plain: ro["sdp"]) {   // #27
                let before = self.appliedRemoteRestart
                self.appliedRemoteRestart = v
                self.restartAppliedAt = Date()   // 1:1 audit r2 F3: the 12 s count from this restart
                self.notePeerReconnecting()   // 1:1 audit #44: the caller is restarting, beat promptly
                // Audit M-009, 2026-10-07: the callee gathers anew for this restart too, so it gets
                // the newer relay list first, if one arrived after its connection was built.
                self.applyNewerIceServers(to: pc)
                pc.setRemoteDescription(RTCSessionDescription(type: .offer, sdp: sdp)) { err in
                    // 1:1 audit #30: a failed step un-latches the version, so the next snapshot of
                    // the doc tries it again instead of leaving the offer unanswered.
                    if let err { self.releaseRestartLatch(v, back: before, err); return }
                    self.flushPendingCandidates()
                    self.acceptScreenTransceiver(pc)   // screen share v3, idempotent
                    let c = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
                    pc.answer(for: c) { ans, err in
                        guard let ans else { self.releaseRestartLatch(v, back: before, err); return }
                        let local = self.withOpusDtxAndRed(ans)
                        pc.setLocalDescription(local) { err in
                            if let err { self.releaseRestartLatch(v, back: before, err); return }
                            // #27; 1:1 audit r2 G9: a failed seal is retried, never sent plain.
                            self.writeSignalSdp(local.sdp, version: v, field: "restartAnswer", ref: ref) {
                                [weak self] in self?.appliedRemoteRestart == v
                            }
                        }
                    }
                }
            }
            // Callee asked for an ICE restart (its network moved or its ICE dropped first).
            if self.isCaller, let rq = (d["restartRequest"] as? NSNumber)?.intValue,
               rq > self.restartRequestsSeen,
               self.state == .active || self.state == .reconnecting {
                self.restartRequestsSeen = rq
                self.notePeerReconnecting()   // 1:1 audit #44
                // 1:1 audit r2 F1, 2026-10-08: a request over a restart that is working is served
                // by that restart (an 840-843 callee re-asks every 8 s whatever happens).
                if !self.restartIsWorking {
                    self.restartIce()   // #20: inside the in-flight window it now runs when that closes
                }
            }
            // Caller applies the ICE-restart ANSWER.
            if self.isCaller, let ra = d["restartAnswer"] as? [String: Any],
               let v = (ra["version"] as? NSNumber)?.intValue,
               v == self.negotiationVersion, v > self.appliedRemoteRestart, let pc = self.pc,
               let sdp = self.signalSdp(sealed: ra["enc"], plain: ra["sdp"]) {   // #27
                let before = self.appliedRemoteRestart
                self.appliedRemoteRestart = v
                // Audit M-117: the latest offer is answered, whichever kind it was. An upgrade's
                // version never matches here once an ICE restart has gone out over it.
                if v == self.screenUpgradeInFlightVersion {
                    self.screenUpgradeInFlightVersion = nil
                } else {
                    self.restartInFlightAt = nil
                    self.restartAppliedAt = Date()   // 1:1 audit r2 F3
                }
                pc.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: sdp)) { err in
                    if let err { self.releaseRestartLatch(v, back: before, err); return }   // 1:1 audit #30
                    self.flushPendingCandidates()
                }
            }
            // The other side's camera on/off (per-side, no permission).
            self.handleRemoteCallState(d)
        }
        callDocListener = l
        listeners.append(l)
    }

    // Trickle-ICE buffer: libwebrtc DROPS candidates added before the remote description is set,
    // so we queue them and flush after every setRemoteDescription (C1 — fixes flaky connect / one-way audio).
    private var pendingRemoteCandidates: [RTCIceCandidate] = []

    private func addOrBuffer(_ candidate: RTCIceCandidate) {
        // Audit M-041, 2026-10-07: also buffer a candidate from an ICE RESTART that beat its restart
        // description here. Its ufrag is the new one, the remote description still carries the old,
        // and libwebrtc drops it, so the very routes the restart found never got tried.
        guard let pc, let remote = pc.remoteDescription,
              Self.matchesUfrag(candidate, of: remote) else {
            // Capped (the reference engine keeps at most 30 early messages): a remote description
            // that never arrives must not let this grow for the life of a stuck call. Oldest go first.
            if pendingRemoteCandidates.count >= 100 { pendingRemoteCandidates.removeFirst() }
            pendingRemoteCandidates.append(candidate)
            return
        }
        pc.add(candidate) { err in if let err { print("call: addIceCandidate failed:", err) } }
    }

    func flushPendingCandidates() {
        // Always on MAIN: called from SDP completions (WebRTC thread) while Firestore listeners (main)
        // append to pendingRemoteCandidates - the unsynchronized mix raced/lost candidates.
        guard Thread.isMainThread else { DispatchQueue.main.async { self.flushPendingCandidates() }; return }
        guard let pc, let remote = pc.remoteDescription, !pendingRemoteCandidates.isEmpty else { return }
        // Audit M-041: only the ones for the description now in place. The rest stay buffered: a
        // later restart's (its description has not landed yet) or an older generation's (harmless,
        // and the cap ages them out).
        let pending = pendingRemoteCandidates.filter { Self.matchesUfrag($0, of: remote) }
        pendingRemoteCandidates.removeAll { Self.matchesUfrag($0, of: remote) }
        for c in pending { pc.add(c) { err in if let err { print("call: flush addIceCandidate failed:", err) } } }
    }

    /// Audit M-041, 2026-10-07: does this candidate belong to the ICE generation of `description`?
    /// Both are compared by ufrag: libwebrtc writes `ufrag <x>` into every candidate line and
    /// `a=ice-ufrag:<x>` into the description, and a restart changes it. Nothing is added to the
    /// wire. A candidate or description without one (another engine) counts as a match, which is
    /// the old behaviour.
    private static func matchesUfrag(_ candidate: RTCIceCandidate, of description: RTCSessionDescription) -> Bool {
        let parts = candidate.sdp.split(separator: " ")
        guard let i = parts.firstIndex(of: "ufrag"), i + 1 < parts.count else { return true }
        let theirs = String(parts[i + 1])
        guard let line = description.sdp.components(separatedBy: "\n")
                .first(where: { $0.hasPrefix("a=ice-ufrag:") }) else { return true }
        let current = line.dropFirst("a=ice-ufrag:".count).trimmingCharacters(in: .whitespacesAndNewlines)
        return current.isEmpty || current == theirs
    }

    private func observeRemoteCandidates(_ col: CollectionReference) {
        candidatesListener?.remove()   // a re-attach (owner, 2026-10-08) replaces the old one
        if let old = candidatesListener { listeners.removeAll { $0 === old } }   // 1:1 audit #31
        candidatesWatch = col
        let l = col.addSnapshotListener { [weak self] snap, err in
            guard let self else { return }
            if let err {
                let id = col.parent?.documentID
                self.callListenerFailed(err, "call routes", callId: id) { [weak self] in
                    guard let self, self.candidatesWatch?.path == col.path else { return }
                    self.observeRemoteCandidates(col)
                }
                return
            }
            snap?.documentChanges.forEach { change in
                guard change.type == .added else { return }
                // Once per candidate doc: a re-attached listener lists them all again.
                guard self.appliedCandidateIds.insert(change.document.reference.path).inserted else { return }
                var c = change.document.data()
                // #27: a sealed candidate carries only `enc` (JSON of the three fields inside).
                // Plaintext ones (older build, unsealed call) are still taken: their route is
                // useless to anyone without the sealed DTLS fingerprint.
                if let enc = c["enc"] as? String {
                    guard let inner = self.openSealedCandidate(enc) else {
                        // 1:1 audit r2 G9, 2026-10-08: not openable yet (key not in memory; openSignal
                        // has started the warm). Kept on a retry list instead of being lost.
                        self.retrySealedCandidate(enc, callId: self.callId, attempt: 1)
                        return
                    }
                    c = inner
                }
                guard let sdp = c["candidate"] as? String else { return }
                let candidate = RTCIceCandidate(
                    sdp: sdp,
                    sdpMLineIndex: Int32((c["sdpMLineIndex"] as? NSNumber)?.intValue ?? 0),
                    sdpMid: c["sdpMid"] as? String
                )
                // ⭐ THE MEASUREMENT THAT SETTLES WHERE THE SECONDS GO. Two phones cannot begin
                // testing a route until each has been TOLD about the other's, and every one of
                // those travels as its own record to Firestore in Doha and back out. On a USA to
                // Uganda call that is a detour through Qatar, six or ten times, in each direction.
                //
                // So the long gap between "our routes are ready" and "media is up" is either the
                // ocean or it is our own signalling, and those need completely different fixes: the
                // first is physics, the second is the Cloudflare worker already written and not yet
                // deployed. `firstRemoteCandidate` against `firstCandidate` tells them apart —
                // ours ready at 512ms and theirs arriving at 9s would name the culprit outright.
                self.mark("firstRemoteCandidate")
                self.addOrBuffer(candidate)   // buffer until remote SDP is set, then flush
            }
        }
        candidatesListener = l
        listeners.append(l)
    }

    /// 1:1 audit r2 G9: the three candidate fields inside a sealed `enc`, or nil when not openable.
    private func openSealedCandidate(_ enc: String) -> [String: Any]? {
        guard let json = openSignal(enc)?.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: json)) as? [String: Any]
    }

    /// 1:1 audit r2 G9, 2026-10-08: a sealed candidate that could not be opened yet is tried again
    /// every second (5 tries) for the same call, once the key warm has landed.
    private func retrySealedCandidate(_ enc: String, callId id: String?, attempt: Int) {
        guard attempt <= 5 else { print("call: #27 sealed candidate could not be opened, skipped"); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, id != nil, self.callId == id else { return }
            guard let c = self.openSealedCandidate(enc) else {
                self.retrySealedCandidate(enc, callId: id, attempt: attempt + 1)
                return
            }
            guard let sdp = c["candidate"] as? String else { return }
            self.addOrBuffer(RTCIceCandidate(sdp: sdp,
                                             sdpMLineIndex: Int32((c["sdpMLineIndex"] as? NSNumber)?.intValue ?? 0),
                                             sdpMid: c["sdpMid"] as? String))
        }
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
        buffered.forEach { writeCandidate($0, to: col) }
    }

    /// One local candidate to the other side, RETRIED. The write used to be fire-and-forget, so a
    /// candidate written in the second a network was dropping (exactly when a new path is being
    /// found) was lost without a trace, and with it maybe the only route that would have worked.
    /// The reference engine queues every signalling message and re-sends what failed. Up to three
    /// tries a second apart, and only while it is still the same call.
    private func writeCandidate(_ data: [String: Any], to col: CollectionReference, attempt: Int = 1) {
        let id = callId
        // #27: sealed once, on the first try; the retries resend the same sealed document.
        let payload = attempt == 1 ? sealedCandidate(data) : data
        col.addDocument(data: payload) { [weak self] err in
            guard err != nil, attempt < 3 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                guard let self, self.callId == id, id != nil else { return }
                self.writeCandidate(payload, to: col, attempt: attempt + 1)
            }
        }
    }

    /// Owner audit 2026-10-06 #27: on a sealed call a candidate (the IP addresses) leaves this phone
    /// as one `enc` field holding the three fields as JSON. Unsealed calls write it as before.
    private func sealedCandidate(_ data: [String: Any]) -> [String: Any] {
        guard sealSignalling, let sdp = data["candidate"] as? String else { return data }
        var inner: [String: Any] = ["candidate": sdp,
                                    "sdpMLineIndex": Int((data["sdpMLineIndex"] as? Int32) ?? 0)]
        if let mid = data["sdpMid"] as? String { inner["sdpMid"] = mid }
        guard let json = try? JSONSerialization.data(withJSONObject: inner),
              let text = String(data: json, encoding: .utf8),
              let enc = sealSignal(text) else { return data }   // sealSignal logs the fallback
        return ["enc": enc]
    }

    // MARK: - Hang up / cleanup

    // System-/remote-initiated end (timeout, ICE failure, remote hang up) — plays a
    // feedback tone for this user and clears the system UI.
    func hangUp() { finishCall(updateRemote: true, clearCallKit: true, localUser: false) }
    /// 1:1 audit r2 C6, 2026-10-08: an end this person caused outside CallKit (signing out): a
    /// local hangup, as in the reference app, so no end tone and iOS is not told "remote ended".
    func endLocally() { finishCall(updateRemote: true, clearCallKit: true, localUser: true) }
    // The local user pressed End via CallKit — no tone (they know), don't re-report.
    func endFromCallKit() { finishCall(updateRemote: true, clearCallKit: false, localUser: true) }
    // The other side ended the call — carry their reason so we play the right tone.
    private func remoteEnded(reason: EndReason) {
        endReason = reason
        finishCall(updateRemote: false, clearCallKit: true, localUser: false)
    }

    /// The caller gave up on a ring, told by a cancel push (audit M-004 app half, 2026-10-07, for
    /// PushManager). Ends this phone's ring at once instead of waiting for the ring watcher, which
    /// a suspended app may not have running. Only a ring nobody here accepted; anything else is
    /// left to the doc listeners. A cancel for a call this phone is not ringing is remembered, so a
    /// late ring push for it never rings (M-036).
    ///
    /// `reason` is the cancel push's `endReason` (audit round 2, V3 N2, 2026-10-07): "busy" or
    /// "declined" means the ring was settled on another of MY devices (it was busy, or I declined
    /// there). That ends quietly, with no "Missed call" row and no tone, the same way the ring
    /// watcher's `endRingQuietlyIfSettledElsewhere` does. "hangup", "timeout", empty or unknown (an
    /// older server) stay a missed call.
    /// 1:1 audit r2 A2, 2026-10-08: iOS refused to ring this call on THIS phone (a Focus, its block
    /// list). Ends here only: the doc stays ringing for my other devices, and the caller's ring-out
    /// closes it. No row from this phone (the caller's row or the answering device's covers it).
    func endRingLocally(callId: String) {
        guard self.callId == callId, state == .incoming, !wasAccepted else { return }
        endReason = .missed
        recordWritten = true
        finishCall(updateRemote: false, clearCallKit: false, localUser: true)
    }

    func remoteCancelled(callId: String, reason: String? = nil) {
        guard !callId.isEmpty else { return }
        guard self.callId == callId, state == .incoming, !wasAccepted else {
            if self.callId != callId { rememberFinished(callId) }
            return
        }
        ringingWatcher?.remove(); ringingWatcher = nil
        // 1:1 audit r2 A1, 2026-10-08: answered on my other device (the server's cancel push when
        // `acceptedAt` appears). Stops quietly, no row, no doc write, as answered elsewhere.
        if reason == "answered" {
            recordWritten = true
            endedElsewhere = true
            finishCall(updateRemote: false, clearCallKit: true, localUser: true)
            return
        }
        if reason == "busy" || reason == "declined" {
            recordWritten = true
            declinedElsewhere = true   // 1:1 audit r2 C2, 2026-10-08
            finishCall(updateRemote: false, clearCallKit: true, localUser: true)
            return
        }
        remoteEnded(reason: .missed)
    }

    // MARK: - Move to a multi-person call

    /// "Add people" on a connected 1:1 call: both of us move onto a new ad-hoc multi-person call
    /// with the people picked, and the 1:1 closes quietly on both sides (no tone, no "ended" label).
    ///
    /// ⚠️ THE ORDER IS FORCED. `GroupCallService.startAdhoc` refuses while this service is not idle
    /// (decision D25), so the 1:1 has to be torn down locally FIRST, with what we still need kept in
    /// locals. The teardown must not write `status: ended` itself (`updateRemote: false`): the peer
    /// would see a plain hang-up before the room exists. `moveTo` and `status` go in ONE write once
    /// the room is up, so the peer's listener reads the move before it can read the end.
    /// The chat row is still written as an answered call by `finishCall`, as for any connected call.
    func moveToGroup(adding people: [CallMember]) {
        guard state == .active, connectedDate != nil, let oldId = callId, !otherUid.isEmpty else {
            // "Done" used to do nothing at all while the call dipped to reconnecting (audit M-122,
            // 2026-10-07). Say so; the person can try again once the call is back.
            if state == .reconnecting || (state == .active && connectedDate == nil) {
                MainActor.assumeIsolated {
                    GroupCallService.presentOverTop(GroupCallService.Notice(
                        title: "Can't Add People Yet",
                        message: "The call is reconnecting. Try again in a moment."))
                }
            }
            return
        }
        let myUid = me
        let peerUid = otherUid
        let peerShownName = otherName          // my label for them: for my own screen only
        let peerRawName = otherRawName.isEmpty ? otherName : otherRawName
        let peerPhoto = otherPhotoUrl
        let video = cameraOn   // my camera carries over into the new call
        finishCall(updateRemote: false, clearCallKit: true, localUser: true)
        let ref = db.collection("calls").document(oldId)
        Task { @MainActor in
            // THEIR PUBLISHED NAME, NOT MY NICKNAME (audit M-151, 2026-10-07). The members list is in
            // the shared room doc, read by everyone invited, and `otherName` is what I filed them
            // under. The profile this phone last saw (local), else the server's copy, else the name
            // the call itself carried.
            var profile = await ProfileStore.shared.cachedPeer(peerUid)
            if profile == nil { profile = await ProfileStore.shared.fetch(peerUid) }
            let other = CallMember(uid: peerUid, name: profile?.name ?? peerRawName, photoUrl: peerPhoto)
            // startAdhoc adds me itself; everyone else, de-duplicated, with the peer first.
            var seen: Set<String> = [myUid, other.uid]
            let invited = [other] + people.filter { seen.insert($0.uid).inserted }
            guard let roomId = await GroupCallService.shared.startAdhoc(with: invited, video: video) else {
                // The room could not be made. The 1:1 is already gone here, so end it for the peer
                // the ordinary way rather than leave them talking to nobody.
                await Self.writeWithRetry(ref, ["status": "ended", "endReason": EndReason.hangup.rawValue])
                // And say so, with the way back (audit M-029 round 1, 2026-10-07): the call ended
                // with no word at all, and calling them again meant finding them from scratch.
                Self.offerCallBack(uid: peerUid, name: peerShownName, photo: peerPhoto, video: video)
                return
            }
            await Self.writeWithRetry(ref, ["moveTo": roomId, "status": "ended", "endReason": EndReason.hangup.rawValue])
        }
    }

    /// "Add people" failed after the 1:1 was already down (audit M-029 round 1, 2026-10-07). A UIKit
    /// alert on whatever is on top, the same way `offerUnblock` asks. Never stacks on another alert:
    /// if the group side already put up its own notice, that one stands.
    @MainActor
    private static func offerCallBack(uid: String, name: String, photo: String?, video: Bool, tries: Int = 4) {
        guard let top = WebLink.topViewController(), !(top is UIAlertController) else { return }
        if top.isBeingPresented || top.isBeingDismissed {
            guard tries > 0 else { return }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 300_000_000)
                offerCallBack(uid: uid, name: name, photo: photo, video: video, tries: tries - 1)
            }
            return
        }
        let who = name.isEmpty ? "them" : name
        let alert = UIAlertController(title: "Couldn't Add People",
                                      message: "The new call could not start, so your call with \(who) ended.",
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .cancel))
        alert.addAction(UIAlertAction(title: "Call Back", style: .default) { _ in
            CallService.shared.startCall(to: uid, name: name, photo: photo, video: video)
        })
        top.present(alert, animated: true)
    }

    /// Owner audit 2026-10-06 #45: the `moveTo` write was `try?`, so one failure left the peer on a
    /// 1:1 this side had already torn down, talking to nobody until ICE gave up (~30s). Three tries,
    /// a second apart, like `writeCandidate`. Nothing else is waiting on it, so failing quietly after
    /// that is no worse than before.
    private static func writeWithRetry(_ ref: DocumentReference, _ data: [String: Any]) async {
        for attempt in 1...3 {
            do { try await ref.updateData(data); return } catch {
                print("call: moveToGroup write failed (try \(attempt)):", error)
                if attempt < 3 { try? await Task.sleep(nanoseconds: 1_000_000_000) }
            }
        }
    }

    /// The peer's half of `moveToGroup`: close the 1:1 the same quiet way and join the room.
    /// Only an ad-hoc id is followed; anything else in `moveTo` is ignored and the normal end runs.
    private func followMove(to roomId: String) {
        let video = cameraOn
        // A dial that was sent back into a room I belong to (audit M-091, 2026-10-07: the person I
        // rang is in that call and answered with `moveTo` instead of busy) was never a missed call.
        if state == .outgoing { recordWritten = true }
        finishCall(updateRemote: false, clearCallKit: true, localUser: true)
        Task { @MainActor in await GroupCallService.shared.joinAdhoc(roomId: roomId, video: video) }
    }

    private func finishCall(updateRemote: Bool, clearCallKit: Bool, localUser: Bool) {
        guard state != .ended, state != .idle else { return }   // re-entry guard: only finish once
        tearingDown = true   // 1:1 audit check, 2026-10-08: no audio unit start during teardown
        cancelTimers()
        stopRingback()
        // Owner audit 2026-10-06 #9: a dial whose call doc never reached the server was never placed.
        // Unless I cancelled it myself, that is a failure on this phone, not the other person's
        // "No answer" (the 45s ring-out used to land here as .missed on an offline dial).
        let neverPlaced = isCaller && !callDocCreated && connectedDate == nil
        if neverPlaced, !localUser, endReason == .none || endReason == .missed {
            endReason = .failed
        }
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
        // THE END WRITES GET BACKGROUND TIME (audit M-099, 2026-10-07). Ending from the lock screen
        // lets iOS suspend the app as soon as the audio session goes, and the "ended" write and the
        // chat record could be lost with it. One background task covers the writes below and ends
        // when they have all completed, or after ten seconds, whichever is first.
        let endWrites = DispatchGroup()
        let endTask = EndWritesTask()
        // The ringing row write, if one is still in flight (audit M-109): the record and the row
        // delete below run after it, so it can never land last and leave a stray "Ringing" row.
        let pendingRingRow = ringRowTask
        ringRowTask = nil
        if let id = callId { rememberFinished(id) }   // audit M-036
        var wroteMissedRecord = false
        // Write a call record into the chat (once). Each side writes its own row.
        // callId != nil matters: denying the mic on an OUTGOING call hangs up before the call doc is
        // ever created, and the `callId ?? UUID()` fallback below then wrote a phantom "Missed call" row
        // under a random id - for a call that was never placed, and undedupable against the other side.
        // #9: the same goes for a dial that failed before its doc existed: no row in the chat for a
        // call the other person was never offered. (A dial I cancelled myself still logs, as before.)
        if !recordWritten, !otherUid.isEmpty, callId != nil, !(neverPlaced && endReason == .failed) {
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
            wroteMissedRecord = outcome == "missed"
            endWrites.enter()
            Task {
                await pendingRingRow?.value   // audit M-109
                await ChatService.recordCall(cid: cid, callId: cidCallId, callerUid: callerUidVal, outcome: outcome, video: video, durationSec: dur)
                endWrites.leave()
            }
        }
        // A teardown that was told NOT to write a record (glare loser, blocked callee, answered on
        // my other phone all force `recordWritten`) leaves the live "Ringing" row with no finaliser
        // — delete it, or the chat keeps a call that never became anything. Only ever set on the
        // device that CREATED the row, so this cannot race the other side's real record.
        if let ringId = liveRingRowId, !otherUid.isEmpty {
            liveRingRowId = nil
            let cid = [me, otherUid].sorted().joined(separator: "_")
            let row = db.collection("conversations").document(cid)
                .collection("messages").document("call_\(ringId)")
            endWrites.enter()
            Task {
                await pendingRingRow?.value   // audit M-109: delete only after the row exists
                row.delete { _ in endWrites.leave() }
            }
        }
        if updateRemote, let id = callId {
            let ref = db.collection("calls").document(id)
            let reason = endReason
            if isCaller, callDocCreated, !calleeAccepted, connectedDate == nil {
                // A CALLER ENDING A RING, DECIDED ON THE SERVER (audit M-037, 2026-10-07), the same
                // transaction the ring-out uses (`ringOutChecked`): no accept on the doc means the
                // caller gave up first, stamped with `cancelledAt` for the callee's accept to read;
                // an accept already there means both happened at once, so the call ends as a plain
                // hang-up and this side's row is brought to "answered", which is what the callee's
                // phone logs for it. A transaction that cannot run falls back to the old blind end.
                let peer = otherUid, myUid = me, video = startedAsVideo || everVideo
                let fixRow = wroteMissedRecord
                endWrites.enter()
                db.runTransaction({ txn, errPtr -> Any? in
                    let snap: DocumentSnapshot
                    do { snap = try txn.getDocument(ref) } catch {
                        errPtr?.pointee = error as NSError
                        return nil
                    }
                    let d = snap.data() ?? [:]
                    if (d["status"] as? String) == "ended" { return "ended" }
                    if d["acceptedAt"] != nil {
                        txn.updateData(["status": "ended", "endReason": EndReason.hangup.rawValue], forDocument: ref)
                        return "accepted"
                    }
                    txn.updateData(["status": "ended", "endReason": reason.rawValue,
                                    "cancelledAt": FieldValue.serverTimestamp()], forDocument: ref)
                    return "cancelled"
                }) { result, err in
                    if let err {
                        Self.reportToRecovery(err, "call end")   // owner, 2026-10-08
                        ref.updateData(["status": "ended", "endReason": reason.rawValue]) { e in
                            if let e { Self.reportToRecovery(e, "call end") }
                            endWrites.leave()
                        }
                        return
                    }
                    if (result as? String) == "accepted", fixRow, !peer.isEmpty, !myUid.isEmpty {
                        let cid = [myUid, peer].sorted().joined(separator: "_")
                        Task {
                            await ChatService.recordCall(cid: cid, callId: id, callerUid: myUid, outcome: "answered",
                                                         video: video, durationSec: 0)
                            endWrites.leave()
                        }
                        return
                    }
                    endWrites.leave()
                }
            } else if !isCaller, !wasAccepted {
                // 1:1 audit r2 A1, 2026-10-08: a ring this device never answered (decline, 60 s
                // timer) ends the shared doc only if NO device answered it. A stale second phone
                // used to end the call I was talking on from my other phone. Nothing is written
                // when `acceptedAt` or another device's claim is already there; no blind fallback.
                let claim = Self.deviceClaim
                endWrites.enter()
                db.runTransaction({ txn, errPtr -> Any? in
                    let snap: DocumentSnapshot
                    do { snap = try txn.getDocument(ref) } catch {
                        errPtr?.pointee = error as NSError
                        return nil
                    }
                    let d = snap.data() ?? [:]
                    if (d["status"] as? String) == "ended" || d["acceptedAt"] != nil { return nil }
                    if let owner = d["answeredDevice"] as? String, !owner.isEmpty, owner != claim { return nil }
                    txn.updateData(["status": "ended", "endReason": reason.rawValue], forDocument: ref)
                    return nil
                }) { _, err in
                    if let err { Self.reportToRecovery(err, "call end") }
                    endWrites.leave()
                }
            } else {
                endWrites.enter()
                ref.updateData(["status": "ended", "endReason": reason.rawValue]) { err in
                    if let err { Self.reportToRecovery(err, "call end") }   // owner, 2026-10-08
                    endWrites.leave()
                }
            }
        }
        endWrites.notify(queue: .main) { endTask.end() }
        // Save the measurement for a call that never connected. writeTimeline is once-only, so a
        // call that DID connect already wrote its own and this is a no-op. Named by how it ended, so
        // a ring-out is never read as a slow connect.
        mark("ended")
        writeTimeline(outcome: endReason == .none ? "ended" : endReason.rawValue)
        listeners.forEach { $0.remove() }
        listeners = []
        ringingWatcher?.remove(); ringingWatcher = nil
        // Nothing of this call is attached again after this (owner, 2026-10-08).
        callDocListener = nil; callDocWatch = nil
        candidatesListener = nil; candidatesWatch = nil
        ringingWatchId = nil
        appliedCandidateIds = []
        // The "sharing video" note must never outlive its call.
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["call-video-sharing"])
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["call-video-sharing"])
        // The system PiP must never outlive its call either (his Facebook screenshot: call over,
        // Apple's floating window still riding on top of every app showing the frozen avatar).
        // The only teardown lived in CallView.onDisappear, and a BACKGROUNDED end never fires it —
        // the cover is still "presented" while another app is frontmost. This funnel is the one
        // place every end passes through, foreground or background; teardown() is idempotent.
        CallPiPController.shared.teardown()
        // The route observer was installed on the first .active call and NEVER removed, so it lived for
        // the app's lifetime and kept running updateAudioRoute() — mutating isSpeaker and re-running
        // screen behaviour — with no call in progress at all.
        if let obs = routeObserver { NotificationCenter.default.removeObserver(obs); routeObserver = nil }
        stopAudioRecoveryObservation()
        if let obs = thermalObserver { NotificationCenter.default.removeObserver(obs); thermalObserver = nil }
        // Its pending step-up belongs to this call; left queued it restarted the NEXT call's capture
        // once if that call began within 10s (owner audit 2026-10-06 #45).
        thermalStepUpWork?.cancel(); thermalStepUpWork = nil
        stopHeartbeat()
        stopPathMonitor()
        // The camera used to keep capturing through the whole 1-2s .ended tail, because teardown only
        // happened at .idle. Nobody can see those frames; stop them the moment the call is over.
        // The screen share too, and the broadcast with it: the red indicator must not outlive the
        // call (either side hanging up, a drop, a decline all pass through here). No signal: the call
        // document is finished with.
        stopScreenShare(requestExtensionStop: true, signal: false)
        videoCapturer?.stopCapture()
        localVideoTrack?.isEnabled = false
        stopPausedCameraRetry()
        // 1:1 audit #21 (owner, 2026-10-08): close() blocks until WebRTC has torn the connection
        // down, and it ran on main ahead of the state change and CallKit's end. Let go of it here
        // and close it off the main thread. Every delegate callback already checks `=== self.pc`.
        if let closing = pc {
            DispatchQueue.global(qos: .userInitiated).async { closing.close() }
        }
        pc = nil
        localAudioTrack = nil          // 1:1 audit #42: no mic source held between calls
        if let id = callId { ringRechecked.remove(id) }   // #42: the set no longer only grows
        // #25 + 1:1 audit check, 2026-10-08: busy the held losers only if my call doc exists;
        // a dial that never landed lets them ring here instead.
        if !pendingGlareBusy.isEmpty {
            if callDocCreated { flushGlareBusy() } else { releaseGlareLosers() }
        }
        // 1:1 audit #1: captured before `isCaller` is cleared below. Only someone who was in the call
        // hears the end tone; a ring this phone never answered ends silently.
        let heardCall = isCaller || wasAccepted || connectedDate != nil
        callId = nil
        currentCallCreatedAt = nil   // audit M-005/M-006
        dialCreateStarted = false    // audit M-112
        dialStartedAt = nil          // audit M-155
        otherRawName = ""            // audit M-151
        otherUid = ""
        peerIsEstablishedContact = false   // never inherited by the next call
        peerTrustPending = false           // 2026-09-24 fix-all #231
        heldPreAnswer = nil                // 2026-09-24 fix-all #230
        iceDroppedDuringRing = false       // owner audit 2026-10-06 #15: belongs to this call's path
        isCaller = false

        // Feedback tone for the non-initiating side / system-ended calls. Keep the audio
        // session alive until the tone finishes, THEN clear CallKit (which deactivates it).
        let reason = endReason
        // What iOS is told (owner audit 2026-10-06 #20): it decides Recents. Answered on my other
        // phone; a ring that never connected and that nobody here ended (caller cancelled, rang out);
        // a failure; otherwise the plain remote end.
        // 1:1 audit r2 C2, 2026-10-08: declined or busy on my other device → declined elsewhere.
        let kitEnd: CallKitManager.EndKind =
            declinedElsewhere ? .declinedElsewhere
            : endedElsewhere ? .answeredElsewhere
            : reason == .failed ? .failed
            : (connectedDate == nil && !localUser) ? .unanswered
            : .remote
        endedElsewhere = false
        declinedElsewhere = false
        // Owner audit 2026-10-06 #45: which end this is. The tone and idle timers below used to check
        // only `state == .ended`, so a later call that also ended inside an earlier call's window had
        // its own tone and end label cut short by the earlier call's timers.
        endSeq &+= 1
        let thisEnd = endSeq
        if !localUser, reason != .none, heardCall {
            playEndTone(reason)
            let toneDur = (reason == .busy) ? 2.0 : 0.6   // matches loops: 1 (declined plays the short ended tone now)
            // Audit 2026-09-24: this delayed end read activeUUID when it FIRED, so a new call that
            // rang inside the tone window (a callback right after a drop) had its own CallKit ring
            // ended by the old call's cleanup. Only end the system call this call owned.
            let endingUUID = CallKitManager.shared.activeUUID
            // 1:1 audit r2 C3, 2026-10-08: a redial inside the tone reports THIS reason, not .remote.
            if clearCallKit { pendingKitEnd = kitEnd }
            DispatchQueue.main.asyncAfter(deadline: .now() + toneDur) {
                if self.endSeq == thisEnd { self.pendingKitEnd = nil }
                if self.state == .ended, self.endSeq == thisEnd { self.stopTone() }
                if clearCallKit, CallKitManager.shared.activeUUID == endingUUID {
                    CallKitManager.shared.reportEnded(kitEnd)
                }
            }
        } else if clearCallKit {
            CallKitManager.shared.reportEnded(kitEnd)
        }

        // I pressed End myself: close at once, no end label (owner's order 2026-10-04, the
        // reference behaviour). A caller hanging up before an answer used to read "Couldn't reach
        // them", which blamed the other person for my own tap. The `.ended` tail is cosmetic
        // (see observeIncoming), so skipping it is safe. Mic-denied keeps its tail to be read.
        if localUser, !micDenied {
            state = .idle
            return
        }
        state = .ended
        // Keep the final state visible briefly (longer for the busy tone) before idle.
        // The mic-denied line needs time to be read; one second is gone before the eye lands on it.
        let idleDelay = ((!localUser && reason == .busy) || micDenied) ? 2.0 : 1.0
        DispatchQueue.main.asyncAfter(deadline: .now() + idleDelay) {
            if self.state == .ended, self.endSeq == thisEnd { self.state = .idle }
        }
    }
    /// Bumped once per finished call; see the #45 note in `finishCall`.
    private var endSeq = 0
    /// 1:1 audit r2 C3, 2026-10-08: the CallKit end the tone path is holding back; closeEndedTail
    /// reports it if a new call cuts the tone short.
    private var pendingKitEnd: CallKitManager.EndKind?
}

/// Background time for one call's end writes (audit M-099, 2026-10-07). Begun on creation, ended
/// once by whichever comes first: `end()` when the writes complete, the ten-second cap, or iOS
/// reclaiming the time. Off the main thread it does nothing (the end path runs on main).
private final class EndWritesTask {
    private var id: UIBackgroundTaskIdentifier = .invalid

    init() {
        guard Thread.isMainThread else { return }
        MainActor.assumeIsolated {
            self.id = UIApplication.shared.beginBackgroundTask(withName: "call-end-writes") { [self] in self.end() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [self] in self.end() }
    }

    func end() {
        guard Thread.isMainThread else { DispatchQueue.main.async { self.end() }; return }
        guard id != .invalid else { return }
        let ending = id
        id = .invalid
        MainActor.assumeIsolated { UIApplication.shared.endBackgroundTask(ending) }
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
        // ⭐ THE TWO NUMBERS THAT SETTLE THE RELAY ARGUMENT, and they are readable from a call
        // nobody answers — which is the only test that can be run alone, at night, with the other
        // person asleep.
        //
        // `firstCandidate` is the phone finding its own address: near-instant, and a baseline.
        // `firstRelayCandidate` is the relay answering, which means the credentials fetch, the
        // journey to whichever relay we were given, and the allocation handshake, all in one
        // number. If that is seconds, the relay is the problem and no amount of tuning here helps.
        // If it is tens of milliseconds, the relay was never the problem and the answer is
        // elsewhere.
        let isRelay = candidate.sdp.contains(" typ relay")
        DispatchQueue.main.async {
            guard peerConnection === self.pc else { return }   // #45: a closed call's late candidate
            self.mark("firstCandidate")
            if isRelay { self.mark("firstRelayCandidate") }
            // Buffer until the call doc exists (else the write is rule-denied + lost — C2).
            if self.callDocCreated, let col = self.myCandidatesCollection { self.writeCandidate(data, to: col) }
            else { self.localCandidateBuffer.append(data) }
        }
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        DispatchQueue.main.async {
            // Owner audit 2026-10-06 #45: a state change queued by the connection a hang-up just
            // closed used to run after the idle reset, and `.connected` set `mediaReady` again, so
            // the NEXT call started its timer the instant it was accepted. finishCall nils `pc`, so
            // anything not from the live connection is a leftover.
            guard peerConnection === self.pc else { return }
            // 1:1 audit #9 (owner, 2026-10-08): ICE checking new routes is a restart making progress.
            self.iceCheckingSince = newState == .checking ? (self.iceCheckingSince ?? Date()) : nil
            switch newState {
            case .connected, .completed:
                // Audit M-042: ICE up over a failed DTLS transport is not media. Stay down; the
                // reconnect cap ends the call.
                guard !self.transportFailed else { break }
                self.lastIceConnectedAt = Date()   // 1:1 audit #20
                self.iceDroppedDuringRing = false
                // ⭐ THE MEDIA PATH BEING UP IS NO LONGER THE SAME EVENT AS THE CALL STARTING, and
                // splitting those two is the whole of the pre-negotiation change.
                //
                // The connection is now built while the phone is still RINGING, so this fires before
                // anybody has accepted. Treating it as "connected" there would start the duration
                // timer on an unanswered call, tell CallKit the call is up, and flip the chat row to
                // Ongoing — all for a call the person has not yet touched.
                self.mediaReady = true
                self.mark("mediaReady")
                self.recovered()                          // back to a healthy media path
                self.beginConnectedCallIfAccepted()
            case .disconnected, .failed:
                // Owner audit 2026-10-06 #15: the path is down, so it is no longer "ready". Left
                // true, a drop during the ring let the accept start the call (timer, CallKit
                // "connected") onto a dead path, and no later ICE event ever came to notice.
                self.mediaReady = false
                // Still ringing: there is no call to reconnect yet (enterReconnecting only runs
                // from .active), so remember it and start the reconnect the moment it is answered.
                if self.state == .incoming || self.state == .outgoing {
                    self.iceDroppedDuringRing = true
                    return
                }
                // `disconnected` may self-heal, but 3s of dead air was the old wait; 1s is enough to
                // skip a blip. `failed` won't self-heal; restart now.
                self.enterReconnecting(restartAfter: newState == .failed ? 0 : 1)
            case .closed:
                if self.state == .active || self.state == .reconnecting {
                    self.endReason = .failed; self.hangUp()
                }
            default:
                break
            }
        }
    }
    /// Audit M-042, 2026-10-07: the WHOLE connection's state, ICE plus DTLS. "Connected" was judged
    /// by ICE alone, so a DTLS handshake that failed on a path ICE called good left a call that read
    /// connected and carried nothing, with no reconnect and no give-up. `.failed` here now takes the
    /// same road as ICE `.failed`: Reconnecting, a restart, and the 30s cap ends it if nothing heals.
    /// The other states are left to the ICE handler above, which already owns them.
    ///
    /// Only a failure with ICE still up is handled here: an ICE failure also fails the whole
    /// connection, and the ICE handler already takes that one. A failed DTLS transport does not come
    /// back, and ICE reconnecting after a restart must not read as recovered on top of it, so
    /// `transportFailed` holds `mediaReady` down for the rest of the call (see the ICE handler).
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        guard newState == .failed else { return }
        // Read here, on the signalling thread the delegate runs on, before the hop.
        let ice = peerConnection.iceConnectionState
        guard ice == .connected || ice == .completed else { return }
        DispatchQueue.main.async {
            guard peerConnection === self.pc else { return }   // #45: not a closed call's leftover
            print("call: M-042 connection failed with ICE up (DTLS)")
            self.transportFailed = true
            self.mediaReady = false
            // Still ringing: the same "dropped during the ring" mark the ICE handler sets, so the
            // answer goes to Reconnecting. Answered: Reconnecting now. Either way the 30s cap ends
            // it as Failed.
            if self.state == .incoming || self.state == .outgoing {
                self.iceDroppedDuringRing = true
                return
            }
            self.enterReconnecting(restartAfter: 0)
        }
    }
    // Unused delegate methods (required by protocol).
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    /// The callee's end of the accept channel. Only ever used to SEND, once, on accept.
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        guard dataChannel.label == Self.acceptChannelLabel else { return }
        DispatchQueue.main.async {
            guard peerConnection === self.pc else { return }   // #45: never adopt a dead call's channel
            dataChannel.delegate = self
            self.acceptChannel = dataChannel
            // Answered already? Then the channel opened late and the message is owed right now.
            if self.wasAccepted { self.sendAcceptOverChannel() }
        }
    }

    // Unified-plan remote track arrival: grab the remote video track for rendering.
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams mediaStreams: [RTCMediaStream]) {
        if let track = rtpReceiver.track as? RTCVideoTrack {
            // Screen share v3: the SECOND video transceiver's receiver is their screen; the first is
            // their camera, as always. Worked out here, on the thread that delivered the receiver.
            let isScreen = screenTransceiver(in: peerConnection)?.receiver.receiverId == rtpReceiver.receiverId
            // Just bind the remote feed for rendering. isVideo is driven by the consent handshake (or
            // the initial call type) — NOT flipped here, so an unsolicited track can't force video on.
            DispatchQueue.main.async {
                guard peerConnection === self.pc else { return }   // #45: not after the reset nilled it
                if isScreen { self.remoteScreenTrack = track } else { self.remoteVideoTrack = track }
            }
        }
    }
}

// MARK: - RTCDataChannelDelegate (the accept accelerator)
//
// One message, one direction: the callee says "accepted" and the caller acts on it. See the note on
// `acceptChannel` — this is an accelerator with no correctness resting on it, so every path here
// fails silently back to the Firestore route.
extension CallService: RTCDataChannelDelegate {
    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        guard dataChannel.label == Self.acceptChannelLabel else { return }
        // The channel can open AFTER the person has already tapped, on a slow negotiation. Owed
        // message goes out the moment it can.
        DispatchQueue.main.async {
            if dataChannel.readyState == .open, !self.isCaller, self.wasAccepted {
                self.sendAcceptOverChannel()
            }
        }
    }

    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        guard dataChannel.label == Self.acceptChannelLabel, !buffer.isBinary,
              String(data: buffer.data, encoding: .utf8) == Self.acceptMessage else { return }
        DispatchQueue.main.async { self.acceptArrivedOverChannel() }
    }
}

/// 1:1 audit r2 E4, 2026-10-08: calls `onFirst` once, on main, when the next frame reaches the track
/// it is added to. Used to resolve a front/back switch on the new camera's first frame.
private final class FirstFrameProbe: NSObject, RTCVideoRenderer {
    private let lock = NSLock()
    private var fired = false   // under `lock`
    private let onFirst: () -> Void
    init(_ onFirst: @escaping () -> Void) { self.onFirst = onFirst; super.init() }

    func setSize(_ size: CGSize) {}

    func renderFrame(_ frame: RTCVideoFrame?) {
        guard frame != nil else { return }
        lock.lock()
        let first = !fired
        fired = true
        lock.unlock()
        if first { DispatchQueue.main.async(execute: onFirst) }
    }
}
