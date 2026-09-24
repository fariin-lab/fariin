import Foundation
import UIKit
import LiveKit
import FirebaseFunctions
import FirebaseFirestore
import FirebaseAuth

// Group calls run on LiveKit (an SFU) — phones can't mesh more than ~3 people. 1:1 calls stay on
// stasel/WebRTC; LiveKit ships LK-prefixed WebRTC so the two coexist. The join token is minted
// server-side by the `groupCallToken` function (our API secret never touches the app).
@MainActor
final class GroupCallService: ObservableObject {
    static let shared = GroupCallService()
    private init() {}

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
    @Published var activeCid: String?       // nil = no group call in progress
    @Published var isVideo = false
    @Published var micOn = true
    @Published var cameraOn = false
    @Published var connecting = false
    @Published var minimized = false        // swiped down → CallContainer shows the return bar
    @Published var callTitle = ""
    /// 2026-09-24 decision D25: why a start did not become a call. GroupCallView shows it as an alert
    /// and closes on OK. Before this a failed start left the call screen up on "1 in call", with
    /// nobody in it and nothing saying why.
    struct Notice: Equatable { let title: String; let message: String? }
    @Published var notice: Notice?

    var isActive: Bool { activeCid != nil }

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
        // 2026-09-24 decision D25: refused while a 1:1 call is ringing, live or closing.
        guard CallService.shared.state == .idle else { notice = Self.busyNotice; return }
        connecting = true; isVideo = video; callTitle = title
        do {
            let res = try await Functions.functions(region: "me-central1")
                .httpsCallable("groupCallToken").call(["cid": cid])
            guard let d = res.data as? [String: Any], let token = d["token"] as? String else {
                connecting = false
                notice = Notice(title: "Call failed", message: nil)   // 2026-09-24 decision D25
                return
            }
            try await room.connect(url: url, token: token)
            try await room.localParticipant.setMicrophone(enabled: true)
            if video { try await room.localParticipant.setCamera(enabled: true) }
            activeCid = cid; micOn = true; cameraOn = video; connecting = false
            // 2026-09-24 fix-all #97: an empty room means this tap STARTED the call rather than
            // joined one, and the starter writes the call's record into the chat.
            let startedHere = room.remoteParticipants.isEmpty
            let recordId = startedHere ? "gcall_\(UUID().uuidString)" : nil
            // Mark the call active so other members see a "Join call" bar + get rung.
            var callDoc: [String: Any] = [
                "active": true,
                "startedBy": Auth.auth().currentUser?.uid ?? "",
                "video": video,
                "title": title,
                "startedAt": FieldValue.serverTimestamp(),
            ]
            if let recordId { callDoc["recordId"] = recordId }
            try? await Firestore.firestore().collection("groupCalls").document(cid).setData(callDoc)
            if let recordId { await Self.writeRecord(cid: cid, id: recordId, video: video) }
        } catch {
            connecting = false
            // Only tear down if THIS task never established a call. Calling disconnect()
            // unconditionally is what let a losing second task kill the winner's live room.
            if activeCid == nil {
                await disconnect()
                notice = Notice(title: "Call failed", message: nil)   // 2026-09-24 decision D25
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
        Task { try? await room.localParticipant.setMicrophone(enabled: v) }
    }
    func toggleCamera() {
        cameraOn.toggle(); let v = cameraOn
        Task { try? await room.localParticipant.setCamera(enabled: v) }
    }

    func end() { Task { await disconnect() } }

    private func disconnect() async {
        let cid = activeCid
        // "I am the only one left" is also true when I JOINED an empty room — which is exactly the
        // case a stale doc creates (the last member force-quit, so nothing ever wrote active:false
        // and the Join bar stayed up for hours). Clearing it here means the first person to find the
        // room empty heals it for everyone, instead of the 4h age cap being the only cure (audit).
        let wasLast = room.remoteParticipants.isEmpty   // I'm the only one → end the call for the group
        await room.disconnect()
        if let cid, wasLast {
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
        minimized = false
    }
}
