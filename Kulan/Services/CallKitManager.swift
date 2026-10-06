import Foundation
import CallKit
import AVFoundation
import WebRTC

// Bridges our WebRTC calls to the native iOS call UI (CallKit): the green status
// pill, the system call screen with Speaker/Mic/Hang-up, and (with VoIP push)
// lock-screen ringing. Handles the audio-session hand-off WebRTC needs under CallKit.
//
// NOTE: untested from CI — CallKit + live audio need two real devices.
final class CallKitManager: NSObject {
    static let shared = CallKitManager()

    private let provider: CXProvider
    private let controller = CXCallController()
    private(set) var activeUUID: UUID?
    private(set) var activeCallId: String?   // maps the system call UUID to our callId

    // owner, 2026-10-06: a group ring (GroupCallRinging) has its OWN CallKit call, never
    // `activeUUID`, so every 1:1 path above and below runs exactly as before. Each delegate method
    // looks at the action's UUID first and hands a group one to the group side.
    private(set) var groupUUID: UUID?
    /// A group call answered through CallKit: its audio follows the LiveKit SDK's CallKit recipe
    /// (`GroupCallKitAudio`) until the call ends. False for every call joined inside the app.
    private var groupAudioUnderCallKit = false
    /// CallKit activated the audio session for the group call, and has not deactivated it yet.
    /// Kept apart from the flag above because the deactivation arrives AFTER the call has ended.
    private var groupAudioSessionLive = false

    /// Provider config for a given ringtone file.
    ///
    /// ⛔ CALLKIT WILL ONLY RING A FILE THAT SHIPS IN OUR BUNDLE. Apple's own words for this
    /// property: "the name of the sound resource in the app bundle". Not a path, not a URL, not a
    /// system sound id — which is why the Call Sound picker cannot list Reflection, Buoyant, Pond or
    /// any other iOS ringtone by name. Passing nil is the one route to those, and it hands the
    /// choice to the phone rather than making it here; see `NotificationSound.systemRingtone`.
    private static func makeConfig(ringtone: String?) -> CXProviderConfiguration {
        let config = CXProviderConfiguration()
        config.supportsVideo = true
        config.maximumCallsPerCallGroup = 1
        config.supportedHandleTypes = [.generic]
        // What the RECEIVER hears while their phone rings. CallKit loops it for the whole ring.
        config.ringtoneSound = ringtone
        return config
    }

    private override init() {
        provider = CXProvider(configuration: Self.makeConfig(ringtone: NotificationSound.defaultRingtone.bundleFile))
        super.init()
        provider.setDelegate(self, queue: nil)
        // WebRTC must not touch the audio session itself under CallKit.
        RTCAudioSession.sharedInstance().useManualAudio = true
        RTCAudioSession.sharedInstance().isAudioEnabled = false
    }

    /// Point the provider at whatever ringtone this chat is set to.
    ///
    /// ⚠️ NIL IS NOT SILENCE. It used to say here that a nil ringtone meant this chat was set to
    /// None and the call would arrive quietly. CallKit rings something for every incoming call, and
    /// with no bundle filename it rings whatever the phone is set to in Settings — which is exactly
    /// why nil is now offered on purpose, under the name it deserves. See
    /// `NotificationSound.systemRingtone`.
    private func applyRingtone(callerUid: String?) {
        let cid: String? = {
            guard let callerUid, !callerUid.isEmpty, let me = AuthService.shared.uid else { return nil }
            return ChatService.convId(me, callerUid)
        }()
        let file = SoundStore.ringtoneFile(cid)
        guard provider.configuration.ringtoneSound != file else { return }
        provider.configuration = Self.makeConfig(ringtone: file)
    }

    // MARK: - Outgoing
    @discardableResult
    func startOutgoing(name: String, video: Bool = false) -> UUID {
        let uuid = UUID()
        activeUUID = uuid
        activeCallId = nil
        let action = CXStartCallAction(call: uuid, handle: CXHandle(type: .generic, value: name))
        // A video call shows as video in the system UI and Recents from the start, not only after
        // the camera is toggled (owner audit 2026-10-06 #32).
        action.isVideo = video
        controller.request(CXTransaction(action: action)) { error in
            // A FAILED start action (iOS refuses while a cellular call is up, etc.) means CallKit
            // never performs the action and never activates the audio session — so the call could
            // signal, "connect", and carry NO audio in either direction, with the error thrown away
            // (audit). Tear it down instead of leaving a silent call standing.
            guard error != nil else { return }
            DispatchQueue.main.async { CallService.shared.endFromCallKit() }
        }
        return uuid
    }
    func reportConnecting() { if let u = activeUUID { provider.reportOutgoingCall(with: u, startedConnectingAt: nil) } }

