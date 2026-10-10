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
    private static func makeConfig(ringtone: String?, inRecents: Bool = true) -> CXProviderConfiguration {
        let config = CXProviderConfiguration()
        config.supportsVideo = true
        config.maximumCallsPerCallGroup = 1
        config.supportedHandleTypes = [.generic]
        // What the RECEIVER hears while their phone rings. CallKit loops it for the whole ring.
        config.ringtoneSound = ringtone
        // 1:1 audit r2 G4, 2026-10-08: "Show Calls in Recents" (Privacy), per call; see `showsInRecents`.
        config.includesCallsInRecents = inRecents
        return config
    }

    /// 1:1 audit r2 G4, 2026-10-08: the setting's UserDefaults key (default on), as in the reference app.
    static let showInRecentsKey = "calls.showInRecents"

    /// 1:1 audit r2 G4: does a call with this person go to the Phone app's Recents? The setting, and
    /// never for a chat opened with my Chat PIN (`acceptedVia == "pin"`). Read from the live chat
    /// list, or the list saved on disk on a cold launch from a push. No peer (group ring): the setting.
    private static func showsInRecents(peerUid: String?) -> Bool {
        let on = UserDefaults.standard.object(forKey: showInRecentsKey) as? Bool ?? true
        guard on else { return false }
        guard let peerUid, !peerUid.isEmpty, let me = AuthService.shared.uid, !me.isEmpty else { return true }
        let cid = ChatService.convId(me, peerUid)
        var conv: Conversation? = Thread.isMainThread
            ? ConversationsRepository.shared.conversations.first(where: { $0.id == cid }) : nil
        if conv == nil { conv = ConversationsDiskCache.shared.load(uid: me).first(where: { $0.id == cid }) }
        return conv?.acceptedVia != "pin"
    }

    /// 1:1 audit r2 G4: swap the provider config only when something in it changes.
    private func applyConfig(ringtone: String?, peerUid: String?) {
        let recents = Self.showsInRecents(peerUid: peerUid)
        let current = provider.configuration
        guard current.ringtoneSound != ringtone || current.includesCallsInRecents != recents else { return }
        provider.configuration = Self.makeConfig(ringtone: ringtone, inRecents: recents)
    }

    private override init() {
        provider = CXProvider(configuration: Self.makeConfig(
            ringtone: NotificationSound.defaultRingtone.bundleFile,
            inRecents: UserDefaults.standard.object(forKey: Self.showInRecentsKey) as? Bool ?? true))
        super.init()
        provider.setDelegate(self, queue: nil)
        // WebRTC must not touch the audio session itself under CallKit.
        RTCAudioSession.sharedInstance().useManualAudio = true
        RTCAudioSession.sharedInstance().isAudioEnabled = false
        // 1:1 audit #17 (owner, 2026-10-08): this runs at launch, so the call engine is built here
        // off the main thread instead of on the first ring or dial.
        CallService.warmUpEngine()
        // 1:1 audit #37: a screen share started from Control Center during a live call is taken
        // over by the call. Deferred a turn so this init never touches CallService.shared while one
        // of the two singletons is still being created.
        DispatchQueue.main.async { CallService.shared.installShareAdoption() }
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
        applyConfig(ringtone: file, peerUid: callerUid)   // 1:1 audit r2 G4: Recents with it
    }

    // MARK: - Outgoing
    /// `peerUid`: decides Recents (1:1 audit r2 G4). `onRefused`: iOS refused the start; the dial
    /// that asked ends as failed (1:1 audit r2 B3), never a newer one.
    @discardableResult
    func startOutgoing(name: String, video: Bool = false, peerUid: String? = nil,
                       onRefused: (() -> Void)? = nil) -> UUID {
        let uuid = UUID()
        activeUUID = uuid
        activeCallId = nil
        applyConfig(ringtone: provider.configuration.ringtoneSound, peerUid: peerUid)   // r2 G4
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
            DispatchQueue.main.async {
                // Audit M-003, 2026-10-07: let go of the handles too. They were cleared only by the
                // CXEndCallAction delegate callback, which never runs for a call iOS refused to
                // start, so `activeUUID` stayed set and every later 1:1 ring took the "a different
                // call is live" branch: transient report, ended at once, never rang.
                let me = CallKitManager.shared
                // 1:1 audit r2 B3, 2026-10-08: only this start's own call is let go of and ended,
                // and it ends as "Call failed" (the dial's own handler), as the reference app's
                // failed-call path. A late refusal for an older dial no longer ends the new one.
                guard me.activeUUID == uuid else { return }
                me.activeUUID = nil; me.activeCallId = nil
                if let onRefused { onRefused() } else { CallService.shared.endFromCallKit() }
            }
        }
        return uuid
    }

    /// 1:1 audit r2 G5, 2026-10-08: the pushed ring was reported with a cached name (the push
    /// carries none); the caller's profile name replaces it on the system call screen.
    func updateCallerName(callId: String, name: String) {
        guard let uuid = activeUUID, activeCallId == callId, !name.isEmpty else { return }
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: name)
        provider.reportCall(with: uuid, updated: update)
    }
    func reportConnecting() { if let u = activeUUID { provider.reportOutgoingCall(with: u, startedConnectingAt: nil) } }

    // Keep the SYSTEM call UI (lock screen/dynamic island) mute state in sync with the in-app toggle.
    func setMuted(_ muted: Bool) {
        // 1:1 audit r2 D3, 2026-10-08: never while applying a mute CallKit itself asked for; the
        // echo request queued opposite actions after a double tap and the mic flipped forever.
        guard !applyingSystemMute else { return }
        guard let u = activeUUID else { return }
        controller.request(CXTransaction(action: CXSetMutedCallAction(call: u, muted: muted))) { _ in }
    }
    func reportConnected() {
        guard let u = activeUUID else { return }
        // Audit M-045, 2026-10-07: armed BEFORE the report, since CallKit's automatic unmute follows
        // it. Only for a caller who is muted, and only for a few seconds, so a real unmute tapped
        // on the lock screen later is never the one swallowed.
        // V3 N6, round 2: the CALLER only (`isCaller`, readable since F1's round 2). This also runs
        // on the callee's side, where it swallowed a real unmute tapped within the first 3 s.
        if CallService.shared.isCaller, CallService.shared.isMuted {
            stateLock.lock(); connectUnmuteUntil = Date().addingTimeInterval(3); stateLock.unlock()
        }
        provider.reportOutgoingCall(with: u, connectedAt: nil)
    }

    /// Guards the two values below, which CallKit's delegate may read off the main thread.
    private let stateLock = NSLock()
    /// Audit M-045: until when CallKit's automatic unmute at connect is expected.
    private var connectUnmuteUntil: Date?
    /// Audit M-082, 2026-10-07: the group call's speaker choice, kept here for `didActivate`.
    /// It read `GroupCallService.speakerOn` only when on the main thread and fell back to the
    /// loudspeaker otherwise, so an answered call the user had moved to the earpiece came back on
    /// the loudspeaker at the next session activation. Fed by GroupCallRinging's speaker sink.
    private var groupSpeakerChoice = true

    /// True once, inside the window armed by `reportConnected`.
    private func takeConnectUnmute() -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        guard let until = connectUnmuteUntil else { return false }
        connectUnmuteUntil = nil
        return Date() < until
    }

    func noteGroupSpeaker(_ on: Bool) {
        stateLock.lock(); groupSpeakerChoice = on; stateLock.unlock()
    }
    private var groupSpeaker: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return groupSpeakerChoice
    }

    // MARK: - Incoming (idempotent per callId so two paths can't make two UUIDs)
    /// `callerUid` is only used to find the per-chat Call Sound. The ringtone has to be set on the
    /// PROVIDER before the call is reported — there is no per-call ringtone property — so the config
    /// is swapped here, right before reporting.
    ///
    /// `fromPush`: this report answers a VoIP push. Audit M-001, 2026-10-07: the same-call early
    /// return below used to run for pushes too. With the app open the Firestore listener rings a
    /// call first, and the VoIP push for that same call lands seconds later; it was completed with
    /// NOTHING reported. The PushKit contract is per PUSH, not per call: every missed report counts
    /// against the app, and enough of them get it killed and its VoIP pushes throttled ("sometimes
    /// it doesn't ring, sometimes late"). A push for a call already reported now reports a
    /// transient call and ends it at once (`reportAndDiscard`); the listener keeps the silent return.
    func reportIncoming(callId: String, name: String, video: Bool = false,
                        callerUid: String? = nil, fromPush: Bool = false, completion: (() -> Void)? = nil) {
        if activeCallId == callId, activeUUID != nil {
            if fromPush { reportAndDiscard { completion?() } } else { completion?() }
            return
        }
        applyRingtone(callerUid: callerUid)
        // A DIFFERENT call is already live/ringing: iOS requires reporting something for a VoIP
        // push, but this second caller must NOT steal activeUUID (End would then target the wrong
        // system call). Report a transient call and end it immediately (busy).
        // Audit M-047, 2026-10-07: a live, joining or waiting GROUP call is busy here too. It holds
        // no `activeUUID`, so a 1:1 push during a group call took the branch below and showed a REAL
        // ringing CallKit call until CallService ended it on the next run-loop turn.
        // Not when CallService itself took this very call as ringing (its own group check is
        // narrower until it also counts the approval wait): a transient report then would leave it
        // ringing on the caller's side with no system call here, so it rings as before.
        let serviceRingsThis = CallService.shared.callId == callId && CallService.shared.state == .incoming
        if activeUUID != nil || (groupCallBusy && !serviceRingsThis) {
            let uuid = UUID()
            let update = CXCallUpdate()
            update.remoteHandle = CXHandle(type: .generic, value: name)
            update.hasVideo = video
            Self.limitControls(update)
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
        Self.limitControls(update)
        provider.reportNewIncomingCall(with: uuid, update: update) { [weak self] error in
            // If iOS REFUSES to report it (its own block list, a Focus filter), there is no ring and
            // no system call — but activeUUID/activeCallId were left pointing at it, so the app sat
            // in .incoming with no UI and End could not clear it until the caller's 45s timeout
            // (audit). Release the handles and tear our side down.
            // Audit M-044, 2026-10-07: only when the refused report is STILL the current call. The
            // teardown used to sit outside that check and ended whatever call was current by then
            // (a later call that had taken over). And it ends as MISSED, not as the user's decline:
            // nobody tapped anything, iOS refused to ring.
            if error != nil {
                DispatchQueue.main.async {
                    guard self?.activeUUID == uuid else { return }
                    self?.activeUUID = nil; self?.activeCallId = nil
                    // 1:1 audit r2 A2, 2026-10-08: a refusal on THIS phone ends the ring here only.
                    // It wrote `ended` onto the shared doc and killed the ring on my other devices;
                    // the reference app marks only the refusing device's call.
                    CallService.shared.endRingLocally(callId: callId,
                                                      kitError: (error as NSError?)?.code)
                }
            } else {
                // Owner, 2026-10-10: the ring is up; the caller may now hear "Ringing...".
                DispatchQueue.main.async { CallService.shared.ringShown(callId: callId) }
            }
            completion?()
        }
    }

    /// Audit M-047, 2026-10-07: a group call this phone is in, joining, or waiting to be let into.
    /// GroupCallService is main-actor state; CallKit and PushKit both deliver on the main queue
    /// here, and anywhere else this answers "not busy", which is the old behaviour.
    private var groupCallBusy: Bool {
        guard Thread.isMainThread else { return false }
        return MainActor.assumeIsolated {
            let g = GroupCallService.shared
            return g.isActive || g.connecting || g.waitingForApproval
        }
    }

    /// Audit M-115, 2026-10-07: the system call screen offered a keypad and call merging, and
    /// nothing here handles either. Every update we report says so.
    private static func limitControls(_ update: CXCallUpdate) {
        update.supportsDTMF = false
        update.supportsGrouping = false
        update.supportsUngrouping = false
        // 1:1 audit #5 (owner, 2026-10-08): no hold, as in the reference app. Unhold relies on
        // CallKit re-activating the session, which fails when calls are swapped on the system
        // screen and leaves the call silent. iOS then offers "End & Accept" for a phone call.
        update.supportsHolding = false
    }

    /// 2026-09-24 audit: a VoIP push that names no call. iOS still requires a report for every VoIP
    /// push (or it kills the app and stops delivering them), so report a transient call and end it
    /// at once, the same way the busy branch above does, without touching any call state.
    func reportAndDiscard(completion: @escaping () -> Void) {
        let uuid = UUID()
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: "Call")
        Self.limitControls(update)
        provider.reportNewIncomingCall(with: uuid, update: update) { [provider] _ in
            provider.reportCall(with: uuid, endedAt: nil, reason: .failed)
            completion()
        }
    }

    /// Audit M-004, 2026-10-07: the caller hung up before an answer and the server sent a cancel
    /// push. A ring started by a push could only be stopped by a Firestore listener or a timer in
    /// a process iOS may suspend seconds after the push, so a locked phone kept ringing into a dead
    /// call. Stops the system ring for that call only, if it is still ringing unanswered here.
    /// CallService's own ring watcher then reads the ended doc and finishes its side as before
    /// (its `reportEnded` finds nothing left to end). True if a ring was stopped.
    @discardableResult
    ///
    /// Round 2, 2026-10-07: `endReason` is the server's reason from the cancel push (F6: "busy",
    /// "declined", "hangup" or "timeout"). V3 N2: a ring settled on my OTHER phone (busy there, or
    /// declined there) is not a missed call, so iOS is told answered / declined elsewhere for
    /// Recents; a caller who gave up or rang out stays unanswered.
    func endCancelledRing(callId: String, endReason: String? = nil) -> Bool {
        guard activeUUID != nil, activeCallId == callId else { return false }
        let service = CallService.shared
        // V3 N5, round 2: not a call this phone already accepted. On the slow answer path the
        // state can still read `.incoming` for a moment after the tap; ending the system call
        // then would pull it out from under the answer.
        guard service.callId == callId, service.state == .incoming, !service.wasAccepted else { return false }
        switch endReason {
        // 1:1 audit r2 C2/A1, 2026-10-08: busy or declined on my other device is declined
        // elsewhere (the reference app); answered there (cancel push on `acceptedAt`) is answered.
        case "declined", "busy": reportEnded(.declinedElsewhere)
        case "answered":         reportEnded(.answeredElsewhere)
        default:         reportEnded(.unanswered)   // what CallService itself tells iOS for a cancelled ring
        }
        return true
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
        Self.limitControls(update)
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
        controller.request(CXTransaction(action: CXEndCallAction(call: uuid))) { [provider] error in
            // Same reasoning as the nil-UUID branch above: if the end action itself fails, the End
            // button silently did nothing. Fall back to tearing our side down directly.
            guard error != nil else { return }
            DispatchQueue.main.async {
                // Audit M-003, 2026-10-07: the failed action never reaches the CXEndCallAction
                // handler, the one place the handles were cleared, so the phone treated every later
                // 1:1 ring as busy. Close the system call ourselves and let go of it.
                let me = CallKitManager.shared
                if me.activeUUID == uuid {
                    provider.reportCall(with: uuid, endedAt: nil, reason: .failed)
                    me.activeUUID = nil; me.activeCallId = nil
                }
                CallService.shared.endFromCallKit()
            }
        }
    }
    /// Why a call ended without a user action here. iOS uses the reason for Recents: a ring answered
    /// on my other phone must not log as missed, and a ring nobody picked up is "unanswered", not
    /// "remote ended" (owner audit 2026-10-06 #20; the reference app reports each reason).
    /// `declinedElsewhere`: round 2 (V3 N2), a ring declined on my other phone, from a cancel push.
    enum EndKind { case remote, unanswered, answeredElsewhere, declinedElsewhere, failed }

    /// Remote hung up / call failed — clear the system UI without a user action.
    func reportEnded(_ kind: EndKind = .remote) {
        let reason: CXCallEndedReason
        switch kind {
        case .remote:            reason = .remoteEnded
        case .unanswered:        reason = .unanswered
        case .answeredElsewhere: reason = .answeredElsewhere
        case .declinedElsewhere: reason = .declinedElsewhere
        case .failed:            reason = .failed
        }
        if let uuid = activeUUID { provider.reportCall(with: uuid, endedAt: nil, reason: reason) }
        activeUUID = nil; activeCallId = nil
    }

    /// 1:1 audit r3 B3, 2026-10-08: an end this phone decided (sign-out, glare, move to group) goes to
    /// iOS as a local End action, not "remote ended". The handles are let go first, so the End action
    /// finds no live call and is only acknowledged (the service has already torn down).
    func endFromHere() {
        guard let uuid = activeUUID else { return }
        activeUUID = nil; activeCallId = nil
        controller.request(CXTransaction(action: CXEndCallAction(call: uuid))) { [provider] error in
            guard error != nil else { return }
            DispatchQueue.main.async { provider.reportCall(with: uuid, endedAt: nil, reason: .remoteEnded) }
        }
    }

    /// 1:1 audit r2 D3: true while a CallKit mute action is being applied (main queue only). In the
    /// class body: an extension cannot hold stored properties.
    private var applyingSystemMute = false
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
        // Audit M-003, 2026-10-07: every system call is gone after a reset, ours included. The
        // handles were left set, so the phone stayed "busy" for every later 1:1 ring. Cleared AFTER
        // hangUp, so its delayed end (which compares against the UUID it saw) still matches only
        // this call and can never end a new one that rings inside the tone window.
        activeUUID = nil; activeCallId = nil
    }

    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        configureAudio()
        action.fulfill()
        provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: nil)
        // Audit M-115, 2026-10-07: an outgoing call has no CXCallUpdate of its own, so the keypad
        // and merge buttons are switched off here.
        let update = CXCallUpdate()
        Self.limitControls(update)
        provider.reportCall(with: action.callUUID, updated: update)
    }

    // Audit M-115, 2026-10-07: never offered (see `limitControls`); answered so nothing waits on them.
    func provider(_ provider: CXProvider, perform action: CXPlayDTMFCallAction) { action.fulfill() }
    func provider(_ provider: CXProvider, perform action: CXSetGroupCallAction) { action.fulfill() }

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        // owner, 2026-10-06: a group ring answered in CallKit. Audio per the SDK's CallKit recipe,
        // set up BEFORE the room connects; the join itself runs on the main actor.
        if let group = groupUUID, group == action.callUUID {
            // Audit M-153, 2026-10-07: the same room is already joining (or up) inside the app,
            // from its Join bar or invitation while CallKit still rang. A second join was started
            // under it, refused because one was connecting, and then "the join never became a
            // call" ended the CallKit call and put the audio defaults back under the live join.
            // Now the ring just ends as answered elsewhere, and the audio is never switched over.
            if Thread.isMainThread,
               MainActor.assumeIsolated({ GroupCallRinging.shared.answerFindsRoomJoining(uuid: group) }) {
                action.fulfill()
                return
            }
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
        // Audit M-116, 2026-10-07: an answer for a call that is not ours (a transient busy report
        // answered in the instant it shows) used to answer whatever 1:1 call was current.
        guard let live = activeUUID, live == action.callUUID else { action.fail(); return }
        configureAudio()
        // 1:1 audit #23 (owner, 2026-10-08): the service has no call left to answer (it ended in
        // the tone window, or never had one). Fulfilling left a "connected" system call with
        // nothing behind it, so the action fails and the system call is closed.
        guard CallService.shared.answer() else {
            action.fail()
            reportEnded(.failed)
            return
        }
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
        // Audit M-116, 2026-10-07: and with no call of ours at all, an unknown UUID no longer ends
        // whatever 1:1 call is current; it is acknowledged and nothing else happens.
        guard let live = activeUUID, live == action.callUUID else { action.fulfill(); return }
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
                if service.isActive {
                    if service.micOn == muted { service.toggleMic() }
                } else {
                    // Audit M-083, 2026-10-07: still joining. This was dropped, yet fulfilled, so
                    // the system screen said muted while the join then opened the mic.
                    GroupCallRinging.shared.callKitMuteBeforeJoin(uuid: group, muted: muted)
                }
            }
            action.fulfill()
            return
        }
        // Audit M-116, 2026-10-07: not our call (or no call of ours): refused, never applied to
        // whatever call is current.
        guard let live = activeUUID, live == action.callUUID else { action.fail(); return }
        // Audit M-045, 2026-10-07: CallKit turns the mic back on by itself when an outgoing call
        // connects. A caller who muted during "Calling..." had their mic opened with no tap. That
        // one automatic unmute is acknowledged, not applied, and the system screen is put back.
        if !action.isMuted, CallService.shared.isMuted, takeConnectUnmute() {
            action.fulfill()
            setMuted(true)
            return
        }
        // 1:1 audit r2 D3, 2026-10-08: SET to the action's value, as the reference app does, and
        // without requesting another CallKit action (the toggle's own request is suppressed).
        if CallService.shared.isMuted != action.isMuted {
            applyingSystemMute = true
            CallService.shared.toggleMute()
            applyingSystemMute = false
        }
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
        // Audit M-116, 2026-10-07: not our call (or no call of ours): refused, never applied.
        guard let live = activeUUID, live == action.callUUID else { action.fail(); return }
        CallService.shared.setHeld(action.isOnHold)
        action.fulfill()
    }

    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        // owner, 2026-10-06: a group call answered through CallKit. The LiveKit engine may start
        // only now; the 1:1 engine below is not touched.
        if groupAudioUnderCallKit {
            groupAudioSessionLive = true
            // Audit M-082, 2026-10-07: the copy kept by `noteGroupSpeaker`, on whatever thread
            // CallKit calls from (group calls start on the speaker; see GroupCallRinging).
            GroupCallKitAudio.activated(audioSession, speaker: groupSpeaker)
            return
        }
        groupAudioSessionLive = false
        let s = RTCAudioSession.sharedInstance()
        s.lockForConfiguration()
        // .videoChat on the loudspeaker: VPIO echo cancellation TUNED FOR LOUDSPEAKER (the echo-
        // on-speaker fix big apps use); .voiceChat (earpiece-tuned) otherwise. Bluetooth allowed.
        // 1:1 audit #2 (owner, 2026-10-08): chosen by the speaker choice, not the camera. .videoChat
        // routes to the loudspeaker by itself, so a video call moved to the earpiece came back on
        // the speaker at every activation. Same rule as updateAudioRoute, one mode writer.
        try? s.setCategory(.playAndRecord,
                           mode: CallService.shared.isSpeaker ? .videoChat : .voiceChat,
                           options: [.allowBluetooth, .allowBluetoothA2DP])
        s.audioSessionDidActivate(audioSession)
        // 1:1 audit #26 (owner, 2026-10-08): the WebRTC audio unit (and the mic indicator) stays
        // off while the caller's call only rings; CallService turns it on at the accept. The
        // callee and every re-activation turn it on here as before.
        s.isAudioEnabled = CallService.shared.callAudioUnitMayStart
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
        CallService.shared.audioSessionDeactivated()   // 1:1 audit r2 C5 (K1), 2026-10-08
    }

    /// 1:1 audit #24 (owner, 2026-10-08): iOS gave up waiting on an action. CallKit's automatic
    /// unmute of a call that already ended times out even when answered (known since iOS 13), so
    /// that one is ignored, as the reference app does. Anything else is logged; iOS has already
    /// treated the action as failed.
    func provider(_ provider: CXProvider, timedOutPerforming action: CXAction) {
        if action is CXSetMutedCallAction { return }
        print("[Call] CallKit timed out performing \(type(of: action))")
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
        // 1:1 audit #2 (owner, 2026-10-08): mode by the speaker choice, as in didActivate.
        try? s.setCategory(.playAndRecord,
                           mode: CallService.shared.isSpeaker ? .videoChat : .voiceChat,
                           options: [.allowBluetooth, .allowBluetoothA2DP])
        s.unlockForConfiguration()
    }
}
