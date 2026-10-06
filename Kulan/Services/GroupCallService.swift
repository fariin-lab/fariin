import Foundation
import UIKit
import LiveKit
import AVFoundation
import FirebaseFunctions
import FirebaseFirestore
import FirebaseAuth

/// One person in a multi-person call: everyone invited, joined or not.
struct CallMember: Identifiable, Hashable {
    let uid: String
    let name: String
    let photoUrl: String?
    var id: String { uid }
}

/// Which kind of room the group call is. A group conversation's room, a multi-person call started
/// from a 1:1 ("adhoc_…", its own `groupCalls` doc), or a call link (`callLinks/{roomId}`).
enum GroupRoom: Equatable {
    case group(cid: String)
    case adhoc(id: String)
    case link(roomId: String, key: String)
}

/// Who someone is in a call, as the SERVER decided it (group call permissions, 2026-10-06): the
/// join token's LiveKit attribute `role`, or the `role` in the `groupCallToken` answer for me. The
/// phone only uses it to choose which buttons to show; `callAdmin` checks every action itself.
enum CallRole: String {
    case owner, moderator, participant

    /// Anything missing or unknown reads as a plain participant: the least power, never more.
    init(attribute: String?) {
        self = attribute.flatMap(CallRole.init(rawValue:)) ?? .participant
    }

    /// The people list's badge.
    var badge: String? {
        switch self {
        case .owner: return "Host"
        case .moderator: return "Admin"
        case .participant: return nil
        }
    }

    /// The access table: the owner may mute or remove anyone else, a moderator only participants,
    /// a participant nobody. Never oneself; the caller checks that by uid.
    func canModerate(_ target: CallRole) -> Bool {
        switch self {
        case .owner: return target != .owner
        case .moderator: return target == .participant
        case .participant: return false
        }
    }
}

/// What `callAdmin` can be asked to do.
enum CallAdminAction: String {
    /// `block` is for call links only (the server refuses it elsewhere): out of the call and refused
    /// by that link for good. A plain `remove` on a link only takes the person out; they may ask again.
    case mute, remove, block, end
}

/// Where I am on the way into a call (owner 2026-10-06, reference study). ONE state for the screens
/// to read, instead of three flags each screen combined its own way: not in anything, the join is
/// running, waiting for the link's creator to say yes, in the call.
enum GroupJoinState: Equatable { case notJoined, joining, pending, joined }

/// A multi-person call I was invited to and have not answered yet. `IncomingGroupCallLayer` shows it.
struct AdhocInvite: Identifiable, Equatable {
    let roomId: String
    let title: String
    let video: Bool
    let startedBy: String
    let startedAt: Date
    let others: [CallMember]   // starter first
    var id: String { roomId }
}

// Group calls run on LiveKit (an SFU) — phones can't mesh more than ~3 people. 1:1 calls stay on
// stasel/WebRTC; LiveKit ships LK-prefixed WebRTC so the two coexist. The join token is minted
// server-side by the `groupCallToken` function (our API secret never touches the app).
@MainActor
final class GroupCallService: ObservableObject {
    static let shared = GroupCallService()
    private init() { room.add(delegate: roomObserver) }

    /// owner audit 2026-10-06 #4: bumped by `end()`. A join in flight (token fetch, room.connect)
    /// carries the value it started with and checks it after every wait; a mismatch means the user
    /// already hung up or closed the screen, so whatever it got up is taken down quietly instead of
    /// turning into a live call with no screen and no card.
    private var joinGeneration = 0
    /// owner audit 2026-10-06 #16: true while `disconnect()` runs, so the room's own "disconnected"
    /// event from OUR hang-up is not mistaken for a dropped room. Read by the call screen's status
    /// banner for the same reason (no "Connection lost" after I hung up).
    private(set) var leaving = false
    /// Held here: the room keeps its delegates weakly.
    private let roomObserver = RoomDropObserver()
    /// owner audit 2026-10-06 #44: a parked link joiner also watches the link itself, so the admin
    /// turning approval off lets them in without answering the old request.
    private var linkDocListener: ListenerRegistration?

    // Public LiveKit server address (not a secret — it's just where the app connects).
    private let url = "wss://kulan-irgnsxba.livekit.cloud"

    // Observe this room in the UI for live participant updates. Dynacast and adaptiveStream both
    // default to FALSE in the SDK, so we were publishing simulcast layers nobody had subscribed to
    // and pulling the top layer into tiles the size of a stamp: the whole uplink budget of a weak
    // phone spent on pixels no one sees. Capture is pinned to 540p rather than the 720p default so
    // the top layer matches its 800kbps preset instead of being a starved 720p, and so published
    // width stays at the SDK's >= 960 cutoff for a three-layer ladder. That ladder is the point:
    // a weak leg drops to 180p instead of the call stalling out.
    let room = Room(roomOptions: RoomOptions(
        defaultCameraCaptureOptions: CameraCaptureOptions(dimensions: .h540_169),
        defaultVideoPublishOptions: VideoPublishOptions(encoding: VideoParameters.presetH540_169.encoding,
                                                        simulcast: true),
        adaptiveStream: true,
        dynacast: true
    ))
    @Published var activeCid: String? {     // nil = no group call in progress
        didSet { syncJoinState() }
    }
    /// See `GroupJoinState`. Derived from `activeCid`, `waitingForApproval` and `connecting`, which
    /// keep their old meanings for the code that reads them.
    @Published private(set) var joinState: GroupJoinState = .notJoined
    private func syncJoinState() {
        let now: GroupJoinState = activeCid != nil ? .joined
            : (waitingForApproval ? .pending : (connecting ? .joining : .notJoined))
        if now != joinState { joinState = now }
    }
    @Published var isVideo = false
    @Published var micOn = true

    /// ⛔ THE SCREEN BEFORE A LINK CALL — owner, 2026-10-06, with a screenshot of the reference
    /// app's: tapping a call link first shows your own camera, the call's name, camera and mic
    /// buttons, and Leave / Join. Set here, shown by `IncomingGroupCallLayer` (`CallLobbyView`).
    struct Lobby: Identifiable, Equatable { let key: String; var id: String { key } }
    @Published var lobby: Lobby? {
        didSet {
            // The lobby went away (Leave, or swiped down) with a join or a knock still running
            // from it: that is leaving, exactly as closing the call screen while connecting is.
            if lobby == nil, oldValue != nil, lobbyJoin, !isActive, connecting || waitingForApproval { end() }
        }
    }
    /// ⛔ THE LOBBY STAYS UP UNTIL I AM IN (owner 2026-10-06, reference study). Join used to close
    /// the lobby at once and put up the call screen on "Connecting…"; with approval on, the wait
    /// happened on that second screen. Now a join started from the lobby (`joinLink(fromLobby: true)`)
    /// keeps the lobby on screen while it runs ("Ask to Join" → "Waiting to be let in"), and the call
    /// screen comes up only once the room is joined. A refusal lands here as a line of text.
    @Published var lobbyError: String?
    private var lobbyJoin = false
    /// The mic as the lobby left it. Read by `connect` (also after an approval wait), cleared with
    /// the room.
    private var startMuted = false
    /// When this phone got into the room. The two-person look's header clock, like a 1:1 call's;
    /// here and not on the screen, which is rebuilt every time the call is restored from its card.
    @Published private(set) var joinedAt: Date?

    /// Opens the pre-join screen for a link. Busy (a call already up or starting) says so instead.
    func openLobby(key: String) {
        guard lobby == nil else { return }
        guard activeCid == nil, !connecting, !waitingForApproval, CallService.shared.state == .idle else {
            Self.presentOverTop(Self.busyNotice)
            return
        }
        guard CallLinkKey(text: key) != nil else { Self.presentOverTop(Self.linkGone); return }
        lobbyError = nil
        lobby = Lobby(key: key)
    }
    @Published var cameraOn = false
    /// A VOICE call link (owner, 2026-10-06): nobody's camera can come on in this room. Set from the
    /// server's join answer; the media server enforces it too (the token can publish the mic only).
    @Published private(set) var cameraLocked = false
    @Published var connecting = false {
        didSet { syncJoinState() }
    }
    @Published var minimized = false        // swiped down → CallContainer shows the return bar
    @Published var callTitle = ""
    /// 2026-09-24 decision D25: why a start did not become a call. GroupCallView shows it as an alert
    /// and closes on OK. Before this a failed start left the call screen up on "1 in call", with
    /// nobody in it and nothing saying why.
    struct Notice: Equatable { let title: String; let message: String? }
    @Published var notice: Notice?

