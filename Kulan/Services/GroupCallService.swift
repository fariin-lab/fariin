import Foundation
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

    let room = Room()                       // observe this in the UI for live participant updates
    @Published var activeCid: String?       // nil = no group call in progress
    @Published var isVideo = false
    @Published var micOn = true
    @Published var cameraOn = false
    @Published var connecting = false
    @Published var minimized = false        // swiped down → CallContainer shows the return bar
    @Published var callTitle = ""

    var isActive: Bool { activeCid != nil }

    func start(cid: String, title: String, video: Bool) async {
        // `!connecting` too (audit): activeCid is only set AFTER connect succeeds, so a second tap
        // during the ~0.3s before the call UI covers the button started a SECOND task on the shared
        // room. Its connect threw "already connected", and its catch called disconnect() — which
        // tore down the live call the first tap had just established, for everyone in it.
        guard activeCid == nil, !connecting else { return }
        connecting = true; isVideo = video; callTitle = title
        do {
            let res = try await Functions.functions(region: "me-central1")
                .httpsCallable("groupCallToken").call(["cid": cid])
            guard let d = res.data as? [String: Any], let token = d["token"] as? String else {
                connecting = false; return
            }
            try await room.connect(url: url, token: token)
            try await room.localParticipant.setMicrophone(enabled: true)
            if video { try await room.localParticipant.setCamera(enabled: true) }
            activeCid = cid; micOn = true; cameraOn = video; connecting = false
            // Mark the call active so other members see a "Join call" bar + get rung.
            try? await Firestore.firestore().collection("groupCalls").document(cid).setData([
                "active": true,
                "startedBy": Auth.auth().currentUser?.uid ?? "",
                "video": video,
                "title": title,
                "startedAt": FieldValue.serverTimestamp(),
            ])
        } catch {
            connecting = false
            // Only tear down if THIS task never established a call. Calling disconnect()
            // unconditionally is what let a losing second task kill the winner's live room.
            if activeCid == nil { await disconnect() }
        }
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
            try? await Firestore.firestore().collection("groupCalls").document(cid)
                .setData(["active": false], merge: true)
        }
        activeCid = nil; micOn = true; cameraOn = false; isVideo = false; callTitle = ""
        minimized = false
    }
}
