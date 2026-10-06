import Foundation
import AVFoundation
import CallKit
import Combine
import LiveKit
import FirebaseAuth
import FirebaseFirestore
import FirebaseFunctions

/// owner, 2026-10-06: an invitation to a multi-person call, and the start of a group-chat call,
/// ring like a real call (CallKit, lock screen too). This is the one place that knows about a
/// ring in progress: which room, which CallKit call, and when it must stop.
///
/// The ring is brought by a VoIP push (`kind == "groupring"`, sent by functions-groups). iOS kills
/// an app that takes a VoIP push without reporting a call, so `handlePush` reports one on every
/// path, with no wait before it, and ends at once the ones that must not ring.
///
/// A ring ends when: it is answered or declined (CallKit or the in-app invitation, either one
/// settles both), the call is no longer active, I answered or declined on my other device, I am
/// no longer on the list, a 1:1 call takes over, or 60s have passed. Finished rings are kept for
/// 30 minutes so a late push for the same room never rings.
@MainActor
final class GroupCallRinging {
    static let shared = GroupCallRinging()
    private init() {}

    private struct Ring {
        let roomKind: String     // "adhoc" (multi-person) or "group" (a group chat's call)
        let roomId: String       // the adhoc_… id, or the group's cid
        let callTitle: String    // the group's title, for `start(cid:title:video:)`
        let video: Bool
        let uuid: UUID           // the CallKit call
    }
    /// ringing: CallKit is ringing. joining: answered through CallKit, the room is coming up.
    /// inCall: the room is up; the CallKit call stays for the whole call.
    private enum Phase { case ringing, joining, inCall }

    private var ring: Ring?
    private var phase: Phase = .ringing
    private var listener: ListenerRegistration?
    private var timeoutTask: Task<Void, Never>?
    private var watch: Set<AnyCancellable> = []
    /// Rooms declined on this phone in this run. The in-app invitation reads it, because its own
    /// list may load only after a decline made on the lock screen.
    private var declinedHere: Set<String> = []
    private var busySent: [String: Date] = [:]

    /// The ring's length, the service's own number (60s).
    private static var ringWindow: TimeInterval { TimeInterval(GroupCallService.ringWindow) }
    private static let memoryKey = "groupRing.finished"
    private static let memoryAge: TimeInterval = 30 * 60

    // MARK: - The VoIP push