    /// My role in the running call, from the server's join answer (and my own LiveKit attributes if
    /// the server changes it mid-call). Drives which admin controls the people list offers.
    @Published private(set) var myRole: CallRole = .participant
    /// Bumped when anyone's LiveKit attributes change, so views that read roles straight from the
    /// participants (`participant.attributes["role"]`) draw again.
    @Published private(set) var rolesVersion = 0
    /// A short line over the stage that does not close the screen ("You were muted"). Clears itself.
    @Published private(set) var toast: String?
    private var toastTask: Task<Void, Never>?
    /// Mic toggles of mine still in flight: a mute event while one runs is mine, not the server's.
    private var micChangesInFlight = 0
    /// True from my own "End call for everyone" until the room is gone, so the room-deleted event
    /// that follows is not reported back to me as "The call was ended".
    private var endingForAll = false
    /// Link calls: the link made by "Make a new link" during this call, and whether the one being
    /// handed out was revoked. Share and Copy use `currentLink`.
    @Published private(set) var replacedLink: ActiveCallLink?
    @Published private(set) var linkRevoked = false

    var isActive: Bool { activeCid != nil }

    // MARK: Multi-person (ad-hoc) and link calls
    @Published var activeRoom: GroupRoom?            // set with activeCid; nil while no call is up
    @Published var members: [CallMember] = []        // ad-hoc: everyone invited, live from the doc
    @Published var joinedUids: Set<String> = []      // ad-hoc: everyone who ever connected
    @Published var roomStartedAt: Date?              // ad-hoc: drives "Ringing…" vs "Didn't join"
    @Published var waitingForApproval = false {      // link joiner, parked until the creator answers
        didSet { syncJoinState() }
    }
    @Published var pendingRequests: [CallMember] = [] // link creator: people waiting to be let in
    @Published private(set) var isLinkCreator = false
    @Published var incomingInvite: AdhocInvite?
    /// An ad-hoc or link call wants its screen up. `IncomingGroupCallLayer` presents GroupCallView for
    /// these; group conversation calls keep their own covers in the chat and in group info.
    @Published var presentsRoomScreen = false

    var isAdhoc: Bool { if case .adhoc(_)? = activeRoom { return true }; return false }
    var isLink: Bool { if case .link(_, _)? = activeRoom { return true }; return false }
    var myUid: String { Auth.auth().currentUser?.uid ?? "" }

    private var db: Firestore { Firestore.firestore() }
    private var functions: Functions { Functions.functions(region: "me-central1") }
    private var roomListener: ListenerRegistration?
    private var requestsListener: ListenerRegistration?
    private var myRequestListener: ListenerRegistration?
    private var waitingLink: (roomId: String, key: String, video: Bool)?
    private var inviteListener: ListenerRegistration?
    private var authHandle: AuthStateDidChangeListenerHandle?
    private var inviteUid: String?
    private var inviteDocs: [(id: String, data: [String: Any])] = []
    private var declinedInvites: Set<String> = []
    /// Opened from a tapped push: shown even past the 90s ring window, as long as the call is live.
    private var ageExemptInvites: Set<String> = []

    /// 2026-09-24 decision D25: a 1:1 call and a group call never run at once. Shared by both sides.
    static let busyNotice = Notice(title: "Can't Call", message: "You're already in a call.")

