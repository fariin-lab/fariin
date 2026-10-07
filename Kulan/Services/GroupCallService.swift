import Foundation
import UIKit
import Combine
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
    private init() {
        room.add(delegate: roomObserver)
        // Audit M-081, 2026-10-07: the camera stops while the app is in the background and comes
        // back with it (see `appWentToBackground`).
        let center = NotificationCenter.default
        appObservers = [
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil,
                               queue: .main) { _ in
                Task { @MainActor in GroupCallService.shared.appWentToBackground() }
            },
            center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil,
                               queue: .main) { _ in
                Task { @MainActor in GroupCallService.shared.appCameBack() }
            },
        ]
    }
    private var appObservers: [NSObjectProtocol] = []

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
    //
    // Screen sharing (2026-10-07) goes through the Broadcast Upload extension (BroadcastUpload/),
    // so the whole phone screen is shared, not just this app. It is 1080p at 15 fps: text has to
    // stay readable, and a screen changes far less than a face, so frames are the cheap thing to
    // give up. 2.5 Mbps is the SDK's own 1080p/15 screen preset; the default "auto" degradation
    // keeps the resolution and drops frames on a weak link, which is what a shared screen wants.
    // Capture options for the extension must be room defaults; the SDK ignores per-call ones.
    let room = Room(roomOptions: RoomOptions(
        defaultCameraCaptureOptions: CameraCaptureOptions(dimensions: .h540_169),
        defaultScreenShareCaptureOptions: ScreenShareCaptureOptions(dimensions: .h1080_169, fps: 15,
                                                                    appAudio: false,
                                                                    useBroadcastExtension: true),
        defaultVideoPublishOptions: VideoPublishOptions(encoding: VideoParameters.presetH540_169.encoding,
                                                        screenShareEncoding: VideoEncoding(maxBitrate: 2_500_000,
                                                                                           maxFps: 15),
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
            // Audit 11-2: Leave (or a swipe) in the gap between the room connecting and the call
            // screen taking the lobby's place ended nothing: `lobbyJoin` was already cleared, so the
            // call ran on with no screen. The person was still looking at the lobby: that is leaving.
            if lobby == nil, oldValue != nil, lobbySwapPending { lobbySwapPending = false; end() }
        }
    }
    /// A lobby join whose room is up but whose call screen has not yet taken the lobby's place
    /// (it waits for the camera, `swapToRoom`). While on, nothing may clear the lobby on its own.
    private var lobbySwapPending = false
    /// ⛔ THE LOBBY STAYS UP UNTIL I AM IN (owner 2026-10-06, reference study). Join used to close
    /// the lobby at once and put up the call screen on "Connecting…"; with approval on, the wait
    /// happened on that second screen. Now a join started from the lobby (`joinLink(fromLobby: true)`)
    /// keeps the lobby on screen while it runs ("Ask to Join" → "Waiting to be let in"), and the call
    /// screen comes up only once the room is joined. A refusal lands here as a line of text.
    @Published var lobbyError: String?
    private var lobbyJoin = false
    /// The call screen is shown INSIDE the pre-join screen's cover after a lobby join (owner,
    /// 2026-10-07: the lobby went down, the room came up as a second cover, and the Calls list
    /// showed in between). One cover, two contents: `IncomingGroupCallLayer` swaps the lobby for
    /// the room while this is on; the cover closing then means minimize, as the room cover's does.
    @Published private(set) var roomInLobbyCover = false
    /// The lobby's preview has let go of the camera (`CallLobbyView.releaseCamera`), so the call's
    /// own camera can start at once instead of after a fixed wait.
    private var lobbyCameraFree = false
    func noteLobbyCameraReleased() { lobbyCameraFree = true }
    /// The pre-join screen's cover went away by itself: swiped down, or the call screen inside it
    /// asked to close. With the room inside that is a minimize, exactly what the room cover's own
    /// dismissal does; with the lobby still up it is leaving, as before (`lobby`'s didSet).
    func lobbyCoverClosed() {
        if roomInLobbyCover {
            roomInLobbyCover = false
            if isActive { minimized = true } else if waitingForApproval { end() }
        }
        if lobby != nil { lobby = nil }
    }
    /// The mic as the lobby left it. Read by `connect` (also after an approval wait), cleared with
    /// the room.
    private var startMuted = false
    /// When this phone got into the room. The two-person look's header clock, like a 1:1 call's;
    /// here and not on the screen, which is rebuilt every time the call is restored from its card.
    @Published private(set) var joinedAt: Date?

    /// Opens the pre-join screen for a link. Busy (a call already up or starting) says so instead.
    func openLobby(key: String) {
        guard lobby == nil else { return }
        guard activeCid == nil, !connecting, !waitingForApproval, !Self.oneToOneLive else {   // audit M-111
            Self.presentOverTop(Self.busyNotice)
            return
        }
        guard CallLinkKey(text: key) != nil else { Self.presentOverTop(Self.linkGone); return }
        lobbyError = nil
        lobby = Lobby(key: key)
    }
    @Published var cameraOn = false {
        didSet { updateGroupScreenBehavior() }   // audit M-096
    }
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
    @Published var activeRoom: GroupRoom? {          // set with activeCid; nil while no call is up
        didSet { if activeRoom != oldValue { followGroupRoles() } }   // audit M-072, 2026-10-07
    }
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
    /// Opened from a tapped push: shown even past the ring minute, as long as the call is live.
    private var ageExemptInvites: Set<String> = []
    /// audit M-097, 2026-10-07: the account a tapped push raised an invitation for. On a cold launch
    /// the tap lands before the auth listener's first start, and that start used to wipe the
    /// invitation the tap had just raised. A start for this same account keeps it.
    private var tappedInviteUid: String?
    /// audit M-094, 2026-10-07: two people who started a multi-person call to each other at the same
    /// moment. The one whose room id sorts higher gives its room up and joins the other's; this is
    /// the room to join once its own room is down (`reevaluateInvites`), and when that was decided.
    private var glareJoin: (roomId: String, video: Bool, at: Date)?

    /// audit M-065 / M-094 / M-102 / M-164, 2026-10-07: what the ad-hoc room's doc says beyond the
    /// member list. Kept with the room id it came from, so one call's values never leak into the
    /// next (everything here is read through `currentAdhocDoc`, which checks that id).
    ///   invitedAt: per person, when they were added (the doc's `invitedAt` map, or this phone's own
    ///              add while the server copy is not there yet). Each person rings for their own minute.
    ///   startedBy: who started the room.
    ///   removed:   people the owner removed (`removedUids`, server-written). They cannot be added again.
    ///   added:     people this phone just added, to notice the server dropping one again (a block).
    private struct AdhocDocState {
        let roomId: String
        var invitedAt: [String: Date] = [:]
        var startedBy: String?
        var removed: Set<String> = []
        var added: [String: (name: String, at: Date, seen: Bool)] = [:]
    }
    @Published private var adhocDoc: AdhocDocState?
    /// The ad-hoc room I am in or joining, if any.
    private var currentAdhocRoomId: String? {
        if case .adhoc(let id)? = activeRoom { return id }
        if let j = joiningRoomId, j.hasPrefix("adhoc_") { return j }
        return nil
    }
    private var currentAdhocDoc: AdhocDocState? {
        guard let s = adhocDoc, s.roomId == currentAdhocRoomId else { return nil }
        return s
    }
    /// audit M-065, 2026-10-07: when `uid`'s ring minute started in the running multi-person call.
    /// Their own add time when the doc (or this phone) has one, the call's start otherwise. Read by
    /// the people sheet's "Ringing..." too.
    func inviteStart(for uid: String) -> Date? {
        currentAdhocDoc?.invitedAt[uid] ?? roomStartedAt
    }
    /// audit M-102, 2026-10-07: people the owner removed from the running multi-person call. The
    /// server refuses to put them back on the list, and one of them in an add made the whole add fail.
    var removedUids: Set<String> { currentAdhocDoc?.removed ?? [] }
    /// The same per-person start, read from an invitation's doc on the invited phone.
    private static func inviteStart(in d: [String: Any], for uid: String) -> Date? {
        if let m = d["invitedAt"] as? [String: Any], let t = (m[uid] as? Timestamp)?.dateValue() { return t }
        return (d["startedAt"] as? Timestamp)?.dateValue()
    }

    /// audit M-072, 2026-10-07: a group conversation's call roles follow the group itself. The join
    /// answer's role was kept for the whole call, so a new owner or a demoted admin saw the wrong
    /// buttons until they rejoined. The server still checks every action itself.
    private var groupRoleListener: ListenerRegistration?
    private var groupConv: Conversation?

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

    /// Audit M-111, 2026-10-07: a 1:1 call counts as "in a call" only while it rings or runs. Its
    /// 1-2 s `.ended` tail used to refuse every group start, join and lobby as busy.
    private static var oneToOneLive: Bool {
        [.outgoing, .incoming, .active, .reconnecting].contains(CallService.shared.state)
    }

    /// `requireLive` (audit M-059, 2026-10-07): true for every way in that means "join the call that
    /// is ringing or showing" (a ring answered from CallKit, a chat's Join bar). If the room turns
    /// out to be empty, the call's doc is read from the server and an inactive call is refused with
    /// "Call ended" instead of starting a brand-new call that rings the whole group again. False
    /// (the default) only for an explicit Call button, which is allowed to create.
    func start(cid: String, title: String, video: Bool, requireLive: Bool = false) async {
        // `!connecting` too (audit): activeCid is only set AFTER connect succeeds, so a second tap
        // during the ~0.3s before the call UI covers the button started a SECOND task on the shared
        // room. Its connect threw "already connected", and its catch called disconnect() — which
        // tore down the live call the first tap had just established, for everyone in it.
        guard activeCid == nil, !connecting else { return }
        notice = nil
        // Audit M-016, 2026-10-07: waiting at a link's door is already a call claimed; a second join
        // here would run two connects on the one shared room.
        guard !waitingForApproval else { notice = Self.busyNotice; return }
        closeLobbyForAnotherJoin()
        // 2026-09-24 decision D25: refused while a 1:1 call is ringing or live (audit M-111: not in
        // its closing tail).
        guard !Self.oneToOneLive else { notice = Self.busyNotice; return }
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
            // Audit M-059, 2026-10-07: a late ring answer or a stale Join bar found nobody in the
            // room. Ask the server whether the call is still on before this tap becomes a new call;
            // nothing is published yet. A read that fails refuses too: re-ringing the whole group by
            // mistake is the worse outcome.
            if requireLive, room.remoteParticipants.isEmpty {
                let snap = try? await Firestore.firestore().collection("groupCalls").document(cid)
                    .getDocument(source: .server)
                guard gen == joinGeneration else { await abandonJoin(); return }
                guard snap?.data()?["active"] as? Bool == true else {
                    await failJoin(Notice(title: snap == nil ? "Call failed" : "Call ended", message: nil))
                    return
                }
            }
            // In the room = in the call; mic and camera follow (see startLocalMedia).
            activeCid = cid; activeRoom = .group(cid: cid); connecting = false
            // Audit M-083: a ring answered on the system call screen and muted there before the
            // room was up starts muted (kept by GroupCallRinging, read once here), as does a Mute
            // tapped in the app while joining (`startMuted`). The mic chain applies any later tap.
            startLocalMedia(mic: !startMuted && !GroupCallRinging.shared.consumeMuteOnJoin(roomId: cid),
                            video: video)
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
                // Audit M-020, 2026-10-07: the chat record only once the doc write went through.
                // A refused start (the rules keep a stale active doc of someone else's) used to
                // leave an "ongoing" bubble no doc pointed to.
                let started: Bool
                do { try await ref.setData(callDoc); started = true } catch { started = false }
                if started, gen == joinGeneration, activeCid == cid {
                    groupRecordId = recordId
                    await Self.writeRecord(cid: cid, id: recordId, video: video)
                } else if started {
                    // Audit M-139, 2026-10-07: ended (or left) while the start write was out. The
                    // leave's own end write may have run before this landed, which would leave the
                    // call active with nobody in it. Close it here, only if the doc is still mine.
                    await Self.closeCall(cid: cid, adhoc: false, recordId: recordId, answered: false)
                }
            } else {
                // owner audit 2026-10-06 #3: a JOINER no longer writes the full doc (it erased the
                // starter's recordId and reset startedAt/startedBy). Audit M-020, 2026-10-07: its
                // `active: true` merge was refused by the rules for every non-starter anyway, so it
                // is gone; the joiner only reads which call it is in, so its leave closes that one.
                let d = try? await ref.getDocument().data()
                if gen == joinGeneration, activeCid == cid { groupRecordId = d?["recordId"] as? String }
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

    /// Audit M-002, 2026-10-07: each tap used to start its own unordered Task, so a Mute tapped
    /// while the join's first publish was still running found no publication, did nothing, and the
    /// publish then went out with the button saying muted. Now the tap only changes the wish and
    /// `syncMic` applies the latest wish, one SDK call at a time.
    func toggleMic() {
        guard !leaving else { return }   // audit M-060: the dead call screen's buttons do nothing
        guard isActive || connecting || waitingForApproval else { return }   // no call, nothing to mute
        micOn.toggle()
        // Still joining: the wish is what the join publishes with (`startMuted`), not a call on a
        // room that is not up yet.
        guard isActive else { startMuted = !micOn; return }
        syncMic()
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
        // audit M-022, 2026-10-07: after "Make a new link" the link being handed out is the new one,
        // and the server checks a block against the link people come in by. Naming the old link here
        // wrote the block where the new link never looked, so a blocked person walked back in.
        case .link(let roomId, _): target = ["kind": "link", "id": currentLink?.roomId ?? roomId]
        }
        var payload: [String: Any] = ["room": target, "action": action.rawValue]
        if let uid { payload["targetUid"] = uid }
        // audit M-152, 2026-10-07: the answer can land after this call is gone (or another one has
        // started). Only the call that asked acts on it.
        let gen = joinGeneration
        if action == .end { endingForAll = true }
        do {
            _ = try await functions.httpsCallable("callAdmin").call(payload)
        } catch {
            if action == .end, gen == joinGeneration, activeRoom == r { endingForAll = false }
            throw error
        }
        // The server closed the room and the call's record; I leave quietly, like any hang-up.
        if action == .end, gen == joinGeneration, activeRoom == r { end() }
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
        let gen = joinGeneration, r = activeRoom   // audit M-152, 2026-10-07
        try await CallLinkService.shared.revoke(link)
        guard gen == joinGeneration, activeRoom == r else { return }
        linkRevoked = true
    }

    /// The people list read the link's doc and found it revoked (revoked on another visit).
    func noteLinkRevoked() { linkRevoked = true }

    /// Owner: the old link stops working and a new one with the same name and settings replaces it
    /// in my Calls list. Share and Copy hand out the new one from now on.
    func makeNewLink() async throws {
        guard let link = currentLink else { return }
        let gen = joinGeneration, r = activeRoom   // audit M-152, 2026-10-07
        let fresh = try await CallLinkService.shared.regenerate(link)
        // The call ended (or another began) while the server made the link: the new link is in the
        // Calls list either way, but it must not become the next call's link or listener.
        guard gen == joinGeneration, activeRoom == r else { return }
        replacedLink = fresh
        linkRevoked = false
        // People knocking on the NEW link: its requests live under its own id. The server leads the
        // new link into this same call (`liveRoom`, functions/index.js linkLiveRoom), 2026-10-07.
        if isLinkCreator { listenRequests(fresh.roomId) }
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
    fileprivate func remotePeopleChanged() { noteRoomPeople(); updateRingback() }

    /// Audit M-019 / M-088, 2026-10-07: what the room looked like while MY link was up. Read only
    /// while connected: when my link drops, the SDK empties the list because I am gone, not because
    /// the others left (owner audit 2026-10-06 #17).
    /// `aloneSince`: alone in a connected room since then. A drop's own cleanup can only make this
    /// a moment old, so `disconnect()` trusts it for a dropped room only when it is a few seconds old.
    /// `someoneJoined`: anybody else was ever in the room with me, so the record says "answered".
    private var aloneSince: Date?
    private var someoneJoined = false
    private func noteRoomPeople() {
        guard isActive, room.connectionState == .connected else { return }
        if room.remoteParticipants.isEmpty {
            if aloneSince == nil { aloneSince = Date() }
        } else {
            aloneSince = nil
            someoneJoined = true
        }
    }
    /// The chat record of the group conversation call I am in (`recordId` on its doc): written by me
    /// as the starter, read once as a joiner. The last-out end write checks it (audit M-033).
    private var groupRecordId: String?

    /// Someone's LiveKit attributes changed; mine may carry a new role.
    fileprivate func attributesChanged() {
        rolesVersion &+= 1
        guard isActive, let r = room.localParticipant.attributes["role"] else { return }
        // audit M-072, 2026-10-07: in a group conversation's call my attribute is the role from my
        // join, frozen; the group's own doc is newer when it has loaded.
        myRole = groupRole(of: myUid) ?? CallRole(attribute: r)
    }

    /// audit M-072, 2026-10-07: watches the group conversation while its call is up, so roles follow
    /// the group (owner handed over, admin added or demoted, "Manage video chats" taken away). Runs
    /// from `activeRoom`'s didSet: on for a group call, off for anything else or no call.
    private func followGroupRoles() {
        groupRoleListener?.remove(); groupRoleListener = nil
        groupConv = nil
        guard case .group(let cid)? = activeRoom else { return }
        groupRoleListener = db.collection("conversations").document(cid).addSnapshotListener { [weak self] snap, _ in
            guard let snap, let data = snap.data() else { return }
            let id = snap.documentID
            Task { @MainActor [weak self] in
                guard let self, case .group(let now)? = self.activeRoom, now == cid else { return }
                self.groupConv = Conversation(id: id, data: data)
                if let mine = self.groupRole(of: self.myUid), mine != self.myRole { self.myRole = mine }
                self.rolesVersion &+= 1   // other people's badges and buttons redraw too
            }
        }
    }

    /// audit M-072, 2026-10-07: `uid`'s role in the running group conversation's call, from the
    /// group's own doc, by the server's rule (`roleIn`): the creator is the owner; an admin is a
    /// moderator unless their rights leave out "Manage video chats" (audit M-073); a member who left
    /// has no say. nil when this is not a group call or the group has not loaded: the caller then
    /// keeps the server's attribute.
    func groupRole(of uid: String) -> CallRole? {
        guard !uid.isEmpty, case .group(let cid)? = activeRoom, let c = groupConv, c.id == cid else { return nil }
        if c.isOwner(uid) { return .owner }
        if c.users.contains(uid), c.adminCan(uid, .manageCalls) { return .moderator }
        return .participant
    }

    /// ⛔ A REAL SPEAKER SWITCH — owner, 2026-10-04: "the speaker, I can't turn it on and off". The
    /// button was the system route picker drawn under a speaker glyph, which never showed a state
    /// and on a phone with no headset offered nothing to pick. Now it flips LiveKit's own output
    /// preference (speaker vs earpiece), the way the one-to-one call's speaker button works.
    @Published var speakerOn = true {
        didSet { updateGroupScreenBehavior() }   // audit M-096: proximity follows the earpiece
    }
    func toggleSpeaker() {
        speakerOn.toggle()
        AudioManager.shared.isSpeakerOutputPreferred = speakerOn
    }
    func toggleCamera() {
        guard !cameraLocked else { return }   // a voice call link: no camera for anybody
        guard !leaving else { return }        // audit M-060
        cameraOn.toggle()
        // Owner, 2026-10-06: "when I open camera, group call is not working". The camera was
        // started without asking for access, and any failure was swallowed, so the button said
        // on while no picture went out. `syncCamera` asks first (as the 1:1 call does), and on a
        // failure puts the button back and says why. Audit M-002: one change at a time, latest wish
        // wins, so two quick taps can no longer leave the camera out while the button says off.
        // Still joining: the join's own start sets the camera, as before.
        if isActive { syncCamera() }
    }

    // MARK: - Mic and camera, one change at a time (audit M-002, M-084, M-085, 2026-10-07)

    /// The running chain for each source. While one runs, a new wish needs nothing more: the chain
    /// re-reads `micOn` / the camera wish after every SDK call and goes again until what is
    /// published matches.
    private var micChain: Task<Void, Never>?
    private var cameraChain: Task<Void, Never>?
    /// The lobby hand-over's `cameraReady`, run when the join's camera chain settles.
    private var pendingCameraReady: (() -> Void)?
    /// Audit M-081: the camera was switched off because the app went to the background. `cameraOn`
    /// stays true as the INTENT (the 1:1 call's rule), so it comes back with the app.
    private var cameraPausedByBackground = false
    private var cameraWanted: Bool { cameraOn && !cameraPausedByBackground && !cameraLocked }

    private func syncMic() {
        guard micChain == nil, isActive, !leaving else { return }
        let gen = joinGeneration
        // Counted for the whole chain, the join's first publish too: a mute event while it runs is
        // mine, not an owner's (`localMicMuteChanged`).
        micChangesInFlight += 1
        micChain = Task { @MainActor [weak self] in
            guard let self else { return }
            var tries = 0
            // Audit M-085: never past the call it was started for. `leaving` is set first thing by
            // `disconnect()`, which waits for this chain before it closes the room.
            while gen == self.joinGeneration, self.isActive, !self.leaving, tries < 4 {
                let want = self.micOn
                if self.room.localParticipant.isMicrophoneEnabled() == want { break }
                tries += 1
                do { try await self.room.localParticipant.setMicrophone(enabled: want) }
                catch {
                    guard gen == self.joinGeneration, !self.leaving else { break }
                    // Audit M-084: a refused microphone (permission off) used to fail silently with
                    // the button on. The button now shows what is really published, and says so.
                    let live = self.room.localParticipant.isMicrophoneEnabled()
                    if self.micOn != live {
                        self.micOn = live
                        self.showToast(want ? "Couldn't turn the microphone on" : "Couldn't turn the microphone off")
                    }
                    break
                }
            }
            self.micChain = nil
            self.micChangesInFlight -= 1
        }
    }

    private func syncCamera() {
        guard cameraChain == nil, isActive, !leaving else { return }
        let gen = joinGeneration
        cameraChain = Task { @MainActor [weak self] in
            guard let self else { return }
            var tries = 0
            while gen == self.joinGeneration, self.isActive, !self.leaving, tries < 4 {
                let want = self.cameraWanted
                if self.room.localParticipant.isCameraEnabled() == want { break }
                tries += 1
                if want, !(await Self.cameraAllowed()) {
                    if gen == self.joinGeneration, !self.leaving {
                        self.cameraOn = false
                        self.showToast("Allow camera access in Settings")
                    }
                    break
                }
                guard gen == self.joinGeneration, !self.leaving else { break }
                if want != self.cameraWanted { continue }   // changed while access was asked
                // At once, with the lobby's preview still running: the newer capture session takes
                // the camera and the lobby's picture holds its last frame until the swap, so there
                // is no moment without a picture and no wait for the preview to stop first.
                do { try await self.room.localParticipant.setCamera(enabled: want) }
                catch {
                    guard gen == self.joinGeneration, !self.leaving else { break }
                    if want == self.cameraWanted {
                        self.cameraOn = self.room.localParticipant.isCameraEnabled()
                        self.showToast(want ? "Couldn't turn the camera on" : "Couldn't turn the camera off")
                    }
                    break
                }
            }
            self.cameraChain = nil
            let ready = self.pendingCameraReady
            self.pendingCameraReady = nil
            ready?()
        }
    }

    /// Audit M-081, 2026-10-07: the group call's camera cannot keep capturing in the background,
    /// so everyone saw a frozen picture with my camera still "on". Now it stops publishing (they
    /// see my photo) and comes back when the app does. Not while sharing the screen: the share
    /// is what they are looking at then, and the shared screen keeps moving.
    private func appWentToBackground() {
        guard isActive, cameraOn, !screenSharing, !cameraPausedByBackground else { return }
        cameraPausedByBackground = true
        syncCamera()
    }

    private func appCameBack() {
        guard cameraPausedByBackground else { return }
        cameraPausedByBackground = false
        syncCamera()
    }

    /// Audit M-096, 2026-10-07: group, ad-hoc and link calls let the screen lock mid-call and had
    /// no proximity sensor. Like the 1:1 call (`CallService.updateInCallScreenBehavior`): the screen
    /// stays awake while the room is up, and a voice call on the earpiece blanks it at the ear.
    /// Never touches the proximity sensor while a 1:1 call owns it.
    private func updateGroupScreenBehavior() {
        let live = isActive && !leaving
        if live { SleepBlocker.shared.add("group-call") } else { SleepBlocker.shared.remove("group-call") }
        guard live || CallService.shared.state == .idle else { return }
        UIDevice.current.isProximityMonitoringEnabled = live && !speakerOn && !cameraOn && !screenSharing
    }

    /// ⛔ IN THE ROOM IS IN THE CALL — owner, 2026-10-06, screenshots of a live call (the other
    /// person's video on screen) still saying "Connecting…". The join used to wait for the mic and
    /// then the camera to be published before it counted as joined, so a slow camera start (or the
    /// first camera-access prompt) held the whole screen on "Connecting…". Now the call is up the
    /// moment the room is, and the mic and camera start after it; the buttons show the wish at once
    /// and go back, with a short note, if a start fails.
    /// `cameraReady` runs once on the main actor when the call's own camera is publishing, or as soon
    /// as it is known that it will not (voice, no permission, a failure, a join left meanwhile). The
    /// lobby hand-over waits on it, so a video call is never shown as a voice screen first.
    private func startLocalMedia(mic: Bool, video: Bool, cameraReady: (() -> Void)? = nil) {
        joinedAt = Date()   // the two-person header's clock (GroupCallView), kept across minimize
        micOn = mic
        cameraOn = video
        // The mic and the camera start side by side: the camera no longer waits behind the mic's
        // publish, which is most of what "Join is slow" was on a video link (owner, 2026-10-07).
        // Audit M-002, 2026-10-07: through the same one-at-a-time chains as the buttons, so a Mute
        // or camera-off tapped while these first publishes run is applied after them, never lost.
        syncMic()
        pendingCameraReady = cameraReady
        syncCamera()
        // Voice: the camera chain has nothing to do and has already settled. Run the hand-over a
        // beat later, as before, so it lands after `didJoinRoom`.
        if cameraChain == nil, let ready = pendingCameraReady {
            pendingCameraReady = nil
            Task { @MainActor in ready() }
        }
    }

    /// The room is up: the pieces that live beside this service start with it. Hands and reactions
    /// ride the room's data channel; a call answered from the lock screen is told it connected.
    private func didJoinRoom() {
        joiningRoomId = nil
        // Any call that is now up closes a lobby still open for some other link (an invitation
        // answered while looking at one): there is one call at a time. Not the lobby whose cover
        // now holds this very call (`roomInLobbyCover`).
        // Audit 11-1 (critical, build 841): this ran right after a lobby join's own room came up,
        // BEFORE the camera-ready swap set `roomInLobbyCover`, so it closed the very lobby the call
        // screen was about to replace and left a live call with no screen. A pending swap keeps it.
        if lobby != nil, !roomInLobbyCover, !lobbySwapPending { lobbyJoin = false; lobby = nil }
        usingFrontCamera = true
        GroupCallSocial.shared.attach(room: room, myUid: myUid, myName: ProfileStore.shared.me?.name ?? "")
        GroupCallRinging.shared.callJoined()
        aloneSince = nil; someoneJoined = false
        noteRoomPeople()              // audit M-019 / M-088: who was already here when I came in
        updateRingback()
        updateGroupScreenBehavior()   // audit M-096
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

    // MARK: - Screen sharing

    /// True while MY screen share track is published. Set only by the publish and unpublish events
    /// (`localScreenShareChanged`), never by the button: with the extension the first
    /// `setScreenShare(true)` only opens the system's broadcast sheet and returns nothing, and the
    /// track goes up later, when the person taps Start there (or never, if they cancel). Stopping
    /// from the red status pill or Control Center unpublishes the track too, so this follows that.
    @Published private(set) var screenSharing = false {
        didSet { updateGroupScreenBehavior() }   // audit M-096: a share is never blanked at the ear
    }
    /// Set once this call has asked for a share, so leaving knows to tell the extension to stop.
    /// A plain "is anything broadcasting" check could stop a share that belongs to a 1:1 call.
    private var shareAsked = false
    private var shareBusy = false

    /// Share Screen / Stop Sharing in the call's "..." menu. Never on a voice call link (the
    /// server's token cannot publish a screen there either).
    func toggleScreenShare() {
        guard isActive, !cameraLocked, !shareBusy else { return }
        let enable = !screenSharing
        let gen = joinGeneration
        if enable { shareAsked = true; lateShareWatch = nil }   // audit M-106: this share is wanted
        shareBusy = true
        Task { @MainActor in
            defer { shareBusy = false }
            do {
                // Enabling: the SDK shows the system broadcast sheet itself
                // (BroadcastManager.requestActivation) and publishes once the extension starts.
                try await room.localParticipant.setScreenShare(enabled: enable)
            } catch {
                if gen == joinGeneration {
                    showToast(enable ? "Couldn't share your screen" : "Couldn't stop sharing")
                }
            }
            // Unpublishing does not end the system broadcast; the extension is told separately.
            if !enable { BroadcastManager.shared.requestStop() }
        }
    }

    fileprivate func localScreenShareChanged(_ published: Bool) {
        // A late event from a room already left must not show a share in the next call.
        guard isActive || !published else { return }
        screenSharing = published
        // A share started from Control Center or the red pill was never asked for here; it still
        // belongs to this call, so leaving the call must stop the extension too.
        if published { shareAsked = true }
    }

    /// Every way out of a room ends my share: the track goes with the room, and the extension is
    /// asked to finish so the red recording pill does not outlive the call.
    private func stopScreenShare() {
        if screenSharing || shareAsked { BroadcastManager.shared.requestStop() }
        // Audit M-106, 2026-10-07: a share asked for but never started (the system sheet still
        // open as the call ends) can still be started from that sheet afterwards, and nothing
        // would ever tell it to stop. For a minute, a broadcast that starts is told to stop, as
        // long as no call is up that could own it (a new group call, or a 1:1 call's share).
        if shareAsked, !screenSharing { watchForLateShare() }
        screenSharing = false
        shareAsked = false
    }

    private var lateShareWatch: AnyCancellable?
    private var lateShareExpiry: Task<Void, Never>?
    private func watchForLateShare() {
        lateShareExpiry?.cancel()
        lateShareWatch = KSDarwinNotificationCenter.shared.publisher(for: .broadcastStarted)
            .sink { _ in
                Task { @MainActor in
                    let service = GroupCallService.shared
                    guard service.lateShareWatch != nil, !service.isActive, !service.connecting,
                          CallService.shared.state == .idle else { return }
                    BroadcastManager.shared.requestStop()
                }
            }
        lateShareExpiry = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            guard !Task.isCancelled else { return }
            self?.lateShareWatch = nil
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
        ringingMembers(at: now).map(\.name)
    }

    /// The same people as `ringingNames`, with their photos (the ringing screen, 2026-10-07).
    /// audit M-065, 2026-10-07: each person inside THEIR OWN ring minute (`inviteStart(for:)`).
    /// "Add people" used to restart one clock for the whole room, so everyone rang again.
    func ringingMembers(at now: Date) -> [CallMember] {
        guard isAdhoc, isActive else { return [] }
        let me = myUid
        return members
            .filter { $0.uid != me && !joinedUids.contains($0.uid)
                && !declinedUids.contains($0.uid) && !busyUids.contains($0.uid)
                && inviteStart(for: $0.uid).map { start in now.timeIntervalSince(start) < Self.ringWindow } == true }
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

    /// audit M-094, 2026-10-07: two people who start a multi-person call to each other at the same
    /// moment each got the other's ring while their own room was starting, and both answered "busy":
    /// nobody connected. A ring is such a crossing when it comes from someone on MY ad-hoc room's
    /// list, I started that room, and nobody has come into it yet. The lower room id wins: its
    /// starter stays and the other one gives their room up and joins it (`yieldToCrossedCall`).
    /// Anything else is a real "busy", exactly as before. Also for `GroupCallRinging`'s push path.
    enum CrossedCall { case none, iWin, iLose }
    func crossedCall(roomId: String, callerUid: String) -> CrossedCall {
        let me = myUid
        guard !me.isEmpty, !callerUid.isEmpty, callerUid != me, roomId.hasPrefix("adhoc_"),
              let mine = currentAdhocRoomId, mine != roomId, !waitingForApproval,
              (currentAdhocDoc?.startedBy ?? members.first?.uid) == me,
              members.contains(where: { $0.uid == callerUid }),
              room.remoteParticipants.isEmpty,
              joinedUids.subtracting([me]).isEmpty else { return .none }
        return roomId < mine ? .iLose : .iWin
    }

    /// audit M-094, 2026-10-07: the losing side of a crossing. My own room stops ringing and goes
    /// down; once it is down `reevaluateInvites` joins `roomId` (the other person's room).
    func yieldToCrossedCall(roomId: String) {
        guard let mine = currentAdhocRoomId, glareJoin?.roomId != roomId else { return }
        glareJoin = (roomId: roomId, video: isVideo, at: Date())
        incomingInvite = nil
        // Ended here, not only by the last-one-out write: a room still connecting skips that write.
        let ref = db.collection("groupCalls").document(mine)
        Task { try? await ref.updateData(["active": false, "endedAt": FieldValue.serverTimestamp()]) }
        end()
    }

    /// The tone the caller hears while the call rings and nobody has come yet: the 1:1 call's own
    /// tone (`RingbackTone`). The reference app stops it the moment the first person joins.
    private var ringback: AVAudioPlayer?
    private var ringbackTimeout: Task<Void, Never>?
    fileprivate func updateRingback() {
        let now = Date()
        let rung = ringingMembers(at: now)
        let ringing = isActive && room.connectionState == .connected && room.remoteParticipants.isEmpty
            && !rung.isEmpty
        guard ringing else { stopRingback(); return }
        if ringback == nil {
            let player = try? AVAudioPlayer(data: RingbackTone.wavData())
            player?.numberOfLoops = -1
            player?.play()
            ringback = player
        }
        // The ring minute ends by the clock, with no event to hang the stop on. audit M-065,
        // 2026-10-07: it ends with the LAST person's minute, and is set again on every pass, so a
        // person added while the tone plays keeps it going for their minute (it used to stop on the
        // first clock, or never re-arm and play on).
        ringbackTimeout?.cancel()
        let newest = rung.compactMap { inviteStart(for: $0.uid) }.max() ?? now
        let left = Self.ringWindow - now.timeIntervalSince(newest)
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
    /// quietly: no notice, no call.
    /// Audit M-061, 2026-10-07: `disconnect()` (which every `end()` runs) now clears `connecting`
    /// for a join left mid-way, so the phone is not "busy" until this old join wakes up. That end
    /// already closed the room and reset the state. If a NEW join (or call) owns the shared room by
    /// the time this one wakes, it is left alone; if the end is still running, it does the cleanup.
    private func abandonJoin() async {
        guard !connecting, activeCid == nil, !leaving else { return }
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
            // Audit M-028, 2026-10-07: a dropped multi-person call has no Join bar to try again
            // from, so it no longer tells the user to; and the room is no longer remembered as
            // answered, so a new ring or invitation for it can reach me.
            if case .adhoc(let id)? = activeRoom {
                declinedInvites.remove(id)
                n = endingForAll ? nil : Notice(title: "Call unexpectedly ended",
                                                message: "Check your connection.")
            } else {
                n = endingForAll ? nil : Notice(title: "Call unexpectedly ended",
                                                message: "Check your connection and try joining again.")
            }
        }
        Task {
            await disconnect()
            // A UIKit alert on whatever is on top: the call screen closes as the call goes (and a
            // minimized call has no screen), so its own alert could never show this.
            if let n { Self.presentOverTop(n) }
        }
    }

    /// Audit M-124, 2026-10-07: one leave at a time. "End for everyone" ran it twice (the room's
    /// deleted event and the admin call's own end), and the second run could tear down whatever
    /// had started in between. A second caller now waits for the run in progress.
    private var disconnectRun: Task<Void, Never>?
    private func disconnect() async {
        if let running = disconnectRun {
            await running.value
            hangingUp = false   // set again by an `end()` that arrived during that run
            return
        }
        let run = Task { @MainActor in await self.runDisconnect() }
        disconnectRun = run
        await run.value
        disconnectRun = nil
    }

    private func runDisconnect() async {
        leaving = true
        defer { leaving = false; hangingUp = false }
        // Audit M-085, 2026-10-07: a mic or camera change still in flight (the join's first publish,
        // a tap) finishes before the room closes, and `leaving` stops it from going again; so
        // nothing is left capturing and nothing is published into the next call.
        await micChain?.value
        await cameraChain?.value
        let cid = activeCid
        let adhoc = isAdhoc, link = isLink
        // Leaving while still waiting to be let in: the knock is withdrawn (below, after the local
        // state is cleared) so the creator's list does not keep a person who has gone.
        let knock = waitingForApproval ? waitingLink?.roomId : nil
        let me = myUid
        // "I am the only one left" is also true when I JOINED an empty room — which is exactly the
        // case a stale doc creates (the last member force-quit, so nothing ever wrote active:false
        // and the Join bar stayed up for hours). Clearing it here means the first person to find the
        // room empty heals it for everyone, instead of the 4h age cap being the only cure (audit).
        // owner audit 2026-10-06 #17: only while the room is CONNECTED. Reconnecting (or already
        // dropped), remoteParticipants is empty because MY link is down, not because the others
        // left, and reading it then ended the call for everyone still in it. A dropped last member
        // leaves the doc active; the 4h age cap and the next person to find the room empty heal it.
        // Audit M-019, 2026-10-07: the client half of "nobody is left". A room that dropped on its
        // own (my link gave up) has an empty list because I am gone; but if I had already been
        // alone in it, connected, for a few seconds before that, I was the last one, and nobody else
        // will ever write the end. (The server's room watcher is the full fix.)
        // Audit M-033, 2026-10-07: read as late as possible, right before the room closes.
        let state = room.connectionState
        let wasLast = (state == .connected && room.remoteParticipants.isEmpty)
            || (state == .disconnected && (aloneSince.map { Date().timeIntervalSince($0) > 3 } ?? false))
        let answered = someoneJoined   // audit M-088
        let recordId = groupRecordId
        await room.disconnect()
        // Audit M-060, 2026-10-07: the local state goes first. It used to wait for the end writes
        // below, so on a slow network the phone stayed "busy" and the dead call screen kept working
        // buttons for seconds.
        activeCid = nil; micOn = true; cameraOn = false; isVideo = false; callTitle = ""
        cameraLocked = false
        usingFrontCamera = true; lobbyError = nil
        // The next group call starts on the speaker again, as group calls always have.
        speakerOn = true; AudioManager.shared.isSpeakerOutputPreferred = true
        minimized = false
        // Audit M-061, 2026-10-07: a join left mid-way (the lobby closed, the screen swiped away)
        // kept `connecting` until that join woke up, so reopening the link or any incoming call was
        // refused as busy. Every `end()` comes through here; the old join's generation check (and
        // `abandonJoin`'s own guard) keep it from touching anything newer.
        connecting = false
        groupRecordId = nil; aloneSince = nil; someoneJoined = false
        resetRoomState()
        presentsRoomScreen = false
        reevaluateInvites()
        // The network part, after the phone is free. Audit M-099: with background time, so ending
        // from the lock screen does not lose the end write and the chat record.
        let closes = cid != nil && wasLast && !link
        guard knock != nil || closes else { return }
        Self.withBackgroundTime("group-call-end") {
            if let knock {
                try? await Firestore.firestore().collection("callLinks").document(knock)
                    .collection("requests").document(me).delete()
            }
            // Link calls have no doc to end here; the ad-hoc doc has no chat record to close.
            // A record that is not known to be mine (a stale doc found empty) keeps the old rule:
            // closed "answered" with its length, never turned into a missed call.
            if closes, let cid {
                await Self.closeCall(cid: cid, adhoc: adhoc, recordId: recordId,
                                     answered: answered || recordId == nil)
            }
        }
    }

    /// The last one out ends the call's doc and (group conversations) closes its chat record.
    /// Audit M-033 / M-034, 2026-10-07: in ONE transaction that ends only the call I was in. It
    /// used to be a blind write decided at the tap, so it could switch off a call someone had just
    /// started, and a leave queued offline could end a later call. A transaction needs the server,
    /// so nothing is queued; and for a group conversation it ends the doc only while its
    /// `recordId` is still the one of my call (when I know it).
    /// Audit M-088, 2026-10-07: a call nobody else ever joined is closed "missed", with no length.
    private static func closeCall(cid: String, adhoc: Bool, recordId: String?, answered: Bool) async {
        let db = Firestore.firestore()
        let ref = db.collection("groupCalls").document(cid)
        let ended: [String: Any]? = await withCheckedContinuation { (cont: CheckedContinuation<[String: Any]?, Never>) in
            db.runTransaction({ txn, errPtr -> Any? in
                let snap: DocumentSnapshot
                do { snap = try txn.getDocument(ref) } catch {
                    errPtr?.pointee = error as NSError
                    return nil
                }
                guard let d = snap.data(), d["active"] as? Bool == true else { return NSNull() }
                if !adhoc, let recordId, d["recordId"] as? String != recordId { return NSNull() }   // a newer call
                // The group rules let a member change `active` and nothing else; an ad-hoc doc also
                // takes `endedAt`.
                if adhoc {
                    txn.updateData(["active": false, "endedAt": FieldValue.serverTimestamp()], forDocument: ref)
                } else {
                    txn.updateData(["active": false], forDocument: ref)
                }
                return d
            }, completion: { result, error in
                cont.resume(returning: error == nil ? result as? [String: Any] : nil)
            })
        }
        // 2026-09-24 fix-all #97: the last one out closes the call's record.
        guard !adhoc, let d = ended, let rid = d["recordId"] as? String else { return }
        let record = db.collection("conversations").document(cid).collection("messages").document(rid)
        if answered, let started = (d["startedAt"] as? Timestamp)?.dateValue() {
            let secs = max(0, Int(Date().timeIntervalSince(started)))
            try? await record.updateData(["callOutcome": "answered", "callDuration": secs])
        } else if !answered {
            try? await record.updateData(["callOutcome": "missed"])
        }
    }

    /// Audit M-018, 2026-10-07: a write that waits for the server's answer only `seconds` long.
    /// true = written, false = refused, nil = no answer in time (still queued on the phone).
    private static func setDataAcked(_ ref: DocumentReference, _ data: [String: Any],
                                     within seconds: Double) async -> Bool? {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool?, Never>) in
            let once = OnceFlag()
            ref.setData(data) { error in
                if once.claim() { cont.resume(returning: error == nil) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                if once.claim() { cont.resume(returning: nil) }
            }
        }
    }

    /// Audit M-099, 2026-10-07: end-of-call writes get the short background time iOS grants, given
    /// back when they finish or after 10 s, whichever comes first.
    private static func withBackgroundTime(_ name: String, _ work: @escaping @MainActor () async -> Void) {
        let hold = BackgroundTimeHold()
        hold.id = UIApplication.shared.beginBackgroundTask(withName: name) {
            MainActor.assumeIsolated { hold.end() }
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            hold.end()
        }
        Task { @MainActor in
            await work()
            hold.end()
        }
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
        // Audit M-029, 2026-10-07: every way this returns nil now says why. "Add people" has already
        // closed the 1:1 by the time it gets here, so a silent nil left both people with nothing.
        // Already in (or waiting for) another call: no call screen is up for a notice, so an alert.
        // A start of this same kind already running is the same tap twice, and stays quiet.
        guard activeCid == nil, !connecting, !waitingForApproval else {
            if !connecting { Self.presentOverTop(Self.busyNotice) }
            return nil
        }
        notice = nil
        closeLobbyForAnotherJoin()
        presentsRoomScreen = true
        // 2026-09-24 decision D25: never alongside a 1:1. The handover ends the 1:1 before this runs.
        guard !Self.oneToOneLive else { notice = Self.busyNotice; return nil }   // audit M-111
        guard let mine = myMember() else { notice = Notice(title: "Call failed", message: nil); return nil }
        var seen: Set<String> = [mine.uid]
        let others = people.filter { seen.insert($0.uid).inserted }
        guard !others.isEmpty else { notice = Notice(title: "Call failed", message: nil); return nil }   // audit M-029
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
        let ref = db.collection("groupCalls").document(roomId)
        // Audit M-018, 2026-10-07: the start write used to be awaited until the server confirmed
        // it, which offline is never: `connecting` stayed true and every call was refused. Now it
        // gets 8 s. The token function checks membership against this doc on the server, so the
        // join cannot go ahead without it.
        let wrote = await Self.setDataAcked(ref, doc, within: 8)
        // A write that did not answer may still land later and ring everyone; the end goes in the
        // queue right behind it. Not awaited: offline it would wait for ever too.
        let stopRinging = { ref.updateData(["active": false, "endedAt": FieldValue.serverTimestamp()]) { _ in } }
        guard gen == joinGeneration else {
            if wrote != false { stopRinging() }
            await abandonJoin()
            return nil
        }
        guard wrote == true else {
            if wrote == nil { stopRinging() }
            await failJoin(Notice(title: "Call failed", message: nil))
            return nil
        }
        declinedInvites.insert(roomId)
        listenRoom(roomId)
        guard await connect(payload: ["roomId": roomId], room: .adhoc(id: roomId), video: video, gen: gen) else {
            // owner audit 2026-10-06 #4: hung up before the room was up. The doc written above is
            // already ringing the others; stop it, or they answer into an empty call.
            // Audit M-017, 2026-10-07: and the same when the token or the connect failed. Only a
            // hang-up stopped the ringing before, so the others rang into an empty room.
            stopRinging()
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
        presentsRoomScreen = true
        guard !Self.oneToOneLive else { notice = Self.busyNotice; return }   // audit M-111
        connecting = true; isVideo = video
        // Audit M-028, 2026-10-07: the room used to go into `declinedInvites` here, before any
        // check, and stayed there whatever happened, so a join that failed for a second could never
        // be rung or invited again. While joining, `joiningRoomId` makes its ring "mine"; the room
        // is remembered as answered only once I am in.
        joiningRoomId = roomId
        let gen = joinGeneration   // owner audit 2026-10-06 #4
        let snap: DocumentSnapshot
        do { snap = try await db.collection("groupCalls").document(roomId).getDocument() }
        catch {
            guard gen == joinGeneration else { await abandonJoin(); return }
            // Audit M-028: a read that failed is not "the call ended".
            connecting = false; joiningRoomId = nil
            notice = Notice(title: "Couldn't join", message: nil)
            return
        }
        guard gen == joinGeneration else { await abandonJoin(); return }
        guard let d = snap.data(with: .estimate), d["active"] as? Bool == true else {
            connecting = false; joiningRoomId = nil
            notice = Notice(title: "Call ended", message: nil)
            return
        }
        apply(roomData: d)
        listenRoom(roomId)
        if await connect(payload: ["roomId": roomId], room: .adhoc(id: roomId), video: video, gen: gen) {
            declinedInvites.insert(roomId)   // never ring again for a room I answered
            await markJoined(roomId)
        }
    }

    /// Adds people to the current multi-person call. The server rings only the new ones.
    func invite(_ people: [CallMember]) async {
        guard case .adhoc(let roomId)? = activeRoom else { return }
        let known = Set(members.map(\.uid))
        // audit M-102, 2026-10-07: people the owner removed are never added back (the server
        // refuses it, and one of them in the list made the whole add fail).
        var seen = known.union(removedUids)
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
            // audit M-065, 2026-10-07: each new person's own add time, for every phone's ring minute
            // (the invitation, the busy answer, "Ringing..."). In the SAME write as `members`: the
            // rules allow an `invitedAt` key only for a person that write adds. ⛔ Needs the rules
            // deploy first; the old rules refuse the key and the whole add with it. Phones read the
            // call's start when it is missing, as before.
            fields["invitedAt.\(m.uid)"] = FieldValue.serverTimestamp()
        }
        members = all   // on screen at once; the room listener confirms
        // Their ring window starts now, not when the call started. audit M-065, 2026-10-07: THEIR
        // window only. This used to reset `roomStartedAt`, which restarted the ring minute for
        // everyone still unanswered on this phone.
        var state = currentAdhocDoc ?? AdhocDocState(roomId: roomId)
        let now = Date()
        for m in fresh {
            state.invitedAt[m.uid] = now
            state.added[m.uid] = (name: m.name, at: now, seen: false)   // audit M-164
        }
        adhocDoc = state
        let ref = db.collection("groupCalls").document(roomId)
        do {
            try await ref.updateData(fields)
        } catch {
            members.removeAll { m in fresh.contains { $0.uid == m.uid } }
            if adhocDoc?.roomId == roomId { for m in fresh { adhocDoc?.added[m.uid] = nil } }
            // audit M-159, 2026-10-07: a line over the stage, not the alert. `notice` is the
            // failed-start alert, and its OK closes the call screen of a call that is still running.
            showToast("Couldn't add people")
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
        lobbyCameraFree = false   // the lobby says when its preview has let the camera go
        // From the lobby the call screen waits until I am in (`connect`). Every other way in (a
        // link row's long-press menu) shows it at once, as before.
        if !lobbyJoin { closeLobbyForAnotherJoin(); presentsRoomScreen = true }
        guard !Self.oneToOneLive else { refuseJoin(Self.busyNotice); return }   // audit M-111
        guard let k = CallLinkKey(text: key) else { refuseJoin(Self.linkGone); return }
        let roomId = k.roomId
        connecting = true; isVideo = video
        micOn = mic   // audit M-002: a Mute tapped while joining toggles from the lobby's choice
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
                // Audit M-069: only ever adds what the join answer may already have said.
                if (d["creatorUid"] as? String) == myUid { self.isLinkCreator = true }
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
        guard case .link(_, _)? = activeRoom, let roomId = currentLink?.roomId, isLinkCreator,
              let who = pendingRequests.first(where: { $0.uid == uid }) else { return }
        pendingRequests.removeAll { $0.uid == uid }
        let gen = joinGeneration, r = activeRoom   // audit M-152, 2026-10-07
        do {
            _ = try await functions.httpsCallable("answerCallLinkRequest")
                .call(["roomId": roomId, "uid": uid, "approve": approve])
        } catch {
            // audit M-152, 2026-10-07: the call is gone (or another began): its card must not
            // turn up in the next call's list.
            guard gen == joinGeneration, activeRoom == r else { return }
            // audit M-127, 2026-10-07: "not found" means they withdrew (or the link is gone).
            // There is nothing left to answer, and putting the card back left a ghost that stuck.
            let ns = error as NSError
            if ns.domain == FunctionsErrorDomain, ns.code == FunctionsErrorCode.notFound.rawValue { return }
            // Still waiting on the server, so it goes back in the list.
            if !pendingRequests.contains(who) { pendingRequests.append(who) }
        }
    }

    /// Creator of a link call: let everyone waiting in, or turn them all away (the reference app's
    /// "Approve all" / "Deny all"). One server call; a failure puts them back in the list.
    func answerAllRequests(approve: Bool) async {
        guard case .link(_, _)? = activeRoom, let roomId = currentLink?.roomId, isLinkCreator, !pendingRequests.isEmpty else { return }
        let before = pendingRequests
        pendingRequests = []
        let gen = joinGeneration, r = activeRoom   // audit M-152, 2026-10-07
        do {
            _ = try await functions.httpsCallable("answerAllCallLinkRequests")
                .call(["roomId": roomId, "approve": approve])
        } catch {
            guard gen == joinGeneration, activeRoom == r else { return }   // audit M-152
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

    /// A join token fetched while the pre-join screen is up (owner, 2026-10-07: Join spun for
    /// seconds): the mint's cold start and its round trip are paid before the tap, so Join goes
    /// straight to the room. Only asked for where the join needs no approval, because the server
    /// reads a token request on an approval link as a knock at the door (the lobby decides that from
    /// the link's document). Good for 90 of the token's 120 seconds; `connect` takes it once.
    /// Audit M-062, 2026-10-07: a prefetched token skips every server check made after it was
    /// minted (revoked, blocked, approval switched on, full). So it is now kept for one account only
    /// (`uid`), used within `prefetchedTokenLife` seconds instead of 90, dropped by the lobby when a
    /// peek says the link is gone or needs approval (`dropPrefetchedLinkToken`), and taken once:
    /// `connect` clears the registration first, so a request still out cannot store a used token.
    private var prefetchedLinkToken: (roomId: String, uid: String, data: [String: Any], at: Date)?
    private static let prefetchedTokenLife: TimeInterval = 20
    /// The request still out, so a Join tapped before it lands waits for it instead of asking the
    /// server a second time (owner, 2026-10-07: Join still spun when tapped straight away).
    private var prefetchingLinkToken: (roomId: String, uid: String, id: UUID, task: Task<[String: Any]?, Never>)?
    /// Audit M-062, 2026-10-07: the lobby saw the link go away, get revoked or start asking for
    /// approval. A token fetched before that must not let anyone past it.
    func dropPrefetchedLinkToken() {
        prefetchedLinkToken = nil
        prefetchingLinkToken = nil   // a request still out no longer stores its answer
    }
    func prefetchLinkToken(key: String) {
        guard let k = CallLinkKey(text: key) else { return }
        let roomId = k.roomId
        let uid = myUid
        if let p = prefetchedLinkToken, p.roomId == roomId, p.uid == uid,
           Date().timeIntervalSince(p.at) < Self.prefetchedTokenLife { return }
        if let p = prefetchingLinkToken, p.roomId == roomId, p.uid == uid { return }
        let callable = functions.httpsCallable("groupCallToken")
        let task = Task<[String: Any]?, Never> {
            guard let res = try? await callable.call(["roomId": roomId, "link": true]),
                  let d = res.data as? [String: Any],
                  d["token"] is String, d["pending"] as? Bool != true else { return nil }
            return d
        }
        let id = UUID()
        prefetchingLinkToken = (roomId, uid, id, task)
        Task { @MainActor in
            let d = await task.value
            // Only while still registered: taken by `connect`, dropped by the lobby or replaced by
            // a newer request, the answer is thrown away.
            guard prefetchingLinkToken?.id == id else { return }
            prefetchingLinkToken = nil
            if let d {
                prefetchedLinkToken = (roomId, uid, d, Date())
                // Warm the media server while the pre-join screen is up: DNS, TLS and the nearest
                // region are settled before Join, so `connect` starts from a warm socket.
                if let token = d["token"] as? String, room.connectionState == .disconnected {
                    try? await room.prepareConnection(url: url, token: token)
                }
            }
        }
    }

    /// Wakes the token function while the pre-join screen is up, so Join does not wait on its cold
    /// start (owner, 2026-10-07: "after I tap Join it loads a long time"). Fire and forget; the
    /// server answers `{warm:true}` before doing anything (functions/index.js groupCallToken).
    func warmJoin() {
        functions.httpsCallable("groupCallToken").call(["warm": true]) { _, _ in }
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
            var d: [String: Any]?
            var haveAnswer = false
            if case .link(let roomId, _) = r {
                let uid = myUid
                if let p = prefetchedLinkToken, p.roomId == roomId, p.uid == uid,
                   Date().timeIntervalSince(p.at) < Self.prefetchedTokenLife {
                    prefetchedLinkToken = nil
                    d = p.data   // fetched while the pre-join screen was up; see prefetchLinkToken
                    haveAnswer = true
                } else if let p = prefetchingLinkToken, p.roomId == roomId, p.uid == uid {
                    // Audit M-062: taken out of the registry BEFORE the wait, so the prefetch's own
                    // landing cannot store this token again for a later join.
                    prefetchingLinkToken = nil
                    prefetchedLinkToken = nil
                    if let ready = await p.task.value {
                        d = ready   // the ahead-of-time request was still out: its answer, not a second trip
                        haveAnswer = true
                    }
                }
                prefetchedLinkToken = nil   // never kept past a join, used or not
            }
            if !haveAnswer {
                let res = try await functions.httpsCallable("groupCallToken").call(payload)
                d = res.data as? [String: Any]
            }
            guard gen == joinGeneration else { await abandonJoin(); return false }
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
            // Audit M-069, 2026-10-07: "am I the link's creator" came only from a best-effort doc
            // read, so a creator whose read failed saw no request cards. The server's join answer
            // says it for certain: on a link, `owner` is the creator (functions/index.js roleFor).
            if isLinkRoom, myRole == .owner { isLinkCreator = true }
            // Joined from the lobby: now the lobby goes and the call screen comes. The lobby's own
            // camera preview is still letting go of the camera, so the call's camera waits a beat.
            let fromLobby = lobbyJoin
            if fromLobby { lobbyJoin = false }
            // ⛔ THE LOBBY STAYS UNTIL THE CAMERA IS UP (owner, 2026-10-07: "after Join it shows the
            // voice call screen, then the video one"). The call screen used to replace the lobby the
            // moment the room connected, before my camera was publishing, so a video link opened on
            // the voice layout. Now the call screen takes the lobby's place inside the same cover only
            // when the camera is live (or will not be). A backstop swaps after 2 s whatever happens.
            let swapGen = joinGeneration
            var swapped = false
            let swapToRoom: () -> Void = { [weak self] in
                guard let self, fromLobby, !swapped, swapGen == self.joinGeneration else { return }
                swapped = true
                self.lobbySwapPending = false
                self.roomInLobbyCover = true
            }
            if fromLobby { lobbySwapPending = true }
            // Audit M-083: an ad-hoc ring answered and muted on the system call screen while joining
            // starts muted too (false for anything that was not a CallKit ring).
            let ringMuted = GroupCallRinging.shared.consumeMuteOnJoin(roomId: activeCid ?? "")
            startLocalMedia(mic: !startMuted && !ringMuted, video: video, cameraReady: swapToRoom)
            if fromLobby {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    swapToRoom()
                }
            }
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
        let wasMinimized = minimized
        minimized = false
        micOn = true   // audit M-002: a lobby's or a joining tap's mute is not carried to the next call
        let inLobby = lobbyJoin && lobby != nil   // read before the reset clears it
        resetRoomState()
        if inLobby {
            lobbyError = n.message ?? n.title
        } else if wasMinimized {
            // Audit M-087, 2026-10-07: minimized while joining there is no call screen to show the
            // notice, so the failure was silent. An alert on whatever is on top says it instead.
            notice = nil
            Self.presentOverTop(n)
        } else {
            notice = n
        }
    }

    private func markJoined(_ roomId: String) async {
        let uid = myUid
        guard !uid.isEmpty else { return }
        joinedUids.insert(uid)
        try? await db.collection("groupCalls").document(roomId)
            .updateData(["joined": FieldValue.arrayUnion([uid])])
    }

    private func resetRoomState() {
        stopScreenShare()   // every leave path comes through here
        startMuted = false
        cameraPausedByBackground = false   // audit M-081
        pendingCameraReady = nil
        updateGroupScreenBehavior()        // audit M-096: the screen may lock again
        lobbyJoin = false
        lobbyCameraFree = false
        // The call ran inside the lobby's cover: that cover closes with the call. A lobby still
        // waiting (a failed join shows its error there) is left alone.
        if roomInLobbyCover { roomInLobbyCover = false; if lobby != nil { lobby = nil } }
        // A call that ends before its screen replaced the lobby closes that lobby too. The flag is
        // cleared FIRST: `lobby`'s didSet would otherwise read it and call end() again.
        if lobbySwapPending { lobbySwapPending = false; if lobby != nil { lobby = nil } }
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
        waitTask?.cancel(); waitTask = nil   // audit M-024 / M-070
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

    /// `roomId`: the room the doc is for, when the caller knows it (the room listener). Without it
    /// the per-room extras (`adhocDoc`) are left for the listener's own snapshot.
    private func apply(roomData d: [String: Any], roomId: String? = nil) {
        let names = d["names"] as? [String: String] ?? [:]
        let photos = d["photos"] as? [String: String] ?? [:]
        let uids = d["members"] as? [String] ?? []
        members = uids.map { CallMember(uid: $0, name: names[$0] ?? "Member", photoUrl: photos[$0]) }
        joinedUids = Set(d["joined"] as? [String] ?? [])
        if roomStartedAt == nil, let t = (d["startedAt"] as? Timestamp)?.dateValue() { roomStartedAt = t }
        if let roomId { applyAdhocExtras(d, roomId: roomId, uids: uids) }
        // Invited people who said no or were busy (written by the server's `groupRingAnswer`). The
        // people in the call are told once, by name; what was already there when I joined is not news.
        let declined = Set(d["declined"] as? [String] ?? [])
        let busy = Set(d["busy"] as? [String] ?? [])
        if roomAnswersSeeded, isActive {
            // audit M-104, 2026-10-07: not for someone who is in the call. The same account on a
            // second phone said no (or busy) while the first one was already here.
            let here = joinedUids.union(room.remoteParticipants.values.compactMap { $0.identity?.stringValue })
            if let uid = busy.subtracting(busyUids).subtracting(here).first, let name = names[uid] {
                showToast("\(name) is busy")
            } else if let uid = declined.subtracting(declinedUids).subtracting(here).first, let name = names[uid] {
                showToast("\(name) declined")
            }
        }
        declinedUids = declined; busyUids = busy; roomAnswersSeeded = true
        updateRingback()
        let me = myUid
        let t = Self.title(for: members.filter { $0.uid != me }.map(\.name))
        if !t.isEmpty { callTitle = t }
    }

    /// audit M-065 / M-102 / M-164, 2026-10-07: the room doc's per-person add times, its starter and
    /// its removed list, kept under `roomId` (`adhocDoc`). And a person this phone added who drops
    /// off the list again within seconds was refused by the server (a block, or their call privacy,
    /// `onAdhocCallWritten`): say so, instead of "Ringing..." and then nothing.
    private func applyAdhocExtras(_ d: [String: Any], roomId: String, uids: [String]) {
        var s = (adhocDoc?.roomId == roomId ? adhocDoc : nil) ?? AdhocDocState(roomId: roomId)
        var stamps: [String: Date] = [:]
        for (uid, v) in d["invitedAt"] as? [String: Any] ?? [:] {
            if let t = (v as? Timestamp)?.dateValue() { stamps[uid] = t }
        }
        // This phone's own add stands until the server copy is there.
        for (uid, at) in s.invitedAt where stamps[uid] == nil && uids.contains(uid) { stamps[uid] = at }
        s.invitedAt = stamps
        s.startedBy = d["startedBy"] as? String
        s.removed = Set(d["removedUids"] as? [String] ?? [])
        let listed = Set(uids)
        let now = Date()
        var refused: [String] = []
        for (uid, a) in s.added {
            if now.timeIntervalSince(a.at) > 20 { s.added[uid] = nil; continue }
            if listed.contains(uid) {
                var seen = a; seen.seen = true
                s.added[uid] = seen
            } else if a.seen {
                // On the list once, now gone, and not the owner's Remove: the server took them off.
                s.added[uid] = nil
                if !s.removed.contains(uid) { refused.append(a.name) }
            }
        }
        adhocDoc = s
        if let name = refused.first, isActive { showToast("Couldn't add \(name)") }
    }

    private func listenRoom(_ roomId: String) {
        roomListener?.remove()
        roomListener = db.collection("groupCalls").document(roomId).addSnapshotListener { [weak self] snap, _ in
            guard let d = snap?.data(with: .estimate) else { return }
            Task { @MainActor [weak self] in
                guard let self, self.roomListener != nil else { return }
                self.apply(roomData: d, roomId: roomId)
            }
        }
    }

    private func beginWaiting(roomId: String, key: String, video: Bool) {
        waitingForApproval = true
        waitingLink = (roomId: roomId, key: key, video: video)
        sawMyRequest = false
        myRequestListener?.remove()
        myRequestListener = db.collection("callLinks").document(roomId)
            .collection("requests").document(myUid)
            .addSnapshotListener { [weak self] snap, _ in
                let status = snap?.data()?["status"] as? String
                // Audit M-024: gone on the server (the link was deleted), not just not cached yet.
                let gone = snap.map { !$0.exists && !$0.metadata.isFromCache } ?? false
                Task { @MainActor [weak self] in self?.requestStatusChanged(status, gone: gone) }
            }
        // owner audit 2026-10-06 #44: the server only answers requests one by one, so a joiner
        // already waiting when the admin switched approval off stayed parked until someone answered
        // the old request. Approval off on the link itself is a yes for everyone waiting.
        linkDocListener?.remove()
        linkDocListener = db.collection("callLinks").document(roomId)
            .addSnapshotListener { [weak self] snap, _ in
                guard let snap else { return }
                let d = snap.data()
                // Audit M-024, 2026-10-07: the link deleted or revoked (also what "Make a new link"
                // does to the old one) while I wait: nobody will ever answer this knock.
                if !snap.metadata.isFromCache, d == nil || d?["revoked"] as? Bool == true {
                    Task { @MainActor [weak self] in self?.linkWentAway() }
                    return
                }
                guard let r = d?["restrictions"] as? String, r != "adminApproval" else { return }
                Task { @MainActor [weak self] in self?.approvalTurnedOff() }
            }
        // Audit M-070 / M-024, 2026-10-07: the knock is renewed every minute (the token call
        // rewrites the request's `at`, so the creator's list keeps a person really waiting and drops
        // one who left without a clean exit), and after two minutes with no answer the wait ends:
        // a host who left, or never looked, used to keep the joiner at the door for ever.
        waitTask?.cancel()
        let gen = joinGeneration
        waitTask = Task { @MainActor [weak self] in
            for minute in 1...2 {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                guard let self, !Task.isCancelled, gen == self.joinGeneration, !self.hangingUp, !self.leaving,
                      self.waitingForApproval, self.waitingLink?.roomId == roomId else { return }
                if minute == 1 {
                    // The answer is not used: an approval or "approval off" arrives on the listeners.
                    self.functions.httpsCallable("groupCallToken")
                        .call(["roomId": roomId, "link": true]) { _, _ in }
                } else {
                    let uid = self.myUid
                    self.db.collection("callLinks").document(roomId).collection("requests")
                        .document(uid).delete { _ in }
                    await self.failJoin(Notice(title: "The host didn't let you in", message: nil))
                }
            }
        }
    }
    /// Audit M-024 / M-070: the knock's minute timer, cancelled with the wait.
    private var waitTask: Task<Void, Never>?
    /// Audit M-024: my request has been seen on the server, so its disappearing means deleted.
    private var sawMyRequest = false

    private func requestStatusChanged(_ status: String?, gone: Bool = false) {
        guard !hangingUp, !leaving, waitingForApproval, let w = waitingLink else { return }
        if status != nil { sawMyRequest = true }
        switch status {
        case "approved":
            admit(w)
        case "denied":
            Task { await self.failJoin(Notice(title: "Request denied", message: nil)) }
        case nil where gone && sawMyRequest:
            linkWentAway()   // audit M-024: my request was deleted with the link
        default:
            break
        }
    }

    /// Audit M-024, 2026-10-07: the link this knock was for is gone. The wait ends with the words a
    /// joiner of a gone link already sees.
    private func linkWentAway() {
        guard !hangingUp, !leaving, waitingForApproval, waitingLink != nil else { return }
        Task { await self.failJoin(Self.linkGone) }
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
        waitTask?.cancel(); waitTask = nil   // audit M-024 / M-070: let in, the wait is over
        waitingLink = nil
        // Audit M-016, 2026-10-07: a 1:1 call got through while I waited at the door. Being let in
        // now would publish my mic into the link room with the private call still running, so the
        // join is refused as busy instead.
        if Self.oneToOneLive {
            Task { await self.failJoin(Self.busyNotice) }
            return
        }
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
        requestDocs = []; requestSeen = [:]   // audit M-070: another link's list starts afresh
        requestsListener = db.collection("callLinks").document(roomId).collection("requests")
            .whereField("status", isEqualTo: "pending")
            .addSnapshotListener { [weak self] snap, _ in
                guard let snap else { return }
                let list = snap.documents.map { doc -> (member: CallMember, at: Date?) in
                    let d = doc.data()
                    return (member: CallMember(uid: doc.documentID, name: d["name"] as? String ?? "Member",
                                               photoUrl: d["photoUrl"] as? String),
                            at: (d["at"] as? Timestamp)?.dateValue())
                }
                Task { @MainActor [weak self] in
                    guard let self, self.requestsListener != nil else { return }
                    // audit M-070, 2026-10-07: when this phone last saw each request change. A
                    // waiting joiner's knock is renewed while they wait (its `at` moves); one that has
                    // not moved for `requestFreshness` belongs to someone who left without a clean
                    // exit, and is hidden. Timed on THIS phone's clock from the moment it saw the
                    // change, so a phone clock that is off cannot hide a fresh request.
                    let now = Date()
                    var seen: [String: (at: Date?, seen: Date)] = [:]
                    for r in list {
                        if let old = self.requestSeen[r.member.uid], old.at == r.at {
                            seen[r.member.uid] = old
                        } else {
                            seen[r.member.uid] = (at: r.at, seen: now)
                        }
                    }
                    self.requestSeen = seen
                    self.requestDocs = list.map(\.member)
                    self.refreshPendingRequests()
                }
            }
    }

    /// audit M-070, 2026-10-07: the creator's raw request list, and when each was last seen to change.
    private var requestDocs: [CallMember] = []
    private var requestSeen: [String: (at: Date?, seen: Date)] = [:]
    private var requestExpiry: Task<Void, Never>?
    /// A knock not renewed for this long is from someone who has gone (about three minutes; a joiner
    /// still waiting renews it well inside that).
    private static let requestFreshness: TimeInterval = 180

    /// audit M-070, 2026-10-07: shows the live requests, and comes back when the next one goes stale.
    private func refreshPendingRequests() {
        let now = Date()
        let live = requestDocs.filter { m in
            requestSeen[m.uid].map { now.timeIntervalSince($0.seen) < Self.requestFreshness } ?? true
        }
        if live != pendingRequests { pendingRequests = live }
        requestExpiry?.cancel(); requestExpiry = nil
        let next = live.compactMap { requestSeen[$0.uid]?.seen }.min()
        guard let next else { return }
        let wait = max(1, Self.requestFreshness - now.timeIntervalSince(next) + 0.5)
        requestExpiry = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard !Task.isCancelled, let self, self.requestsListener != nil else { return }
            self.refreshPendingRequests()
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
        inviteDocs = []; declinedInvites = []
        // audit M-097, 2026-10-07: an invitation a tapped push raised for this same account stays
        // (on a cold launch the tap lands before this first start). Any other account's goes.
        if uid == nil || uid != tappedInviteUid {
            ageExemptInvites = []
            incomingInvite = nil
            tappedInviteUid = nil
        }
        glareJoin = nil
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
    /// declined, and still inside my ring minute. Nothing rings while I am already in a call.
    /// audit M-065 / M-126, 2026-10-07: the minute is `ringWindow` (the caller's own ring length; this
    /// was 90 s, so the invitation outlived the ring by half a minute), counted from when I was added
    /// (`invitedAt`), not from the call's start, so a person added late is rung and told busy too.
    /// audit M-076, 2026-10-07: never from someone I blocked, and no "busy" back to them either.
    func reevaluateInvites() {
        let me = myUid
        let now = Date()
        let blocks = BlockList.snapshot
        guard !me.isEmpty, activeCid == nil, !connecting, !waitingForApproval,
              CallService.shared.state == .idle else {
            // In another call: the invitation is not shown, and the people ringing me are told
            // "busy" instead of ringing into nothing (owner 2026-10-06; the reference app does the
            // same). Only a fresh ring for a call I am not in and have not answered.
            if !me.isEmpty {
                for doc in inviteDocs {
                    let d = doc.data
                    guard d["active"] as? Bool == true,
                          doc.id != glareJoin?.roomId,   // audit M-094: the room I am about to join
                          let by = d["startedBy"] as? String, by != me,
                          !blocks.contains(by),
                          !ringIsMine(roomId: doc.id, callerUid: by),
                          !(d["joined"] as? [String] ?? []).contains(me),
                          !(d["declined"] as? [String] ?? []).contains(me),
                          !(d["busy"] as? [String] ?? []).contains(me),
                          !declinedInvites.contains(doc.id),
                          let at = Self.inviteStart(in: d, for: me),
                          now.timeIntervalSince(at) < Self.ringWindow else { continue }
                    // audit M-094, 2026-10-07: a crossed start is not "busy" (see `crossedCall`).
                    switch crossedCall(roomId: doc.id, callerUid: by) {
                    case .iWin: continue
                    case .iLose: yieldToCrossedCall(roomId: doc.id); return
                    case .none: break
                    }
                    GroupCallRinging.shared.reportBusy(roomKind: "adhoc", roomId: doc.id)
                }
            }
            incomingInvite = nil
            return
        }
        // audit M-094, 2026-10-07: my own room is down after a crossed start; go into theirs, the
        // way the reference app puts both people in one call. Only while it is still live and fresh.
        if let g = glareJoin {
            glareJoin = nil
            if now.timeIntervalSince(g.at) < 30,
               inviteDocs.contains(where: { $0.id == g.roomId && $0.data["active"] as? Bool == true }) {
                let video = g.video && AVCaptureDevice.authorizationStatus(for: .video) == .authorized
                Task { await joinAdhoc(roomId: g.roomId, video: video) }
                return
            }
        }
        for doc in inviteDocs {
            let d = doc.data
            guard let by = d["startedBy"] as? String, by != me,
                  !blocks.contains(by),
                  !(d["joined"] as? [String] ?? []).contains(me),
                  // Said no on my other phone, or on this one's lock screen before the app's own
                  // list loaded (the server keeps the answer on the call's doc).
                  !(d["declined"] as? [String] ?? []).contains(me),
                  !declinedInvites.contains(doc.id),
                  let invite = makeInvite(id: doc.id, data: d),
                  let start = Self.inviteStart(in: d, for: me),
                  ageExemptInvites.contains(doc.id) || now.timeIntervalSince(start) < Self.ringWindow
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
              let invite = makeInvite(id: roomId, data: d),
              !BlockList.snapshot.contains(invite.startedBy)   // audit M-076, 2026-10-07
        else { return }
        declinedInvites.remove(roomId)
        ageExemptInvites.insert(roomId)
        tappedInviteUid = me   // audit M-097, 2026-10-07: survives the listener's first start
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

/// Audit M-099, 2026-10-07: one background-time assertion, given back once (the work finished, the
/// 10 s cap, or iOS asking for it back, whichever is first).
@MainActor
private final class BackgroundTimeHold {
    var id: UIBackgroundTaskIdentifier = .invalid
    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}

/// Audit M-018, 2026-10-07: lets exactly one of two racing callbacks resume a continuation.
private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if used { return false }
        used = true
        return true
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

    /// Screen sharing, 2026-10-07: my screen share track going up or coming down is the only truth
    /// for "I am sharing" (the system sheet, the red pill and Control Center all end here).
    func room(_ room: Room, participant: LocalParticipant, didPublishTrack publication: LocalTrackPublication) {
        guard publication.source == .screenShareVideo else { return }
        Task { @MainActor in GroupCallService.shared.localScreenShareChanged(true) }
    }

    func room(_ room: Room, participant: LocalParticipant, didUnpublishTrack publication: LocalTrackPublication) {
        guard publication.source == .screenShareVideo else { return }
        Task { @MainActor in GroupCallService.shared.localScreenShareChanged(false) }
    }

    /// Roles live in the server-signed LiveKit attributes. The delegate gets only the changed keys,
    /// so readers look at `participant.attributes` themselves.
    func room(_ room: Room, participant: Participant, didUpdateAttributes attributes: [String: String]) {
        Task { @MainActor in GroupCallService.shared.attributesChanged() }
    }
}