    /// Called from PushKit on the main thread. Every path below reports a call to CallKit, and
    /// `completion` runs from CallKit's own answer to that report.
    func handlePush(_ d: [AnyHashable: Any], completion: @escaping () -> Void) {
        let kind = d["roomKind"] as? String ?? ""
        let roomId = d["roomId"] as? String ?? ""
        let adhocId = roomId.hasPrefix("adhoc_")
        guard !roomId.isEmpty, !roomId.contains("/"),
              (kind == "adhoc" && adhocId) || (kind == "group" && !adhocId) else {
            CallKitManager.shared.reportAndDiscard(completion: completion)
            return
        }
        let sentAt = (d["sentAt"] as? NSNumber).map { $0.doubleValue / 1000 }   // seconds
        let callerUid = d["callerUid"] as? String ?? ""
        let service = GroupCallService.shared
        let now = Date().timeIntervalSince1970
        // Not a ring, and nobody is told anything: the call I am already in, joining or answered,
        // or the person I am in a 1:1 with carrying both of us into this room (`ringIsMine`); the
        // same push twice; a push older than the ring window; a ring already finished here; or
        // nobody signed in.
        if service.ringIsMine(roomId: roomId, callerUid: callerUid)
            || ring?.roomId == roomId || service.activeCid == roomId
            || (sentAt.map { now - $0 > Self.ringWindow } ?? false)
            || wasFinished(roomId, adhoc: adhocId, sentAt: sentAt)
            || Auth.auth().currentUser == nil {
            CallKitManager.shared.reportAndDiscard(completion: completion)
            return
        }
        // In another call, or another ring is up: this one does not ring, and the caller is told.
        if ring != nil || CallService.shared.state != .idle
            || service.isActive || service.connecting || service.waitingForApproval {
            CallKitManager.shared.reportAndDiscard(completion: completion)
            reportBusy(roomKind: kind, roomId: roomId)
            return
        }
        let callerName = (d["callerName"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Call"
        let title = (d["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let video = d["video"] as? Bool ?? false
        let r = Ring(roomKind: kind, roomId: roomId, callTitle: title ?? callerName, video: video, uuid: UUID())
        ring = r
        phase = .ringing
        // The caller's name; for a group chat's call, the group's title.
        CallKitManager.shared.reportGroupRing(uuid: r.uuid, name: kind == "group" ? (title ?? callerName) : callerName,
                                              video: video, completion: completion)
        watchRoom(r, until: sentAt.map { $0 + Self.ringWindow })
    }

    /// iOS refused to show the ring (Focus, its own block list): there is no CallKit call.
    func ringRefused(uuid: UUID) {
        guard let r = ring, r.uuid == uuid, phase == .ringing else { return }
        stopWatchingRoom()
        ring = nil
    }

    // MARK: - While it rings

    /// Follows the call's document for as long as the ring is up. Only the SERVER's copy can end a
    /// ring: a cached copy may be an older call in the same group.
    private func watchRoom(_ r: Ring, until deadline: TimeInterval?) {
        stopWatchingRoom()
        let uuid = r.uuid
        let me = Auth.auth().currentUser?.uid ?? ""
        listener = Firestore.firestore().collection("groupCalls").document(r.roomId)
            .addSnapshotListener(includeMetadataChanges: true) { [weak self] snap, error in
                let failed = error != nil
                let cached = snap?.metadata.isFromCache ?? true
                let exists = snap?.exists ?? false
                let active = snap?.get("active") as? Bool ?? false
                let members = snap?.get("members") as? [String] ?? []
                let joined = snap?.get("joined") as? [String] ?? []
                let declined = snap?.get("declined") as? [String] ?? []
                let startedBy = snap?.get("startedBy") as? String ?? ""
                Task { @MainActor [weak self] in
                    guard let self, let r = self.ring, r.uuid == uuid, self.phase == .ringing else { return }
                    // Refused by the rules: off the list, or signed out. The room check failed.
                    if failed { self.finishRing(.failed); return }
                    if cached { return }
                    if !exists || !active {
                        self.finishRing(.remoteEnded)
                    } else if r.roomKind == "adhoc" && !members.contains(me) {
                        self.finishRing(.remoteEnded)
                    } else if joined.contains(me) || startedBy == me {
                        self.finishRing(.answeredElsewhere)
                    } else if declined.contains(me) {
                        self.finishRing(.declinedElsewhere)
                    }
                }
            }
        // 60s from when the server sent it; never under 5s or over 60s from now, whatever the
        // two clocks say.
        let left = min(Self.ringWindow, max(5, (deadline ?? .greatestFiniteMagnitude) - Date().timeIntervalSince1970))
        timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(left * 1_000_000_000))
            guard !Task.isCancelled, let self, self.ring?.uuid == uuid, self.phase == .ringing else { return }
            self.finishRing(.unanswered)
        }
    }

    private func stopWatchingRoom() {
        listener?.remove(); listener = nil
        timeoutTask?.cancel(); timeoutTask = nil
    }

    /// The ring is over without an answer on this phone. `settleInvite` also takes the in-app
    /// invitation for the same room down, so nothing is left ringing.
    private func finishRing(_ reason: CXCallEndedReason, settleInvite: Bool = true) {
        guard let r = ring, phase == .ringing else { return }
        stopWatchingRoom()
        ring = nil
        remember(r.roomId)
        CallKitManager.shared.endGroupCall(uuid: r.uuid, reason: reason)
        let service = GroupCallService.shared
        if settleInvite, service.incomingInvite?.roomId == r.roomId { service.declineInvite() }
    }

    /// A 1:1 call is ringing or starting on this phone. One ring at a time: the group ring stops.
    /// The in-app invitation follows its own rule (hidden during a 1:1, back afterwards).
    func oneToOneTookOver() {
        finishRing(.unanswered, settleInvite: false)
    }

    // MARK: - Answer and decline

    /// Camera on only for a video call AND only when camera access was already given: no
    /// permission pop-up stands between the ring and the answer.
    static func joinsWithVideo(_ video: Bool) -> Bool {
        video && AVCaptureDevice.authorizationStatus(for: .video) == .authorized
    }

    /// Answer tapped in CallKit (lock screen or banner). The CallKit call stays up for the whole
    /// group call; CallKitManager has already put the audio under CallKit.
    /// False = that ring is no longer up here: the caller ends the CallKit call and puts the
    /// audio defaults back.
    func answeredFromCallKit(uuid: UUID) -> Bool {
        guard let r = ring, r.uuid == uuid, phase == .ringing else { return false }
        stopWatchingRoom()
        remember(r.roomId)
        phase = .joining
        watchService()
        let video = Self.joinsWithVideo(r.video)
        Task { @MainActor in
            let service = GroupCallService.shared
            if r.roomKind == "adhoc" {
                await service.joinAdhoc(roomId: r.roomId, video: video)
            } else {
                // A group chat's call has no screen of its own outside the chat; the root layer
                // shows it, as it does for multi-person calls.
                service.presentsRoomScreen = true
                await service.start(cid: r.roomId, title: r.callTitle, video: video)
            }
            guard self.ring?.uuid == r.uuid else { return }   // ended meanwhile
            if service.activeCid == r.roomId {
                self.callJoined()
            } else {
                self.endCallKitCall(.failed)   // the join never became a call
            }
        }
        return true
    }

    /// End tapped in CallKit: a decline while it rings, a hang-up once answered. CallKitManager
    /// has already let go of the CallKit call and its audio.
    func endedFromCallKit(uuid: UUID) {
        guard let r = ring, r.uuid == uuid else { return }
        if phase == .ringing {
            stopWatchingRoom()
            ring = nil
            settleDecline(roomKind: r.roomKind, roomId: r.roomId)
        } else {
            ring = nil
            phase = .ringing
            watch.removeAll()
            GroupCallService.shared.end()
        }
    }

    /// CallKit dropped every call (its daemon restarted).
    func providerReset() {
        guard let r = ring else { return }
        stopWatchingRoom()
        watch.removeAll()
        let wasRinging = phase == .ringing
        ring = nil
        phase = .ringing
        remember(r.roomId)
        if !wasRinging { GroupCallService.shared.end() }
    }

    /// Decline on the in-app invitation: the CallKit ring for the same room stops too.
    func declineFromScreen(_ invite: AdhocInvite) {
        if let r = ring, r.roomId == invite.roomId, phase == .ringing {
            stopWatchingRoom()
            ring = nil
            CallKitManager.shared.endGroupCall(uuid: r.uuid, reason: .declinedElsewhere)
        }
        settleDecline(roomKind: "adhoc", roomId: invite.roomId)
    }

    /// Join on the in-app invitation. The CallKit ring for the same room stops, and the call runs
    /// as every call joined inside the app does (no CallKit call, the SDK's own audio handling).
    func acceptFromScreen(_ invite: AdhocInvite) {
        if let r = ring, r.roomId == invite.roomId, phase == .ringing {
            stopWatchingRoom()
            ring = nil
            CallKitManager.shared.endGroupCall(uuid: r.uuid, reason: .answeredElsewhere)
        }
        remember(invite.roomId)
        let service = GroupCallService.shared
        if service.incomingInvite?.roomId == invite.roomId {
            service.acceptInvite()   // applies the same camera rule
        } else {
            let video = Self.joinsWithVideo(invite.video)
            Task { @MainActor in await service.joinAdhoc(roomId: invite.roomId, video: video) }
        }
    }

    /// True for a room declined on this phone: the in-app invitation must not come up for it.
    func isDeclined(_ roomId: String) -> Bool { declinedHere.contains(roomId) }

    private func settleDecline(roomKind: String, roomId: String) {
        declinedHere.insert(roomId)
        remember(roomId)
        let service = GroupCallService.shared
        if service.incomingInvite?.roomId == roomId { service.declineInvite() }
        sendAnswer("declined", roomKind: roomKind, roomId: roomId, tries: 3)
    }

    // MARK: - Called by GroupCallService

    /// My group call is up (any kind, also one started inside the app: then there is nothing
    /// to do here unless a ring is still up, which stops).
    func callJoined() {
        guard let r = ring else { return }
        if phase == .ringing {
            // Joined from inside the app (the chat's Join bar) while CallKit was still ringing.
            finishRing(GroupCallService.shared.activeCid == r.roomId ? .answeredElsewhere : .unanswered)
            return
        }
        guard phase == .joining else { return }
        phase = .inCall
        CallKitManager.shared.updateGroupVideo(GroupCallService.shared.cameraOn, uuid: r.uuid)
    }

    /// My group call is over (hung up, dropped, removed). Ends the CallKit call kept for it and
    /// puts the audio defaults back. Safe to call any number of times, with no ring and no CallKit
    /// call: the service calls it from its state reset, which also runs for a join that never
    /// became a call. That case is settled by `answeredFromCallKit` when the join returns, so a
    /// reset made on the way INTO a call cannot end the CallKit call under it.
    func callEnded() {
        guard ring != nil, phase == .inCall else { return }
        endCallKitCall(.remoteEnded)
    }

    /// Rung while already in a call: tells the caller this person is busy. Once per room for
    /// longer than any ring or invitation lasts (the service may ask many times for one room).
    func reportBusy(roomKind: String, roomId: String) {
        let now = Date()
        if let last = busySent[roomId], now.timeIntervalSince(last) < 180 { return }
        busySent = busySent.filter { now.timeIntervalSince($0.value) < 180 }
        busySent[roomId] = now
        sendAnswer("busy", roomKind: roomKind, roomId: roomId, tries: 1)
    }

    private func endCallKitCall(_ reason: CXCallEndedReason) {
        guard let r = ring, phase != .ringing else { return }
        ring = nil
        phase = .ringing
        watch.removeAll()
        CallKitManager.shared.endGroupCall(uuid: r.uuid, reason: reason)
    }

    /// While a CallKit-answered call is up: its end, and the mic and speaker buttons, kept in
    /// step with the system call screen. `@Published` fires before the value is stored, so each
    /// sink uses the value it is handed.
    private func watchService() {
        watch.removeAll()
        let service = GroupCallService.shared
        service.$activeCid.dropFirst().sink { cid in
            guard cid == nil else { return }
            Task { @MainActor in
                GroupCallRinging.shared.callEnded()
            }
        }.store(in: &watch)
        service.$micOn.dropFirst().removeDuplicates().sink { on in
            Task { @MainActor in CallKitManager.shared.setGroupMuted(!on) }
        }.store(in: &watch)
        service.$speakerOn.dropFirst().removeDuplicates().sink { on in
            Task { @MainActor in CallKitManager.shared.applyGroupSpeaker(on) }
        }.store(in: &watch)
    }

    // MARK: - Telling the server

    /// `groupRingAnswer` (functions-groups, me-central1). A decline made offline is tried again a
    /// few times; whatever happens, this phone has already stopped ringing.
    private func sendAnswer(_ answer: String, roomKind: String, roomId: String, tries: Int) {
        guard Auth.auth().currentUser != nil else { return }
        Task { @MainActor in
            for attempt in 0..<max(1, tries) {
                do {
                    _ = try await Functions.functions(region: "me-central1").httpsCallable("groupRingAnswer")
                        .call(["roomKind": roomKind, "roomId": roomId, "answer": answer])
                    return
                } catch {
                    if attempt + 1 >= tries { return }
                    try? await Task.sleep(nanoseconds: UInt64(attempt + 1) * 4_000_000_000)
                }
            }
        }
    }

    // MARK: - The 30-minute memory of finished rings

    private func finishedRings() -> [String: Double] {
        let all = UserDefaults.standard.dictionary(forKey: Self.memoryKey) as? [String: Double] ?? [:]
        let now = Date().timeIntervalSince1970
        return all.filter { now - $0.value < Self.memoryAge }
    }

    private func remember(_ roomId: String) {
        var all = finishedRings()
        all[roomId] = Date().timeIntervalSince1970
        UserDefaults.standard.set(all, forKey: Self.memoryKey)
    }

    /// A multi-person room has a new id for every call, so its id alone decides. A group chat's
    /// room is the chat itself: only a push sent before that ring finished is the same ring.
    private func wasFinished(_ roomId: String, adhoc: Bool, sentAt: TimeInterval?) -> Bool {
        guard let at = finishedRings()[roomId] else { return false }
        if adhoc { return true }
        guard let sentAt else { return true }
        return sentAt <= at
    }
}

/// The LiveKit SDK's own CallKit recipe (its README, "Integration with CallKit"), used ONLY for a
/// group call answered through CallKit: the SDK stops configuring the audio session itself, and
/// its audio engine may run only between CallKit's didActivate and didDeactivate. A group call
/// started or joined inside the app never comes here and keeps the SDK's defaults.
/// Not actor-bound: CallKit's delegate calls these.
enum GroupCallKitAudio {
    /// Before connecting to the room.
    static func prepare() {
        AudioManager.shared.audioSession.isAutomaticConfigurationEnabled = false
        try? AudioManager.shared.setEngineAvailability(.none)
    }

    static func activated(_ session: AVAudioSession, speaker: Bool) {
        try? session.setCategory(.playAndRecord, mode: speaker ? .videoChat : .voiceChat,
                                 options: [.mixWithOthers, .allowBluetooth, .allowBluetoothA2DP])
        try? AudioManager.shared.setEngineAvailability(.default)
        route(speaker: speaker)
    }

    static func deactivated() {
        try? AudioManager.shared.setEngineAvailability(.none)
    }

    /// With automatic configuration off the SDK no longer moves the route, so the call screen's
    /// speaker button is applied here.
    static func route(speaker: Bool) {
        try? AVAudioSession.sharedInstance().overrideOutputAudioPort(speaker ? .speaker : .none)
    }

    /// The call is over: back to what every in-app group call expects.
    static func restoreDefaults() {
        try? AudioManager.shared.setEngineAvailability(.default)
        AudioManager.shared.audioSession.isAutomaticConfigurationEnabled = true
    }
}