    // Keep the SYSTEM call UI (lock screen/dynamic island) mute state in sync with the in-app toggle.
    func setMuted(_ muted: Bool) {
        guard let u = activeUUID else { return }
        controller.request(CXTransaction(action: CXSetMutedCallAction(call: u, muted: muted))) { _ in }
    }
    func reportConnected() { if let u = activeUUID { provider.reportOutgoingCall(with: u, connectedAt: nil) } }

    // MARK: - Incoming (idempotent per callId so two paths can't make two UUIDs)
    /// `callerUid` is only used to find the per-chat Call Sound. The ringtone has to be set on the
    /// PROVIDER before the call is reported — there is no per-call ringtone property — so the config
    /// is swapped here, right before reporting.
    func reportIncoming(callId: String, name: String, video: Bool = false,
                        callerUid: String? = nil, completion: (() -> Void)? = nil) {
        if activeCallId == callId, activeUUID != nil { completion?(); return }
        applyRingtone(callerUid: callerUid)
        // A DIFFERENT call is already live/ringing: iOS requires reporting something for a VoIP
        // push, but this second caller must NOT steal activeUUID (End would then target the wrong
        // system call). Report a transient call and end it immediately (busy).
        if activeUUID != nil {
            let uuid = UUID()
            let update = CXCallUpdate()
            update.remoteHandle = CXHandle(type: .generic, value: name)
            update.hasVideo = video
            provider.reportNewIncomingCall(with: uuid, update: update) { [provider] _ in
                provider.reportCall(with: uuid, endedAt: nil, reason: .unanswered)
                completion?()
            }
            return
        }
        let uuid = UUID()
        activeUUID = uuid
        activeCallId = callId
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: name)
        update.hasVideo = video
        provider.reportNewIncomingCall(with: uuid, update: update) { [weak self] error in
            // If iOS REFUSES to report it (its own block list, a Focus filter), there is no ring and
            // no system call — but activeUUID/activeCallId were left pointing at it, so the app sat
            // in .incoming with no UI and End could not clear it until the caller's 45s timeout
            // (audit). Release the handles and tear our side down.
            if error != nil {
                DispatchQueue.main.async {
                    if self?.activeUUID == uuid { self?.activeUUID = nil; self?.activeCallId = nil }
                    CallService.shared.endFromCallKit()
                }
            }
            completion?()
        }
    }

    /// 2026-09-24 audit: a VoIP push that names no call. iOS still requires a report for every VoIP
    /// push (or it kills the app and stops delivering them), so report a transient call and end it
    /// at once, the same way the busy branch above does, without touching any call state.
    func reportAndDiscard(completion: @escaping () -> Void) {
        let uuid = UUID()
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: "Call")
        provider.reportNewIncomingCall(with: uuid, update: update) { [provider] _ in
            provider.reportCall(with: uuid, endedAt: nil, reason: .failed)
            completion()
        }
    }

    // Reflect a mid-call video<->voice switch in the system call UI (green pill shows the camera glyph).
    func updateHasVideo(_ hasVideo: Bool) {
        guard let uuid = activeUUID else { return }
        let update = CXCallUpdate(); update.hasVideo = hasVideo
        provider.reportCall(with: uuid, updated: update)
    }

    // MARK: - Group rings (owner, 2026-10-06)

    /// CXProviderDelegate is not on the main actor. Its queue is the main queue (`queue: nil`), so
    /// this runs the work in place there, and hops when it is ever called from somewhere else.
    private func onMain(_ work: @escaping @MainActor () -> Void) {
        if Thread.isMainThread { MainActor.assumeIsolated { work() } }
        else { Task { @MainActor in work() } }
    }

    /// Rings for a group call. Reports to CallKit before returning, as a VoIP push requires;
    /// `completion` is PushKit's.
    func reportGroupRing(uuid: UUID, name: String, video: Bool, completion: @escaping () -> Void) {
        applyRingtone(callerUid: nil)   // the phone-wide Call Sound; a group ring has no chat of its own
        groupUUID = uuid
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: name)
        update.hasVideo = video
        update.supportsHolding = false
        provider.reportNewIncomingCall(with: uuid, update: update) { [weak self] error in
            // Refused by iOS (Focus, its block list): no ring and no system call. Let go of it.
            if error != nil {
                DispatchQueue.main.async {
                    if self?.groupUUID == uuid { self?.groupUUID = nil }
                    MainActor.assumeIsolated { GroupCallRinging.shared.ringRefused(uuid: uuid) }
                }
            }
            completion()
        }
    }

    /// The ring stopped, or the answered group call is over, without a tap in CallKit.
    func endGroupCall(uuid: UUID, reason: CXCallEndedReason) {
        provider.reportCall(with: uuid, endedAt: nil, reason: reason)
        if groupUUID == uuid { groupUUID = nil; endGroupAudio() }
    }

    /// Puts the SDK's audio defaults back, once, when a CallKit-answered group call ends.
    private func endGroupAudio() {
        guard groupAudioUnderCallKit else { return }
        groupAudioUnderCallKit = false
        GroupCallKitAudio.restoreDefaults()
    }

    /// The in-app mic button, mirrored into the system call screen (CallKit-answered calls only).
    func setGroupMuted(_ muted: Bool) {
        guard let u = groupUUID, groupAudioUnderCallKit else { return }
        controller.request(CXTransaction(action: CXSetMutedCallAction(call: u, muted: muted))) { _ in }
    }

    /// The in-app speaker button (CallKit-answered calls only; see `GroupCallKitAudio.route`).
    func applyGroupSpeaker(_ on: Bool) {
        guard groupAudioUnderCallKit, groupAudioSessionLive else { return }
        GroupCallKitAudio.route(speaker: on)
    }

    func updateGroupVideo(_ hasVideo: Bool, uuid: UUID) {
        guard groupUUID == uuid else { return }
        let update = CXCallUpdate(); update.hasVideo = hasVideo
        provider.reportCall(with: uuid, updated: update)
    }

    // MARK: - End
    func end() {   // user pressed End in our UI -> route through CallKit (handler does teardown)
        guard let uuid = activeUUID else {
            // No CallKit call to end. This used to `return` and the End button did NOTHING — the user's
            // only way out of a live call silently failing. CallKit is how teardown normally reaches
            // CallService, so with no UUID we have to call it ourselves.
            CallService.shared.endFromCallKit()
            return
        }
        controller.request(CXTransaction(action: CXEndCallAction(call: uuid))) { error in
            // Same reasoning as the nil-UUID branch above: if the end action itself fails, the End
            // button silently did nothing. Fall back to tearing our side down directly.
            guard error != nil else { return }
            DispatchQueue.main.async { CallService.shared.endFromCallKit() }
        }
    }
    /// Why a call ended without a user action here. iOS uses the reason for Recents: a ring answered
    /// on my other phone must not log as missed, and a ring nobody picked up is "unanswered", not
    /// "remote ended" (owner audit 2026-10-06 #20; the reference app reports each reason).
    enum EndKind { case remote, unanswered, answeredElsewhere, failed }

    /// Remote hung up / call failed — clear the system UI without a user action.
    func reportEnded(_ kind: EndKind = .remote) {
        let reason: CXCallEndedReason
        switch kind {
        case .remote:            reason = .remoteEnded
        case .unanswered:        reason = .unanswered
        case .answeredElsewhere: reason = .answeredElsewhere
        case .failed:            reason = .failed
        }
        if let uuid = activeUUID { provider.reportCall(with: uuid, endedAt: nil, reason: reason) }
        activeUUID = nil; activeCallId = nil
    }
}