    /// 2026-09-24 decision D25: the 1:1 side's refusal. A 1:1 call can be placed from a dozen screens,
    /// some of them sheets, and a SwiftUI alert cannot present from a covered view; so this is a UIKit
    /// alert on whatever is on top. Waits out a presentation still moving (a menu or sheet closing
    /// on the same tap) and never stacks on another alert.
    static func presentOverTop(_ n: Notice, tries: Int = 4) {
        guard let top = WebLink.topViewController(), !(top is UIAlertController) else { return }
        if top.isBeingPresented || top.isBeingDismissed {
            guard tries > 0 else { return }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 300_000_000)
                GroupCallService.presentOverTop(n, tries: tries - 1)
            }
            return
        }
        let alert = UIAlertController(title: n.title, message: n.message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .cancel))
        top.present(alert, animated: true)
    }

    func start(cid: String, title: String, video: Bool) async {
        // `!connecting` too (audit): activeCid is only set AFTER connect succeeds, so a second tap
        // during the ~0.3s before the call UI covers the button started a SECOND task on the shared
        // room. Its connect threw "already connected", and its catch called disconnect() — which
        // tore down the live call the first tap had just established, for everyone in it.
        guard activeCid == nil, !connecting else { return }
        notice = nil
        closeLobbyForAnotherJoin()
        // 2026-09-24 decision D25: refused while a 1:1 call is ringing, live or closing.
        guard CallService.shared.state == .idle else { notice = Self.busyNotice; return }
        connecting = true; isVideo = video; callTitle = title
        joiningRoomId = cid
        let gen = joinGeneration   // owner audit 2026-10-06 #4
        do {
            let res = try await Functions.functions(region: "me-central1")
                .httpsCallable("groupCallToken").call(["cid": cid])
            guard gen == joinGeneration else { await abandonJoin(); return }
            guard let d = res.data as? [String: Any], let token = d["token"] as? String else {
                connecting = false
                joiningRoomId = nil
                // owner audit 2026-10-06 #44: a speaker toggle made while connecting does not
                // carry into the next call.
                speakerOn = true; AudioManager.shared.isSpeakerOutputPreferred = true
                minimized = false
                notice = Notice(title: "Call failed", message: nil)   // 2026-09-24 decision D25
                return
            }
            // Listening BEFORE the room is up: people already in the call send their raised hand
            // the moment they see me arrive, which can be before this line returns.
            GroupCallSocial.shared.attach(room: room, myUid: myUid, myName: ProfileStore.shared.me?.name ?? "")
            try await room.connect(url: url, token: token)
            guard gen == joinGeneration else { await abandonJoin(); return }
            // In the room = in the call; mic and camera follow (see startLocalMedia).
            activeCid = cid; activeRoom = .group(cid: cid); connecting = false
            startLocalMedia(mic: true, video: video)
            didJoinRoom()
            myRole = CallRole(attribute: d["role"] as? String)
            // 2026-09-24 fix-all #97: an empty room means this tap STARTED the call rather than
            // joined one, and the starter writes the call's record into the chat.
            let startedHere = room.remoteParticipants.isEmpty
            let ref = Firestore.firestore().collection("groupCalls").document(cid)
            if startedHere {
                let recordId = "gcall_\(UUID().uuidString)"
                // Mark the call active so other members see a "Join call" bar + get rung. A fresh
                // call replaces the whole doc, so a stale recordId from an old call cannot survive.
                let callDoc: [String: Any] = [
                    "active": true,
                    "startedBy": Auth.auth().currentUser?.uid ?? "",
                    "video": video,
                    "title": title,
                    "startedAt": FieldValue.serverTimestamp(),
                    "recordId": recordId,
                ]
                try? await ref.setData(callDoc)
                await Self.writeRecord(cid: cid, id: recordId, video: video)
            } else {
                // owner audit 2026-10-06 #3: a JOINER only confirms the call is live. It used to
                // write the full doc without merge, which erased the starter's recordId (so the
                // chat's "ongoing" bubble was never closed) and reset startedAt/startedBy to the
                // joiner's, so the length was measured from the wrong moment.
                try? await ref.setData(["active": true], merge: true)
            }
        } catch {
            if gen != joinGeneration { await abandonJoin(); return }   // owner audit 2026-10-06 #4
            connecting = false
            // Only tear down if THIS task never established a call. Calling disconnect()
            // unconditionally is what let a losing second task kill the winner's live room.
            if activeCid == nil {
                await disconnect()
                // 2026-09-24 decision D25; a member removed from this call is told why.
                notice = Self.joinNotice(error, link: false)
            }
        }
    }

    /// 2026-09-24 fix-all #97: a group call left no trace anywhere. It now leaves a call bubble in the
    /// group, the same `type: "call"` message the 1:1 path writes (`ChatService.recordCall`), opened
    /// "ongoing" by whoever started the room and closed "answered" with its length by the last one
    /// out (`disconnect`). The chat list gets the same plain marker a 1:1 call writes. Decision: the
    /// Calls tab does not list group calls (its call-back button dials one person), so the history
    /// lives in the group's chat.
    private static func writeRecord(cid: String, id: String, video: Bool) async {
        guard let me = Auth.auth().currentUser?.uid else { return }
        let convRef = Firestore.firestore().collection("conversations").document(cid)
        try? await convRef.collection("messages").document(id).setData([
            "type": "call",
            "authorId": me,
            "callerUid": me,
            "callOutcome": "ongoing",
            "callVideo": video,
            "text": "",
            "createdAt": FieldValue.serverTimestamp(),
        ])
        try? await convRef.setData([
            "lastMessage": video ? "📹 Video call" : "📞 Call",
            "lastSender": me,
            "updatedAt": FieldValue.serverTimestamp(),
        ], merge: true)
    }

    func toggleMic() {
        micOn.toggle(); let v = micOn
        micChangesInFlight += 1
        Task {
            try? await room.localParticipant.setMicrophone(enabled: v)
            micChangesInFlight -= 1
        }
    }

    // MARK: - Owner and moderator controls (group call permissions, 2026-10-06)

    /// Mute or remove `uid`, or end the call for everyone, through the server's `callAdmin`. The
    /// server checks my role against its own records; hiding the buttons is only a convenience.
    /// Throws the Functions error as is, so the caller can say what went wrong.
    func admin(_ action: CallAdminAction, target uid: String? = nil) async throws {
        guard let r = activeRoom else {
            throw NSError(domain: FunctionsErrorDomain, code: FunctionsErrorCode.notFound.rawValue)
        }
        let target: [String: String]
        switch r {
        case .group(let cid): target = ["kind": "group", "id": cid]
        case .adhoc(let id): target = ["kind": "adhoc", "id": id]
        case .link(let roomId, _): target = ["kind": "link", "id": roomId]
        }
        var payload: [String: Any] = ["room": target, "action": action.rawValue]
        if let uid { payload["targetUid"] = uid }
        if action == .end { endingForAll = true }
        do {
            _ = try await functions.httpsCallable("callAdmin").call(payload)
        } catch {
            if action == .end { endingForAll = false }
            throw error
        }
        // The server closed the room and the call's record; I leave quietly, like any hang-up.
        if action == .end { end() }
    }

    /// Link calls: the link people should be sent now (the new one after "Make a new link").
    var currentLink: ActiveCallLink? {
        if let replacedLink { return replacedLink }
        if case .link(let roomId, let key)? = activeRoom { return ActiveCallLink(roomId: roomId, key: key) }
        return nil
    }

    /// Owner: no one new can join with the link; the call goes on.
    func revokeLink() async throws {
        guard let link = currentLink else { return }
        try await CallLinkService.shared.revoke(link)
        linkRevoked = true
    }

    /// The people list read the link's doc and found it revoked (revoked on another visit).
    func noteLinkRevoked() { linkRevoked = true }

    /// Owner: the old link stops working and a new one with the same name and settings replaces it
    /// in my Calls list. Share and Copy hand out the new one from now on.
    func makeNewLink() async throws {
        guard let link = currentLink else { return }
        let fresh = try await CallLinkService.shared.regenerate(link)
        replacedLink = fresh
        linkRevoked = false
    }

    /// Not private: `GroupCallSocial` says "<Name> muted you" through it. Four seconds, the
    /// reference app's dwell for these notes.
    func showToast(_ text: String) {
        toast = text
        UIAccessibility.post(notification: .announcement, argument: text)
        toastTask?.cancel()
        toastTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    /// My microphone publication changed mute state. Muted while I wanted it on, with no toggle of
    /// mine in flight, means the server muted me (an owner or admin). The reference app lets you
    /// unmute again, so this only keeps the button honest and says so.
    fileprivate func localMicMuteChanged() {
        guard isActive, micOn, micChangesInFlight == 0,
              !room.localParticipant.isMicrophoneEnabled() else { return }
        micOn = false
        // The server now also says WHO ("<Name> muted you", a data message `GroupCallSocial` shows),
        // and that note lands a beat after the mute itself. Wait for it; say the plain line only if
        // none came (an older server, or the note was lost).
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard let self, self.isActive else { return }
            if let at = GroupCallSocial.shared.lastMutedByAt, Date().timeIntervalSince(at) < 3 { return }
            self.showToast("You were muted")
        }
    }

    /// Someone came or went. The caller's ringing tone stops with the first arrival.
    fileprivate func remotePeopleChanged() { updateRingback() }

    /// Someone's LiveKit attributes changed; mine may carry a new role.
    fileprivate func attributesChanged() {
        rolesVersion &+= 1
        guard isActive, let r = room.localParticipant.attributes["role"] else { return }
        myRole = CallRole(attribute: r)
    }

    /// ⛔ A REAL SPEAKER SWITCH — owner, 2026-10-04: "the speaker, I can't turn it on and off". The
    /// button was the system route picker drawn under a speaker glyph, which never showed a state
    /// and on a phone with no headset offered nothing to pick. Now it flips LiveKit's own output
    /// preference (speaker vs earpiece), the way the one-to-one call's speaker button works.
    @Published var speakerOn = true
    func toggleSpeaker() {
        speakerOn.toggle()
        AudioManager.shared.isSpeakerOutputPreferred = speakerOn
    }
    func toggleCamera() {
        guard !cameraLocked else { return }   // a voice call link: no camera for anybody
        cameraOn.toggle(); let v = cameraOn
        Task { @MainActor in
            // Owner, 2026-10-06: "when I open camera, group call is not working". The camera was
            // started without asking for access, and any failure was swallowed, so the button said
            // on while no picture went out. Ask first (as the 1:1 call does), and on a failure put
            // the button back and say why.
            if v, !(await Self.cameraAllowed()) {
                cameraOn = false
                showToast("Allow camera access in Settings")
                return
            }
            do { try await room.localParticipant.setCamera(enabled: v) }
            catch {
                guard cameraOn == v else { return }   // toggled again meanwhile
                cameraOn = !v
                showToast(v ? "Couldn't turn the camera on" : "Couldn't turn the camera off")
            }
        }
    }

    /// ⛔ IN THE ROOM IS IN THE CALL — owner, 2026-10-06, screenshots of a live call (the other
    /// person's video on screen) still saying "Connecting…". The join used to wait for the mic and
    /// then the camera to be published before it counted as joined, so a slow camera start (or the
    /// first camera-access prompt) held the whole screen on "Connecting…". Now the call is up the
    /// moment the room is, and the mic and camera start after it; the buttons show the wish at once
    /// and go back, with a short note, if a start fails.
    private func startLocalMedia(mic: Bool, video: Bool, cameraDelay: UInt64 = 0) {
        joinedAt = Date()   // the two-person header's clock (GroupCallView), kept across minimize
        micOn = mic
        cameraOn = video
        let gen = joinGeneration
        Task { @MainActor in
            do { try await room.localParticipant.setMicrophone(enabled: mic) }
            catch {
                guard gen == joinGeneration, mic else { return }
                micOn = false
                showToast("Couldn't turn the microphone on")
            }
            guard video else { return }
            guard await Self.cameraAllowed() else {
                if gen == joinGeneration { cameraOn = false; showToast("Allow camera access in Settings") }
                return
            }
            if cameraDelay > 0 { try? await Task.sleep(nanoseconds: cameraDelay) }
            guard gen == joinGeneration, cameraOn else { return }   // turned off meanwhile
            do { try await room.localParticipant.setCamera(enabled: true) }
            catch {
                guard gen == joinGeneration else { return }
                cameraOn = false
                showToast("Couldn't turn the camera on")
            }
        }
    }

    /// The room is up: the pieces that live beside this service start with it. Hands and reactions
    /// ride the room's data channel; a call answered from the lock screen is told it connected.
    private func didJoinRoom() {
        joiningRoomId = nil
        // Any call that is now up closes a lobby still open for some other link (an invitation
        // answered while looking at one): there is one call at a time.
        if lobby != nil { lobbyJoin = false; lobby = nil }
        usingFrontCamera = true
        GroupCallSocial.shared.attach(room: room, myUid: myUid, myName: ProfileStore.shared.me?.name ?? "")
        GroupCallRinging.shared.callJoined()
        updateRingback()
    }

    // MARK: - Camera position

    /// Front or back camera (owner 2026-10-06, reference study: a group call had no way to switch).
    @Published private(set) var usingFrontCamera = true
    private var flippingCamera = false
    func flipCamera() {
        guard cameraOn, !flippingCamera,
              let track = room.localParticipant.firstCameraVideoTrack as? LocalVideoTrack,
              let capturer = track.capturer as? CameraCapturer else { return }
        flippingCamera = true
        Task { @MainActor in
            do {
                _ = try await capturer.switchCameraPosition()
                usingFrontCamera = capturer.position != .back
            } catch {
                showToast("Couldn't switch the camera")
            }
            flippingCamera = false
        }
    }

    // MARK: - Ringing, as the caller hears and sees it

    /// How long an invitation to a multi-person call rings (the people list's "Ringing…" minute).
    static let ringWindow: TimeInterval = 60
    /// Invited people who said no, or whose phone answered "busy" (`groupRingAnswer` writes both on
    /// the call's doc). They stop counting as ringing at once.
    @Published private(set) var declinedUids: Set<String> = []
    @Published private(set) var busyUids: Set<String> = []
    private var roomAnswersSeeded = false

    /// Caller side (owner 2026-10-06): who a multi-person call is still ringing, for "Ringing Alice…".
    /// Invited, never joined, has not said no, and inside the ring minute. Empty for any other call.
    func ringingNames(at now: Date) -> [String] {
        guard isAdhoc, isActive, let start = roomStartedAt,
              now.timeIntervalSince(start) < Self.ringWindow else { return [] }
        let me = myUid
        return members
            .filter { $0.uid != me && !joinedUids.contains($0.uid)
                && !declinedUids.contains($0.uid) && !busyUids.contains($0.uid) }
            .map(\.name)
    }

    /// The room a join is running for, from the tap until it is joined or dropped. With `activeCid`
    /// it answers "is this ring for the call I am already going into?".
    private var joiningRoomId: String?

    /// ⛔ A RING THAT IS ALREADY MINE IS NOT "BUSY" — read by `GroupCallRinging` before it answers a
    /// ring with "busy". True when the ring is for the call I am in, joining or already answered; and
    /// when it comes from the person I am in a 1:1 with, because that is "Add people" carrying both
    /// of us into the new room (`CallService.moveToGroup`, the other side's `followMove`). Such a
    /// ring is ended quietly: no busy answer, no second call screen.
    func ringIsMine(roomId: String, callerUid: String) -> Bool {
        if activeCid == roomId || joiningRoomId == roomId || declinedInvites.contains(roomId) { return true }
        let oneToOne = CallService.shared
        return oneToOne.state != .idle && !callerUid.isEmpty && oneToOne.otherUid == callerUid
    }

    /// The tone the caller hears while the call rings and nobody has come yet: the 1:1 call's own
    /// tone (`RingbackTone`). The reference app stops it the moment the first person joins.
    private var ringback: AVAudioPlayer?
    private var ringbackTimeout: Task<Void, Never>?
    fileprivate func updateRingback() {
        let ringing = isActive && room.connectionState == .connected && room.remoteParticipants.isEmpty
            && !ringingNames(at: Date()).isEmpty
        guard ringing else { stopRingback(); return }
        guard ringback == nil else { return }
        let player = try? AVAudioPlayer(data: RingbackTone.wavData())
        player?.numberOfLoops = -1
        player?.play()
        ringback = player
        // The ring minute ends by the clock, with no event to hang the stop on.
        ringbackTimeout?.cancel()
        let left = Self.ringWindow - Date().timeIntervalSince(roomStartedAt ?? Date())
        ringbackTimeout = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(1, left + 0.5) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.updateRingback()
        }
    }
    private func stopRingback() {
        ringbackTimeout?.cancel(); ringbackTimeout = nil
        ringback?.stop(); ringback = nil
    }

    /// Camera access, asking the first time.
    static func cameraAllowed() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    func end() {
        // owner audit 2026-10-06 #4: bumped HERE, synchronously, so a join still connecting sees
        // it the moment it resumes, even if the disconnect below has not run yet.
        joinGeneration &+= 1
        // 2026-10-06 check 1: and the door is shut here too. Leaving while waiting to be let in
        // first withdraws the knock (a network wait); the creator's "approved" landing in that
        // wait used to start the join anyway, with the generation already bumped, and the person
        // ended up in the call after leaving, mic live, with no screen.
        hangingUp = true
        myRequestListener?.remove(); myRequestListener = nil
        linkDocListener?.remove(); linkDocListener = nil
        Task { await disconnect() }
    }
    /// True from `end()` until its `disconnect()` has finished. An approval that arrives in
    /// between is for a join that no longer exists.
    private var hangingUp = false

    /// owner audit 2026-10-06 #4: the call screen went away (End, or swiped down). Before the room
    /// is up there is no call to minimize to and no floating card to show, so closing the screen is
    /// leaving, the rule the approval wait already had. A live call is left alone (it minimizes),
    /// and so is a join minimized with the chevron: its card appears as soon as the room is up.
    func screenClosed() {
        guard !isActive, !minimized, connecting || waitingForApproval else { return }
        end()
    }

    /// owner audit 2026-10-06 #4: a join the user already left. Whatever it got up is taken down
    /// quietly: no notice, no call. Nothing else can have joined meanwhile, because every start
    /// refuses while `connecting` is still true.
    private func abandonJoin() async {
        await room.disconnect()
        resetRoomState()
        connecting = false
        reevaluateInvites()
    }

    /// owner audit 2026-10-06 #16: the room went to `.disconnected` on its own (kicked, token refused
    /// on reconnect, reconnect gave up). Nothing watched for it, so the screen sat on "Waiting for
    /// others…" with the doc still active and every new call refused until End was tapped. Clean
    /// up exactly as hanging up does. Our own hang-up also fires this event; `leaving` and the
    /// state check skip it.
    /// Group call permissions, 2026-10-06: `removed` = an owner or admin took me out of the call
    /// (LiveKit's participantRemoved); `deleted` = the owner ended it for everyone (roomDeleted).
    /// Each is said once the screen has closed. Neither rejoins: nothing here ever reconnects, and the
    /// server refuses a removed person a new join pass.
    fileprivate func roomDropped(_ reason: RoomDropReason) {
        guard isActive, !leaving, room.connectionState == .disconnected else { return }
        // owner 2026-10-06, reference study: every way a call ends says why. Only being removed and
        // "ended for everyone" did; a lost connection, a failed reconnect or a server fault closed
        // the screen without a word.
        let n: Notice?
        switch reason {
        case .removed:
            n = Notice(title: "You were removed from the call", message: nil)
        case .deleted:
            n = endingForAll ? nil : Notice(title: "The call was ended", message: nil)
        case .duplicate:
            n = Notice(title: "You joined this call on another device", message: nil)
        case .other:
            n = endingForAll ? nil : Notice(title: "Call unexpectedly ended",
                                            message: "Check your connection and try joining again.")
        }
        Task {
            await disconnect()
            // A UIKit alert on whatever is on top: the call screen closes as the call goes (and a
            // minimized call has no screen), so its own alert could never show this.
            if let n { Self.presentOverTop(n) }
        }
    }

    private func disconnect() async {
        leaving = true
        defer { leaving = false; hangingUp = false }
        let cid = activeCid
        let adhoc = isAdhoc, link = isLink
        // Leaving while still waiting to be let in: withdraw the knock so the creator's list does
        // not keep a person who has gone.
        if let w = waitingLink, waitingForApproval {
            try? await db.collection("callLinks").document(w.roomId)
                .collection("requests").document(myUid).delete()
        }
        // "I am the only one left" is also true when I JOINED an empty room — which is exactly the
        // case a stale doc creates (the last member force-quit, so nothing ever wrote active:false
        // and the Join bar stayed up for hours). Clearing it here means the first person to find the
        // room empty heals it for everyone, instead of the 4h age cap being the only cure (audit).
        // owner audit 2026-10-06 #17: only while the room is CONNECTED. Reconnecting (or already
        // dropped), remoteParticipants is empty because MY link is down, not because the others
        // left, and reading it then ended the call for everyone still in it. A dropped last member
        // leaves the doc active; the 4h age cap and the next person to find the room empty heal it.
        let wasLast = room.connectionState == .connected && room.remoteParticipants.isEmpty
        await room.disconnect()
        if let cid, wasLast, adhoc {
            // An ad-hoc call has no chat record to close; the last one out just stops the ringing.
            try? await db.collection("groupCalls").document(cid)
                .updateData(["active": false, "endedAt": FieldValue.serverTimestamp()])
        } else if let cid, wasLast, !link {
            let ref = Firestore.firestore().collection("groupCalls").document(cid)
            // 2026-09-24 fix-all #97: the last one out closes the call's record with its length.
            let snap = try? await ref.getDocument()
            try? await ref.setData(["active": false], merge: true)
            if let d = snap?.data(), d["active"] as? Bool == true, let recordId = d["recordId"] as? String,
               let started = (d["startedAt"] as? Timestamp)?.dateValue() {
                let secs = max(0, Int(Date().timeIntervalSince(started)))
                try? await Firestore.firestore().collection("conversations").document(cid)
                    .collection("messages").document(recordId)
                    .updateData(["callOutcome": "answered", "callDuration": secs])
            }
        }
        activeCid = nil; micOn = true; cameraOn = false; isVideo = false; callTitle = ""
        cameraLocked = false
        usingFrontCamera = true; lobbyError = nil
        // The next group call starts on the speaker again, as group calls always have.
        speakerOn = true; AudioManager.shared.isSpeakerOutputPreferred = true
        minimized = false
        resetRoomState()
        presentsRoomScreen = false
        reevaluateInvites()
    }

    // MARK: - Multi-person calls

    /// "A", "A & B", "A, B & 2 others". Used for the call screen's title and the ad-hoc doc's title.
    static func title(for others: [String]) -> String {
        let names = others.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        case 2: return "\(names[0]) & \(names[1])"
        default:
            let rest = names.count - 2
            return "\(names[0]), \(names[1]) & \(rest) \(rest == 1 ? "other" : "others")"
        }
    }

    private func myMember() -> CallMember? {
        let uid = myUid
        guard !uid.isEmpty else { return nil }
        let p = ProfileStore.shared.me
        return CallMember(uid: uid, name: p?.name ?? "", photoUrl: p?.photoUrl)
    }

    /// Starts a multi-person call with `people` (I am added automatically). Writes the room's doc first,
    /// because the token function checks membership against it, then joins. Returns the room id, or
    /// nil with `notice` set when it did not start.
    func startAdhoc(with people: [CallMember], video: Bool) async -> String? {
        guard activeCid == nil, !connecting, !waitingForApproval else { return nil }
        notice = nil
        closeLobbyForAnotherJoin()
        presentsRoomScreen = true
        // 2026-09-24 decision D25: never alongside a 1:1. The handover ends the 1:1 before this runs.
        guard CallService.shared.state == .idle else { notice = Self.busyNotice; return nil }
        guard let mine = myMember() else { notice = Notice(title: "Call failed", message: nil); return nil }
        var seen: Set<String> = [mine.uid]
        let others = people.filter { seen.insert($0.uid).inserted }
        guard !others.isEmpty else { presentsRoomScreen = false; return nil }
        let everyone = [mine] + others
        let roomId = "adhoc_" + UUID().uuidString.lowercased()
        connecting = true; isVideo = video
        members = everyone; joinedUids = []; roomStartedAt = Date()
        callTitle = Self.title(for: others.map(\.name))
        var names: [String: String] = [:]
        var photos: [String: String] = [:]
        for m in everyone {
            names[m.uid] = m.name
            if let p = m.photoUrl, !p.isEmpty { photos[m.uid] = p }
        }
        let doc: [String: Any] = [
            "kind": "adhoc",
            "active": true,
            "startedBy": mine.uid,
            "video": video,
            "title": Self.title(for: everyone.map(\.name)),
            "members": everyone.map(\.uid),
            "names": names,
            "photos": photos,
            "joined": [String](),
            "startedAt": FieldValue.serverTimestamp(),
        ]
        let gen = joinGeneration   // owner audit 2026-10-06 #4
        do {
            try await db.collection("groupCalls").document(roomId).setData(doc)
        } catch {
            if gen != joinGeneration { await abandonJoin(); return nil }
            await failJoin(Notice(title: "Call failed", message: nil))
            return nil
        }
        declinedInvites.insert(roomId)
        listenRoom(roomId)
        guard await connect(payload: ["roomId": roomId], room: .adhoc(id: roomId), video: video, gen: gen) else {
            // owner audit 2026-10-06 #4: hung up before the room was up. The doc written above is
            // already ringing the others; stop it, or they answer into an empty call.
            if gen != joinGeneration {
                try? await db.collection("groupCalls").document(roomId)
                    .updateData(["active": false, "endedAt": FieldValue.serverTimestamp()])
            }
            return nil
        }
        await markJoined(roomId)
        return roomId
    }

    /// Joins a multi-person call I am a member of (an answered invite, or the 1:1 handover).
    func joinAdhoc(roomId: String, video: Bool) async {
        guard activeCid == nil, !connecting, !waitingForApproval else { return }
        notice = nil
        closeLobbyForAnotherJoin()
        if incomingInvite?.roomId == roomId { incomingInvite = nil }
        declinedInvites.insert(roomId)   // never ring again for a room I answered
        presentsRoomScreen = true
        guard CallService.shared.state == .idle else { notice = Self.busyNotice; return }
        connecting = true; isVideo = video
        let gen = joinGeneration   // owner audit 2026-10-06 #4
        let snap = try? await db.collection("groupCalls").document(roomId).getDocument()
        guard gen == joinGeneration else { await abandonJoin(); return }
        guard let d = snap?.data(with: .estimate), d["active"] as? Bool == true else {
            connecting = false
            notice = Notice(title: "Call ended", message: nil)
            return
        }
        apply(roomData: d)
        listenRoom(roomId)
        if await connect(payload: ["roomId": roomId], room: .adhoc(id: roomId), video: video, gen: gen) {
            await markJoined(roomId)
        }
    }

    /// Adds people to the current multi-person call. The server rings only the new ones.
    func invite(_ people: [CallMember]) async {
        guard case .adhoc(let roomId)? = activeRoom else { return }
        let known = Set(members.map(\.uid))
        var seen = known
        let fresh = people.filter { seen.insert($0.uid).inserted }
        guard !fresh.isEmpty else { return }
        let all = members + fresh
        var fields: [AnyHashable: Any] = [
            "members": FieldValue.arrayUnion(fresh.map(\.uid)),
            "title": Self.title(for: all.map(\.name)),
        ]
        for m in fresh {
            fields["names.\(m.uid)"] = m.name
            if let p = m.photoUrl, !p.isEmpty { fields["photos.\(m.uid)"] = p }
        }
        members = all   // on screen at once; the room listener confirms
        // Their ring window starts now, not when the call started.
        roomStartedAt = Date()
        do {
            try await db.collection("groupCalls").document(roomId).updateData(fields)
        } catch {
            members.removeAll { m in fresh.contains { $0.uid == m.uid } }
            notice = Notice(title: "Couldn't add people", message: nil)
        }
    }

    /// Joins a call link. With admin approval on, a non-creator is parked in `waitingForApproval`
    /// until the creator answers.
    func joinLink(key: String, video: Bool, mic: Bool = true, fromLobby: Bool = false) async {
        guard activeCid == nil, !connecting, !waitingForApproval else { return }
        startMuted = !mic
        notice = nil
        lobbyError = nil
        lobbyJoin = fromLobby && lobby != nil
        // From the lobby the call screen waits until I am in (`connect`). Every other way in (a
        // link row's long-press menu) shows it at once, as before.
        if !lobbyJoin { closeLobbyForAnotherJoin(); presentsRoomScreen = true }
        guard CallService.shared.state == .idle else { refuseJoin(Self.busyNotice); return }
        guard let k = CallLinkKey(text: key) else { refuseJoin(Self.linkGone); return }
        let roomId = k.roomId
        connecting = true; isVideo = video
        callTitle = "Kulan Call"
        isLinkCreator = false
        let gen = joinGeneration   // owner audit 2026-10-06 #4
        // The name is sealed with the link's key; only someone holding the link can read it.
        // Owner, 2026-10-06 (Join Call slow): this read ran BEFORE the join, adding a full round
        // trip. It now runs alongside the token request; the title fills in when it lands.
        let docTask = Task { @MainActor [db, myUid] in
            if let d = try? await db.collection("callLinks").document(roomId).getDocument().data(),
               gen == self.joinGeneration {   // not a join already left or failed
                if let enc = d["encName"] as? String, !enc.isEmpty,
                   let name = k.decryptName(enc), !name.isEmpty { self.callTitle = name }
                self.isLinkCreator = (d["creatorUid"] as? String) == myUid
            }
        }
        let joined = await connect(payload: ["roomId": roomId, "link": true],
                                   room: .link(roomId: roomId, key: key), video: video, gen: gen)
        await docTask.value
        if joined, isLinkCreator {
            listenRequests(roomId)
        }
    }

    /// Creator of a link call: let someone in, or turn them away.
    func answerRequest(uid: String, approve: Bool) async {
        guard case .link(let roomId, _)? = activeRoom, isLinkCreator,
              let who = pendingRequests.first(where: { $0.uid == uid }) else { return }
        pendingRequests.removeAll { $0.uid == uid }
        do {
            _ = try await functions.httpsCallable("answerCallLinkRequest")
                .call(["roomId": roomId, "uid": uid, "approve": approve])
        } catch {
            // Still waiting on the server, so it goes back in the list.
            if !pendingRequests.contains(who) { pendingRequests.append(who) }
        }
    }

    /// Creator of a link call: let everyone waiting in, or turn them all away (the reference app's
    /// "Approve all" / "Deny all"). One server call; a failure puts them back in the list.
    func answerAllRequests(approve: Bool) async {
        guard case .link(let roomId, _)? = activeRoom, isLinkCreator, !pendingRequests.isEmpty else { return }
        let before = pendingRequests
        pendingRequests = []
        do {
            _ = try await functions.httpsCallable("answerAllCallLinkRequests")
                .call(["roomId": roomId, "approve": approve])
        } catch {
            if pendingRequests.isEmpty { pendingRequests = before }
            showToast("Couldn't answer everyone. Try again.")
        }
    }

    /// Creator of a link call: out of the call and refused by this link for good. False when the
    /// server said no (the caller says so).
    @discardableResult
    func block(_ uid: String) async -> Bool {
        do { try await admin(.block, target: uid); return true } catch { return false }
    }

    /// What the screen before joining shows about a link: who is in the call now, whether joining
    /// needs the creator's yes, voice only, full, or no longer valid.
    struct LinkPeek: Equatable {
        let title: String
        let count: Int
        let names: [String]     // up to three people in the call now; empty when the server keeps them back
        let approval: Bool
        let video: Bool
        let gone: Bool
        let full: Bool
        let iAmCreator: Bool
    }

    /// nil = the server could not be asked (offline, or an older server): the lobby then shows the
    /// link without the extras and Join works as it always has.
    func peekLink(key: String) async -> LinkPeek? {
        guard let k = CallLinkKey(text: key) else {
            return LinkPeek(title: "Kulan Call", count: 0, names: [], approval: false, video: true,
                            gone: true, full: false, iAmCreator: false)
        }
        guard let res = try? await functions.httpsCallable("peekCallLink").call(["roomId": k.roomId]),
              let d = res.data as? [String: Any] else { return nil }
        var title = "Kulan Call"
        if let enc = d["encName"] as? String, !enc.isEmpty, let name = k.decryptName(enc), !name.isEmpty {
            title = name
        }
        return LinkPeek(title: title,
                        count: (d["count"] as? NSNumber)?.intValue ?? 0,
                        names: d["names"] as? [String] ?? [],
                        approval: d["approval"] as? Bool ?? false,
                        video: d["video"] as? Bool ?? true,
                        gone: d["gone"] as? Bool ?? false,
                        full: d["full"] as? Bool ?? false,
                        iAmCreator: d["creator"] as? Bool ?? false)
    }

    private static let linkGone = Notice(title: "This call link is no longer valid", message: nil)

    /// A join that starts somewhere else (an invitation answered on the lock screen, a chat's Join
    /// bar) while the lobby of some link is open: the lobby goes first. The call screen is a second
    /// full-screen cover from the same place, and one asked for while the lobby is still up can be
    /// dropped, which would leave a live call with no screen (2026-10-06 check 1).
    private func closeLobbyForAnotherJoin() {
        guard lobby != nil else { return }
        lobbyJoin = false
        lobby = nil
    }

    /// A join refused before it began. In the lobby it is a line on the lobby; anywhere else it is
    /// the call screen's alert.
    private func refuseJoin(_ n: Notice) {
        if lobbyJoin, lobby != nil {
            lobbyJoin = false
            lobbyError = n.message ?? n.title
        } else {
            notice = n
        }
    }

    /// Fetches a token for `payload` and joins the room. Returns false when it did not join; a
    /// `{pending: true}` answer for a link parks us in the waiting state instead of failing.
    /// `gen` is `joinGeneration` as it was when the user started this join (owner audit 2026-10-06
    /// #4); taken by the caller, not here, because the caller already waited once before calling.
    private func connect(payload: [String: Any], room r: GroupRoom, video: Bool, gen: Int) async -> Bool {
        guard gen == joinGeneration else { await abandonJoin(); return false }
        connecting = true
        switch r {
        case .group(let cid): joiningRoomId = cid
        case .adhoc(let id): joiningRoomId = id
        case .link(let roomId, _): joiningRoomId = roomId
        }
        var isLinkRoom = false
        if case .link(_, _) = r { isLinkRoom = true }
        do {
            let res = try await functions.httpsCallable("groupCallToken").call(payload)
            guard gen == joinGeneration else { await abandonJoin(); return false }
            let d = res.data as? [String: Any]
            if d?["pending"] as? Bool == true, case .link(let roomId, let key) = r {
                beginWaiting(roomId: roomId, key: key, video: video)   // first: pending, never a beat of "not joined"
                connecting = false
                return false
            }
            guard let token = d?["token"] as? String else {
                await failJoin(Notice(title: "Call failed", message: nil))
                return false
            }
            // A voice link: join with the camera off whatever was asked, and keep it locked off.
            let voiceOnly = d?["voiceOnly"] as? Bool == true
            let video = video && !voiceOnly
            cameraLocked = voiceOnly
            if voiceOnly { isVideo = false }
            // Listening BEFORE the room is up: people already in the call send their raised hand
            // the moment they see me arrive, which can be before this line returns.
            GroupCallSocial.shared.attach(room: room, myUid: myUid, myName: ProfileStore.shared.me?.name ?? "")
            try await room.connect(url: url, token: token)
            // owner audit 2026-10-06 #4: hung up while this was connecting. Before this the room came
            // up anyway, mic on, with no screen and no card, and every other call was refused.
            guard gen == joinGeneration else { await abandonJoin(); return false }
            switch r {
            case .group(let cid): activeCid = cid
            case .adhoc(let id): activeCid = id
            case .link(let roomId, _): activeCid = roomId
            }
            activeRoom = r; connecting = false
            waitingForApproval = false
            myRole = CallRole(attribute: d?["role"] as? String)
            // Joined from the lobby: now the lobby goes and the call screen comes. The lobby's own
            // camera preview is still letting go of the camera, so the call's camera waits a beat.
            let fromLobby = lobbyJoin
            if fromLobby {
                lobbyJoin = false
                lobby = nil
                presentsRoomScreen = true
            }
            startLocalMedia(mic: !startMuted, video: video, cameraDelay: fromLobby ? 400_000_000 : 0)
            didJoinRoom()
            return true
        } catch {
            // Hung up mid-connect: the room.disconnect() that hang-up ran is what threw here, and
            // it is not a failure to report.
            if gen != joinGeneration { await abandonJoin(); return false }
            connecting = false
            if activeCid == nil { await failJoin(Self.joinNotice(error, link: isLinkRoom)) }
            return false
        }
    }

    private static func joinNotice(_ error: Error, link: Bool) -> Notice {
        let ns = error as NSError
        if ns.domain == FunctionsErrorDomain, let code = FunctionsErrorCode(rawValue: ns.code) {
            // Group call permissions, 2026-10-06: the server refuses a removed person with the
            // message "removed" (any kind of call); a turned-away link request says "denied".
            if code == .permissionDenied, ns.localizedDescription == "removed" {
                return Notice(title: "You can't rejoin this call", message: nil)
            }
            // owner 2026-10-06, reference study: the server's ceiling. (The rate limit uses the same
            // code with a different message, and stays "Call failed".)
            if code == .resourceExhausted, ns.localizedDescription == "full" {
                return Notice(title: "Call is full", message: "This call has reached its limit. Try again later.")
            }
            if link, code == .notFound { return linkGone }
            if link, code == .permissionDenied { return Notice(title: "Request denied", message: nil) }
        }
        return Notice(title: "Call failed", message: nil)
    }

    /// A join that never became a call. Leaves `presentsRoomScreen` up so GroupCallView can show
    /// the notice; its OK closes the screen.
    private func failJoin(_ n: Notice) async {
        await room.disconnect()
        cameraLocked = false
        connecting = false
        // owner audit 2026-10-06 #44: a speaker toggle made while connecting stayed set (and the
        // audio preference with it) until some later hang-up, so the next call began on the
        // earpiece. Same reset `disconnect()` does.
        speakerOn = true; AudioManager.shared.isSpeakerOutputPreferred = true
        // A join minimized with the chevron that then failed must not start the next call minimized.
        minimized = false
        let inLobby = lobbyJoin && lobby != nil   // read before the reset clears it
        resetRoomState()
        if inLobby { lobbyError = n.message ?? n.title } else { notice = n }
    }

    private func markJoined(_ roomId: String) async {
        let uid = myUid
        guard !uid.isEmpty else { return }
        joinedUids.insert(uid)
        try? await db.collection("groupCalls").document(roomId)
            .updateData(["joined": FieldValue.arrayUnion([uid])])
    }

    private func resetRoomState() {
        startMuted = false
        lobbyJoin = false
        joiningRoomId = nil
        joinedAt = nil
        stopRingback()
        declinedUids = []; busyUids = []; roomAnswersSeeded = false
        // Idempotent on both sides: this also runs for a join that never became a call.
        GroupCallSocial.shared.reset()
        GroupCallRinging.shared.callEnded()
        roomListener?.remove(); roomListener = nil
        requestsListener?.remove(); requestsListener = nil
        myRequestListener?.remove(); myRequestListener = nil
        linkDocListener?.remove(); linkDocListener = nil
        waitingLink = nil
        waitingForApproval = false
        activeRoom = nil
        members = []; joinedUids = []; roomStartedAt = nil
        pendingRequests = []; isLinkCreator = false
        myRole = .participant
        endingForAll = false
        replacedLink = nil; linkRevoked = false
        toastTask?.cancel(); toastTask = nil; toast = nil
    }

    private func apply(roomData d: [String: Any]) {
        let names = d["names"] as? [String: String] ?? [:]
        let photos = d["photos"] as? [String: String] ?? [:]
        let uids = d["members"] as? [String] ?? []
        members = uids.map { CallMember(uid: $0, name: names[$0] ?? "Member", photoUrl: photos[$0]) }
        joinedUids = Set(d["joined"] as? [String] ?? [])
        if roomStartedAt == nil, let t = (d["startedAt"] as? Timestamp)?.dateValue() { roomStartedAt = t }
        // Invited people who said no or were busy (written by the server's `groupRingAnswer`). The
        // people in the call are told once, by name; what was already there when I joined is not news.
        let declined = Set(d["declined"] as? [String] ?? [])
        let busy = Set(d["busy"] as? [String] ?? [])
        if roomAnswersSeeded, isActive {
            if let uid = busy.subtracting(busyUids).first, let name = names[uid] {
                showToast("\(name) is busy")
            } else if let uid = declined.subtracting(declinedUids).first, let name = names[uid] {
                showToast("\(name) declined")
            }
        }
        declinedUids = declined; busyUids = busy; roomAnswersSeeded = true
        updateRingback()
        let me = myUid
        let t = Self.title(for: members.filter { $0.uid != me }.map(\.name))
        if !t.isEmpty { callTitle = t }
    }

    private func listenRoom(_ roomId: String) {
        roomListener?.remove()
        roomListener = db.collection("groupCalls").document(roomId).addSnapshotListener { [weak self] snap, _ in
            guard let d = snap?.data(with: .estimate) else { return }
            Task { @MainActor [weak self] in
                guard let self, self.roomListener != nil else { return }
                self.apply(roomData: d)
            }
        }
    }

    private func beginWaiting(roomId: String, key: String, video: Bool) {
        waitingForApproval = true
        waitingLink = (roomId: roomId, key: key, video: video)
        myRequestListener?.remove()
        myRequestListener = db.collection("callLinks").document(roomId)
            .collection("requests").document(myUid)
            .addSnapshotListener { [weak self] snap, _ in
                let status = snap?.data()?["status"] as? String
                Task { @MainActor [weak self] in self?.requestStatusChanged(status) }
            }
        // owner audit 2026-10-06 #44: the server only answers requests one by one, so a joiner
        // already waiting when the admin switched approval off stayed parked until someone answered
        // the old request. Approval off on the link itself is a yes for everyone waiting.
        linkDocListener?.remove()
        linkDocListener = db.collection("callLinks").document(roomId)
            .addSnapshotListener { [weak self] snap, _ in
                guard let r = snap?.data()?["restrictions"] as? String, r != "adminApproval" else { return }
                Task { @MainActor [weak self] in self?.approvalTurnedOff() }
            }
    }

    private func requestStatusChanged(_ status: String?) {
        guard !hangingUp, !leaving, waitingForApproval, let w = waitingLink else { return }
        switch status {
        case "approved":
            admit(w)
        case "denied":
            Task { await self.failJoin(Notice(title: "Request denied", message: nil)) }
        default:
            break
        }
    }

    /// owner audit 2026-10-06 #44: approval was switched off while I waited. The token function
    /// mints straight away now; the old knock is withdrawn so the admin's list drops me.
    private func approvalTurnedOff() {
        guard !hangingUp, !leaving, waitingForApproval, let w = waitingLink else { return }
        let request = db.collection("callLinks").document(w.roomId).collection("requests").document(myUid)
        admit(w)
        Task { try? await request.delete() }
    }

    /// Let in: join the room I was waiting on. Clearing `waitingLink` first makes this run once even
    /// when the approval and the approval-off snapshot land together.
    private func admit(_ w: (roomId: String, key: String, video: Bool)) {
        myRequestListener?.remove(); myRequestListener = nil
        linkDocListener?.remove(); linkDocListener = nil
        waitingLink = nil
        // owner audit 2026-10-06 #4: taken now, so End tapped while this connects (waitingLink is
        // already gone, so the knock cleanup in disconnect() is skipped) still stops the join.
        let gen = joinGeneration
        Task {
            // Still reads "Waiting for the host to let you in" until the room is up; `connect` clears it.
            if await self.connect(payload: ["roomId": w.roomId, "link": true],
                                  room: .link(roomId: w.roomId, key: w.key), video: w.video, gen: gen),
               self.isLinkCreator {
                self.listenRequests(w.roomId)
            }
        }
    }

    private func listenRequests(_ roomId: String) {
        requestsListener?.remove()
        requestsListener = db.collection("callLinks").document(roomId).collection("requests")
            .whereField("status", isEqualTo: "pending")
            .addSnapshotListener { [weak self] snap, _ in
                guard let snap else { return }
                let list = snap.documents.map { doc -> CallMember in
                    let d = doc.data()
                    return CallMember(uid: doc.documentID, name: d["name"] as? String ?? "Member",
                                      photoUrl: d["photoUrl"] as? String)
                }
                Task { @MainActor [weak self] in
                    guard let self, self.requestsListener != nil else { return }
                    self.pendingRequests = list
                }
            }
    }

    // MARK: - Incoming multi-person invites

    /// Follows the signed-in account and listens for multi-person calls I am invited to. Safe to call
    /// more than once. `IncomingGroupCallLayer` calls it when it appears.
    func startInviteListener() {
        guard authHandle == nil else { return }
        authHandle = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            let uid = user?.uid
            Task { @MainActor [weak self] in self?.listenInvites(uid: uid) }
        }
    }

    func stopInviteListener() {
        if let h = authHandle { Auth.auth().removeStateDidChangeListener(h) }
        authHandle = nil
        listenInvites(uid: nil)
    }

    private func listenInvites(uid: String?) {
        guard uid != inviteUid else { return }
        inviteUid = uid
        inviteListener?.remove(); inviteListener = nil
        inviteDocs = []; declinedInvites = []; ageExemptInvites = []
        incomingInvite = nil
        guard let uid else { return }
        inviteListener = db.collection("groupCalls")
            // array-contains ALONE: adding `active ==` / `kind ==` here needs a composite index that
            // does not exist, and a query missing its index fails silently = no invite ever shows.
            // Only ad-hoc docs carry `members`, and the live ones are picked out on the phone.
            .whereField("members", arrayContains: uid)
            .addSnapshotListener { [weak self] snap, _ in
                guard let snap else { return }
                let docs = snap.documents
                    .filter { $0.get("active") as? Bool == true && $0.get("kind") as? String == "adhoc" }
                    .map { (id: $0.documentID, data: $0.data(with: .estimate)) }
                Task { @MainActor [weak self] in
                    guard let self, self.inviteUid == uid else { return }
                    self.inviteDocs = docs
                    self.reevaluateInvites()
                }
            }
    }

    /// Picks the invite to show, if any: not mine, not answered here or on another phone, not
    /// declined, and still inside the 90s ring window. Nothing rings while I am already in a call.
    func reevaluateInvites() {
        let me = myUid
        let now = Date()
        guard !me.isEmpty, activeCid == nil, !connecting, !waitingForApproval,
              CallService.shared.state == .idle else {
            // In another call: the invitation is not shown, and the people ringing me are told
            // "busy" instead of ringing into nothing (owner 2026-10-06; the reference app does the
            // same). Only a fresh ring for a call I am not in and have not answered.
            if !me.isEmpty {
                for doc in inviteDocs {
                    let d = doc.data
                    guard d["active"] as? Bool == true,
                          let by = d["startedBy"] as? String, by != me,
                          !ringIsMine(roomId: doc.id, callerUid: by),
                          !(d["joined"] as? [String] ?? []).contains(me),
                          !(d["declined"] as? [String] ?? []).contains(me),
                          !(d["busy"] as? [String] ?? []).contains(me),
                          !declinedInvites.contains(doc.id),
                          let at = (d["startedAt"] as? Timestamp)?.dateValue(),
                          now.timeIntervalSince(at) < Self.ringWindow else { continue }
                    GroupCallRinging.shared.reportBusy(roomKind: "adhoc", roomId: doc.id)
                }
            }
            incomingInvite = nil
            return
        }
        for doc in inviteDocs {
            let d = doc.data
            guard let by = d["startedBy"] as? String, by != me,
                  !(d["joined"] as? [String] ?? []).contains(me),
                  // Said no on my other phone, or on this one's lock screen before the app's own
                  // list loaded (the server keeps the answer on the call's doc).
                  !(d["declined"] as? [String] ?? []).contains(me),
                  !declinedInvites.contains(doc.id),
                  let invite = makeInvite(id: doc.id, data: d),
                  ageExemptInvites.contains(doc.id) || now.timeIntervalSince(invite.startedAt) < 90
            else { continue }
            if incomingInvite != invite { incomingInvite = invite }
            return
        }
        incomingInvite = nil
    }

    private func makeInvite(id: String, data d: [String: Any]) -> AdhocInvite? {
        let me = myUid
        guard let by = d["startedBy"] as? String,
              let at = (d["startedAt"] as? Timestamp)?.dateValue() else { return nil }
        let names = d["names"] as? [String: String] ?? [:]
        let photos = d["photos"] as? [String: String] ?? [:]
        let uids = (d["members"] as? [String] ?? []).filter { $0 != me }
        let ordered = uids.filter { $0 == by } + uids.filter { $0 != by }
        let others = ordered.map { CallMember(uid: $0, name: names[$0] ?? "Member", photoUrl: photos[$0]) }
        return AdhocInvite(roomId: id, title: Self.title(for: others.map(\.name)),
                           video: d["video"] as? Bool ?? false, startedBy: by, startedAt: at, others: others)
    }

    /// A tapped "adhoccall" push. Raises the invite while the call is still live, even past the
    /// ring window.
    func showInvite(roomId: String) async {
        guard roomId.hasPrefix("adhoc_"), !roomId.contains("/"), activeCid != roomId else { return }
        let me = myUid
        guard !me.isEmpty,
              let snap = try? await db.collection("groupCalls").document(roomId).getDocument(),
              let d = snap.data(with: .estimate), d["active"] as? Bool == true,
              (d["members"] as? [String] ?? []).contains(me),
              !(d["joined"] as? [String] ?? []).contains(me),
              activeCid == nil, !connecting, !waitingForApproval,
              CallService.shared.state == .idle,
              let invite = makeInvite(id: roomId, data: d) else { return }
        declinedInvites.remove(roomId)
        ageExemptInvites.insert(roomId)
        incomingInvite = invite
    }

    func declineInvite() {
        guard let i = incomingInvite else { return }
        declinedInvites.insert(i.roomId)
        incomingInvite = nil
    }

    func acceptInvite() {
        guard let i = incomingInvite else { return }
        incomingInvite = nil
        // No camera prompt in the middle of answering (the reference app's rule): a video invitation
        // is answered with the camera on only when access was already given.
        let video = i.video && AVCaptureDevice.authorizationStatus(for: .video) == .authorized
        Task { await joinAdhoc(roomId: i.roomId, video: video) }
    }
}

