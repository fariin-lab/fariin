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

    private override init() {
        let config = CXProviderConfiguration()
        config.supportsVideo = true
        config.maximumCallsPerCallGroup = 1
        config.supportedHandleTypes = [.generic]
        // Branded incoming ringtone (bundled resource) instead of the generic iOS ring — this is
        // what the RECEIVER hears while their phone rings, the way WhatsApp/Signal ship their own.
        // CallKit loops it for the whole ring. Swap the file to change the sound; keep the name.
        config.ringtoneSound = "kulan_ringtone.wav"
        provider = CXProvider(configuration: config)
        super.init()
        provider.setDelegate(self, queue: nil)
        // WebRTC must not touch the audio session itself under CallKit.
        RTCAudioSession.sharedInstance().useManualAudio = true
        RTCAudioSession.sharedInstance().isAudioEnabled = false
    }

    // MARK: - Outgoing
    @discardableResult
    func startOutgoing(name: String) -> UUID {
        let uuid = UUID()
        activeUUID = uuid
        activeCallId = nil
        let action = CXStartCallAction(call: uuid, handle: CXHandle(type: .generic, value: name))
        controller.request(CXTransaction(action: action)) { _ in }
        return uuid
    }
    func reportConnecting() { if let u = activeUUID { provider.reportOutgoingCall(with: u, startedConnectingAt: nil) } }
    func reportConnected() { if let u = activeUUID { provider.reportOutgoingCall(with: u, connectedAt: nil) } }

    // MARK: - Incoming (idempotent per callId so two paths can't make two UUIDs)
    func reportIncoming(callId: String, name: String, video: Bool = false, completion: (() -> Void)? = nil) {
        if activeCallId == callId, activeUUID != nil { completion?(); return }
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
        provider.reportNewIncomingCall(with: uuid, update: update) { _ in completion?() }
    }

    // Reflect a mid-call video<->voice switch in the system call UI (green pill shows the camera glyph).
    func updateHasVideo(_ hasVideo: Bool) {
        guard let uuid = activeUUID else { return }
        let update = CXCallUpdate(); update.hasVideo = hasVideo
        provider.reportCall(with: uuid, updated: update)
    }

    // MARK: - End
    func end() {   // user pressed End in our UI -> route through CallKit (handler does teardown)
        guard let uuid = activeUUID else { return }
        controller.request(CXTransaction(action: CXEndCallAction(call: uuid))) { _ in }
    }
    /// Remote hung up / call failed — clear the system UI without a user action.
    func reportEnded() {
        if let uuid = activeUUID { provider.reportCall(with: uuid, endedAt: nil, reason: .remoteEnded) }
        activeUUID = nil; activeCallId = nil
    }
}

extension CallKitManager: CXProviderDelegate {
    func providerDidReset(_ provider: CXProvider) { CallService.shared.hangUp() }

    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        configureAudio()
        action.fulfill()
        provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: nil)
    }
    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        configureAudio()
        CallService.shared.answer()
        action.fulfill()
    }
    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        CallService.shared.endFromCallKit()   // CallKit already ending -> don't double-report
        activeUUID = nil; activeCallId = nil
        action.fulfill()
    }

    // Mute toggled from the SYSTEM call UI (lock screen / green pill) — mirror it into our engine,
    // else the system mute button did nothing (audio kept sending). Guarded so it can't loop.
    func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        if CallService.shared.isMuted != action.isMuted { CallService.shared.toggleMute() }
        action.fulfill()
    }

    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        let s = RTCAudioSession.sharedInstance()
        s.lockForConfiguration()
        try? s.setCategory(.playAndRecord, mode: .voiceChat, options: [])
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
        RTCAudioSession.sharedInstance().audioSessionDidDeactivate(audioSession)
        RTCAudioSession.sharedInstance().isAudioEnabled = false
    }

    private func configureAudio() {
        let s = RTCAudioSession.sharedInstance()
        s.lockForConfiguration()
        try? s.setCategory(.playAndRecord, mode: .voiceChat, options: [])
        try? s.setMode(.voiceChat)
        s.unlockForConfiguration()
    }
}