extension CallKitManager: CXProviderDelegate {
    func providerDidReset(_ provider: CXProvider) {
        // owner, 2026-10-06: the group ring or call goes with every other call.
        if groupUUID != nil || groupAudioUnderCallKit {
            groupUUID = nil
            endGroupAudio()
            onMain { GroupCallRinging.shared.providerReset() }
        }
        CallService.shared.hangUp()
    }

    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        configureAudio()
        action.fulfill()
        provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: nil)
    }
    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        // owner, 2026-10-06: a group ring answered in CallKit. Audio per the SDK's CallKit recipe,
        // set up BEFORE the room connects; the join itself runs on the main actor.
        if let group = groupUUID, group == action.callUUID {
            groupAudioUnderCallKit = true
            GroupCallKitAudio.prepare()
            onMain {
                // The ring already gone on the group side: no call may keep the audio switched over.
                if !GroupCallRinging.shared.answeredFromCallKit(uuid: group) {
                    CallKitManager.shared.endGroupCall(uuid: group, reason: .failed)
                }
            }
            action.fulfill()
            return
        }
        configureAudio()
        CallService.shared.answer()
        action.fulfill()
    }
    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        // owner, 2026-10-06: End on a group ring declines it; on an answered group call it hangs up.
        if let group = groupUUID, group == action.callUUID {
            groupUUID = nil
            endGroupAudio()
            onMain { GroupCallRinging.shared.endedFromCallKit(uuid: group) }
            action.fulfill()
            return
        }
        // Only OUR call's End tears the call down. A transient busy report (`reportIncoming`'s
        // second-caller branch) has its own UUID; a Decline tapped on it in the instant it shows
        // must not end the live call (owner audit 2026-10-06, CallKit section).
        if let live = activeUUID, live != action.callUUID { action.fulfill(); return }
        CallService.shared.endFromCallKit()   // CallKit already ending -> don't double-report
        activeUUID = nil; activeCallId = nil
        action.fulfill()
    }

    // Mute toggled from the SYSTEM call UI (lock screen / green pill) — mirror it into our engine,
    // else the system mute button did nothing (audio kept sending). Guarded so it can't loop.
    func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        if let group = groupUUID, group == action.callUUID {   // owner, 2026-10-06: the group call's mic
            let muted = action.isMuted
            onMain {
                let service = GroupCallService.shared
                if service.isActive, service.micOn == muted { service.toggleMic() }
            }
            action.fulfill()
            return
        }
        if let live = activeUUID, live != action.callUUID { action.fulfill(); return }   // not our call
        if CallService.shared.isMuted != action.isMuted { CallService.shared.toggleMute() }
        action.fulfill()
    }

    // HOLD. There was no handler at all, so when a normal cellular call arrived mid-call iOS had no way
    // to put us on hold and the outcome was undefined — while the other side saw a running timer, silence
    // and no explanation, with that dead air counted into the call duration. Now we actually go quiet and
    // tell them, and unhold restores whatever the user's own mute setting was.
    func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) {
        // owner, 2026-10-06: a group call is not held by us; the audio session going away and
        // coming back (didDeactivate / didActivate below) is what stops and restarts its sound.
        if let group = groupUUID, group == action.callUUID { action.fulfill(); return }
        if let live = activeUUID, live != action.callUUID { action.fulfill(); return }   // not our call
        CallService.shared.setHeld(action.isOnHold)
        action.fulfill()
    }

    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        // owner, 2026-10-06: a group call answered through CallKit. The LiveKit engine may start
        // only now; the 1:1 engine below is not touched.
        if groupAudioUnderCallKit {
            groupAudioSessionLive = true
            var speaker = true   // group calls start on the speaker
            if Thread.isMainThread { speaker = MainActor.assumeIsolated { GroupCallService.shared.speakerOn } }
            GroupCallKitAudio.activated(audioSession, speaker: speaker)
            return
        }
        groupAudioSessionLive = false
        let s = RTCAudioSession.sharedInstance()
        s.lockForConfiguration()
        // .videoChat when the camera is on: VPIO echo cancellation TUNED FOR LOUDSPEAKER (the echo-
        // on-speaker fix big apps use); .voiceChat (earpiece-tuned) otherwise. Bluetooth allowed.
        try? s.setCategory(.playAndRecord,
                           mode: CallService.shared.cameraOn ? .videoChat : .voiceChat,
                           options: [.allowBluetooth, .allowBluetoothA2DP])
        s.audioSessionDidActivate(audioSession)
        s.isAudioEnabled = true   // turn the WebRTC audio unit ON
        s.unlockForConfiguration()
        // Re-assert the speaker route. Every session (re)activation — first connect, and after any
        // interruption (Siri, an incoming cellular call) — resets the output to the earpiece default,
        // which silently dropped a speakerphone call back to the earpiece while the UI still showed
        // Speaker ON. Reapply what the user chose.
        try? audioSession.overrideOutputAudioPort(CallService.shared.isSpeaker ? .speaker : .none)
        // The audio session is only LIVE now — CallKit owns it (useManualAudio), so it isn't active
        // at startCall time. An AVAudioPlayer started before this point plays into a dead session =
        // the caller hears NO ringback. So (re)start the ringback HERE, once the session is real.
        CallService.shared.audioSessionActivated()
    }
    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        // owner, 2026-10-06: the group call's session going away (the call ended, or a phone call
        // took over). Once the call has ended the defaults are already back and stay.
        if groupAudioSessionLive {
            groupAudioSessionLive = false
            if groupAudioUnderCallKit { GroupCallKitAudio.deactivated() }
            return
        }
        RTCAudioSession.sharedInstance().audioSessionDidDeactivate(audioSession)
        RTCAudioSession.sharedInstance().isAudioEnabled = false
    }

    private func configureAudio() {
        let s = RTCAudioSession.sharedInstance()
        s.lockForConfiguration()
        // .videoChat when the camera is on: VPIO echo cancellation TUNED FOR LOUDSPEAKER (the echo-
        // on-speaker fix big apps use); .voiceChat (earpiece-tuned) otherwise. Bluetooth allowed.
        // NO setMode below this. setCategory(_:mode:options:) already applies the mode, and a second
        // unconditional setMode(.voiceChat) silently undid the .videoChat choice on every start/answer.
        // It dates from a0f483b, when Fariin was voice-only and BOTH lines said .voiceChat; the line
        // above later became video-aware and this leftover was never removed. Effect: video calls
        // answered through CallKit ran with EARPIECE-tuned echo cancellation on loudspeaker, which is
        // the hear-your-own-voice setup that didActivate (:152) was written to avoid.
        try? s.setCategory(.playAndRecord,
                           mode: CallService.shared.cameraOn ? .videoChat : .voiceChat,
                           options: [.allowBluetooth, .allowBluetoothA2DP])
        s.unlockForConfiguration()
    }
}