/// owner audit 2026-10-06 #16: tells the service when the LiveKit room goes to `.disconnected` by
/// itself. A separate NSObject because RoomDelegate is an @objc protocol called off the main
/// thread; the service decides on the main actor whether it was a drop or our own hang-up.
/// Why the room closed without my asking, as the media server put it.
enum RoomDropReason { case removed, deleted, duplicate, other }

private final class RoomDropObserver: NSObject, RoomDelegate, @unchecked Sendable {
    func room(_ room: Room, didUpdateConnectionState connectionState: ConnectionState,
              from oldConnectionState: ConnectionState) {
        guard connectionState == .disconnected else { return }
        // Read here, on the delegate's own beat: the SDK sets the reason in the same state change
        // that reports `.disconnected`, and a later connect would replace it.
        let why: RoomDropReason
        switch room.disconnectError?.type {
        case .participantRemoved?: why = .removed
        case .roomDeleted?: why = .deleted
        case .duplicateIdentity?: why = .duplicate
        default: why = .other
        }
        Task { @MainActor in GroupCallService.shared.roomDropped(why) }
    }

    func room(_ room: Room, participantDidConnect participant: RemoteParticipant) {
        Task { @MainActor in GroupCallService.shared.remotePeopleChanged() }
    }

    func room(_ room: Room, participantDidDisconnect participant: RemoteParticipant) {
        Task { @MainActor in GroupCallService.shared.remotePeopleChanged() }
    }

    /// Group call permissions, 2026-10-06: the server muting my microphone shows up as my own
    /// microphone publication going muted.
    func room(_ room: Room, participant: Participant, trackPublication: TrackPublication,
              didUpdateIsMuted isMuted: Bool) {
        guard participant is LocalParticipant, trackPublication.source == .microphone, isMuted else { return }
        Task { @MainActor in GroupCallService.shared.localMicMuteChanged() }
    }

    /// Roles live in the server-signed LiveKit attributes. The delegate gets only the changed keys,
    /// so readers look at `participant.attributes` themselves.
    func room(_ room: Room, participant: Participant, didUpdateAttributes attributes: [String: String]) {
        Task { @MainActor in GroupCallService.shared.attributesChanged() }
    }
}
