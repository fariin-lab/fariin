import SwiftUI
import AVFoundation
import FirebaseFirestore

/// ⛔ THE SCREEN BEFORE A LINK CALL — owner, 2026-10-06, with a screenshot of the reference app's
/// pre-join screen: your own camera full screen, the call's name with "Call link" under it at the
/// top, a camera and a mic button, then Leave and Join. Join enters the call the way the two
/// buttons were left. A Voice link keeps the camera off and its button dimmed.
///
/// owner, 2026-10-06 (group call plan, the reference app's lobby rules): the screen asks the
/// server about the link when it opens and every 5s after. A dead link turns it into an error
/// with one Close button. A live one says who is in the call under "Call link". Join reads
/// "Ask to Join" when the creator lets people in one by one, and the screen STAYS UP while the
/// join runs: a spinner on Join, "Waiting to be let in" while at the door. The service closes
/// the screen once the room is up; a refusal comes back here as a short note and Join works again.
///
/// The preview is a plain capture session, not a call track: nothing is published before Join,
/// and the session is stopped the moment the service says the call is joined, because the call
/// starts its own camera then.
struct CallLobbyView: View {
    let lobby: GroupCallService.Lobby

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var service = GroupCallService.shared
    @State private var title = "Kulan Call"
    @State private var voiceOnly = false
    @State private var cameraOn = true
    /// Off to begin with, as in the owner's screenshot of the reference screen: you choose to be
    /// heard before you walk in.
    @State private var micOn = false
    @State private var cameraDenied = false
    /// Camera access answered yes. The preview waits for it.
    @State private var cameraReady = false
    /// The camera is no longer this screen's: the call has it now, or the screen was left.
    @State private var released = false
    /// The server's last answer about the link. nil until the first one lands.
    @State private var peek: GroupCallService.LobbyPeek?
    /// Join was tapped and the service has not come back yet. Covers the beat before its
    /// `joinState` moves, so a second tap finds the button already taken.
    @State private var starting = false
    /// A short line over the buttons ("This call is full", "Request denied"). Clears itself.
    @State private var note: String?
    @State private var noteTask: Task<Void, Never>?
    @StateObject private var preview = LobbyCameraPreview()

    private var me: (name: String, photo: String?) {
        (ProfileStore.shared.me?.name ?? "You", ProfileStore.shared.me?.photoUrl)
    }
    private var showsCamera: Bool { cameraOn && !voiceOnly && !cameraDenied }
    private var linkGone: Bool { peek?.gone == true }
    /// The capture session runs only while its picture is on screen and the camera is still ours.
    private var runsPreview: Bool { showsCamera && cameraReady && !released && !linkGone }
    /// A join is asked for, connecting, waiting at the door, or done: the buttons hold still.
    private var locked: Bool { starting || service.joinState != .notJoined }
    /// The reference app's rule: the creator walks straight in, everyone else knocks when the
    /// link has approval on.
    private var joinTitle: String {
        if let peek, peek.approval, !peek.iAmCreator { return "Ask to Join" }
        return "Join"
    }
    private var joinSpoken: String {
        guard locked else { return joinTitle }
        return service.joinState == .pending ? "Waiting to be let in" : "Joining"
    }
    /// The line under "Call link": who is in the call now, or that I am waiting at the door.
    /// Nothing until the server has answered once.
    private var statusLine: String? {
        if service.joinState == .pending { return "Waiting to be let in" }
        guard let peek else { return nil }
        return Self.whoIsHere(names: peek.names, count: peek.count)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if linkGone {
                goneState
            } else {
                backdrop
                VStack(spacing: 0) {
                    header
                    Spacer()
                    controls
                }
            }
        }
        .task { await load() }
        .task { await watchLink() }
        .onChange(of: runsPreview) { _, on in on ? preview.start() : preview.stop() }
        .onChange(of: service.lobbyError) { _, text in
            if let text { flash(text, seconds: 4) }
        }
        // The publisher, not onChange: it is heard while the service is still setting the state,
        // ahead of the next draw, so the preview's stop is queued before the call's camera starts.
        // It hands over the NEW value; `service.joinState` itself still reads the old one here.
        .onReceive(service.$joinState) { state in
            if state == .joined, !released { releaseCamera() }
        }
        .onDisappear {
            releaseCamera()
            noteTask?.cancel()
            if service.lobbyError != nil { service.lobbyError = nil }
        }
    }

    /// My camera, or my photo when it is off.
    @ViewBuilder private var backdrop: some View {
        if showsCamera {
            LobbyPreviewLayer(session: preview.session)
                .ignoresSafeArea()
        } else {
            TileBackdrop(photoUrl: me.photo).ignoresSafeArea()
            AvatarView(name: me.name, photoUrl: me.photo, size: 120)
        }
    }

    private var header: some View {
        VStack(spacing: 3) {
            Text(title)
                .font(.title3.weight(.semibold))
                .lineLimit(1)
            Label("Call link", systemImage: "link")
                .font(.subheadline)
                .opacity(0.9)
            if let line = statusLine {
                Text(line)
                    .font(.subheadline)
                    .opacity(0.9)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.top, 2)
            }
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.35), radius: 6)
        .padding(.top, 12)
        .padding(.horizontal, 24)
        .animation(.easeInOut(duration: 0.2), value: statusLine)
    }

    // The sizes below are measured from the owner's screenshot of the reference screen (2026-10-07):
    // 56pt round buttons 10pt apart, 16pt down to the bar; the bar is a capsule 44pt in from each
    // edge with 14pt of padding around two 48pt pills 8pt apart, Leave dark and Join green, and it
    // sits 22pt above the home indicator.
    private var controls: some View {
        VStack(spacing: 16) {
            if let note { noteLine(note) }
            mediaButtons
            actionBar
        }
        .padding(.bottom, 22)
        .animation(.easeInOut(duration: 0.2), value: note)
    }

    private func noteLine(_ text: String) -> some View {
        Text(text)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.black.opacity(0.6), in: Capsule())
            .padding(.horizontal, 24)
            .transition(.opacity)
    }

    /// Camera and mic. Held still while a join runs: the call goes in the way they were left
    /// when Join was tapped, also after a wait at the door.
    private var mediaButtons: some View {
        HStack(spacing: 10) {
            round(icon: showsCamera ? "video.fill" : "video.slash.fill", on: showsCamera) {
                toggleCamera()
            }
            .disabled(voiceOnly || locked)
            .opacity(voiceOnly ? 0.4 : 1)
            .accessibilityLabel(voiceOnly ? "Camera unavailable on a voice call" : (showsCamera ? "Turn camera off" : "Turn camera on"))
            round(icon: micOn ? "mic.fill" : "mic.slash.fill", on: micOn) { micOn.toggle() }
                .disabled(locked)
                .accessibilityLabel(micOn ? "Mute" : "Unmute")
        }
    }

    private var actionBar: some View {
        HStack(spacing: 8) {
            Button { leave() } label: { barLabel("Leave") }
            Button { join() } label: { joinLabel }
                .disabled(locked)
                .accessibilityLabel(joinSpoken)
        }
        .buttonStyle(.plain)
        .padding(14)
        .liquidGlass(Capsule(), interactive: false)
        .padding(.horizontal, 44)
    }

    /// The dark pill: Leave, and Close on a dead link. Dark on the glass whatever is behind it, as
    /// the reference draws it over a bright camera picture and over a dim photo alike.
    private func barLabel(_ text: String) -> some View {
        Text(text)
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(Color.black.opacity(0.4), in: Capsule())
    }

    /// Green with the word, or with a spinner while the join runs: the reference app spins its
    /// join button through both the connecting and the waiting state.
    private var joinLabel: some View {
        ZStack {
            if locked {
                ProgressView().tint(.white)
            } else {
                Text(joinTitle)
                    .font(.headline)
                    .foregroundStyle(.white)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 48)
        .background(Color.green, in: Capsule())
    }

    /// The link was revoked or never existed: say so, and the only way on is out. The reference
    /// app checks the link first too, instead of showing a normal-looking screen that cannot join.
    private var goneState: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 14) {
                Image(systemName: "link")
                    .font(.system(size: 28, weight: .semibold))
                    .frame(width: 76, height: 76)
                    .background(Color.white.opacity(0.12), in: Circle())
                    .accessibilityHidden(true)
                Text("This call link is no longer valid")
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 32)
            Spacer()
            Button { leave() } label: { barLabel("Close") }
                .buttonStyle(.plain)
                .padding(14)
                .liquidGlass(Capsule(), interactive: false)
                .padding(.horizontal, 44)
                .padding(.bottom, 22)
        }
    }

    /// White when on, dark glass when off: the screenshot's two round buttons.
    private func round(icon: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(on ? .black : .white)
                .frame(width: 56, height: 56)
                .background(on ? AnyShapeStyle(Color.white) : AnyShapeStyle(Color.black.opacity(0.45)), in: Circle())
        }
        .buttonStyle(.plain)
    }

    /// The reference app's wording for who is in the call. `names` holds a few at most; anyone
    /// past the first two is counted, and so is anyone the server sent no name for.
    private static func whoIsHere(names: [String], count: Int) -> String {
        let named = Array(names.filter { !$0.isEmpty }.prefix(2))
        let others = max(count, named.count) - named.count
        let othersText = others == 1 ? "1 other" : "\(others) others"
        switch (named.count, others) {
        case (0, 0): return "No one else is here"
        case (0, 1): return "1 person is here"
        case (0, _): return "\(others) people are here"
        case (1, 0): return "\(named[0]) is in this call"
        case (1, _): return "\(named[0]) and \(othersText) are in this call"
        case (_, 0): return "\(named[0]) and \(named[1]) are in this call"
        default: return "\(named[0]), \(named[1]) and \(othersText) are in this call"
        }
    }

    private func load() async {
        // A note left from an earlier visit is not this visit's news.
        if service.lobbyError != nil { service.lobbyError = nil }
        // The camera first, so the picture is up while the name loads.
        if await GroupCallService.cameraAllowed() { cameraReady = true } else { cameraDenied = true }
        // The server's answer (`watchLink`) carries the name and the voice mark too. This read
        // stays for when the server is not reached: the link's own document still says both.
        guard let k = CallLinkKey(text: lobby.key),
              let d = try? await Firestore.firestore().collection("callLinks").document(k.roomId)
                .getDocument().data() else { return }
        if (peek?.title ?? "").isEmpty,
           let enc = d["encName"] as? String, !enc.isEmpty, let n = k.decryptName(enc), !n.isEmpty { title = n }
        if (d["video"] as? Bool) == false { voiceOnly = true }
    }

    /// Asks the server about the link now and every 5s while this screen is up; `.task` cancels
    /// it with the screen. Not while a join runs: the join's own outcome is the news then.
    private func watchLink() async {
        while !Task.isCancelled {
            if service.joinState == .notJoined {
                let seen = await service.peekLink(key: lobby.key)
                // nil = the server was not reached: what is on screen stays. An answer that lands
                // after Join was tapped is dropped, so a join in flight never loses its screen.
                if let seen, !Task.isCancelled, !starting, service.joinState == .notJoined { apply(seen) }
                if linkGone { return }   // a dead link does not come back
            }
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }
    }

    private func apply(_ seen: GroupCallService.LobbyPeek) {
        peek = seen
        if !seen.title.isEmpty { title = seen.title }
        if !seen.video { voiceOnly = true }
    }

    private func toggleCamera() {
        if cameraDenied {
            // Asked already and refused: Settings is the only way back.
            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            return
        }
        cameraOn.toggle()
    }

    /// Shows `text` over the buttons for a few seconds and reads it to VoiceOver.
    private func flash(_ text: String, seconds: Double) {
        noteTask?.cancel()
        note = text
        UIAccessibility.post(notification: .announcement, argument: text)
        noteTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            clearNote()
        }
    }

    /// Takes the service's `lobbyError` down with the note, so the same refusal a second time
    /// is a change again and is shown again.
    private func clearNote() {
        noteTask?.cancel(); noteTask = nil
        note = nil
        if service.lobbyError != nil { service.lobbyError = nil }
    }

    /// The call starts its own camera the moment it is joined, and one camera cannot feed two
    /// capture sessions: ours lets go, and `released` keeps it from ever starting again.
    private func releaseCamera() {
        released = true
        preview.stop()
    }

    private func leave() {
        releaseCamera()
        // A join already asked for (connecting, or waiting at the door) is called off with the
        // screen. Without this it would go on with no screen and bring the call up by itself.
        if starting || service.joinState == .joining || service.joinState == .pending { service.end() }
        service.lobby = nil
    }

    private func join() {
        guard !locked, !linkGone else { return }
        // The reference app checks before it asks: a full call says so here and nothing is sent.
        if peek?.full == true {
            flash("This call is full", seconds: 3)
            return
        }
        let key = lobby.key, video = showsCamera, mic = micOn
        clearNote()
        starting = true
        // The lobby is NOT closed here any more: the service closes it once the room is up, and
        // reports a refusal through `lobbyError`. The preview keeps running until then.
        Task { @MainActor in
            // Leave tapped in the beat before this ran: there is no screen to come back to.
            if service.lobby == lobby {
                await service.joinLink(key: key, video: video, mic: mic, fromLobby: true)
            }
            starting = false
        }
    }
}

extension GroupCallService {
    /// The service's answer about a link (the plan's `LinkPeek`) under the name this screen uses.
    /// Looked up from inside the service, so it is found whether that type sits inside the
    /// service or beside it.
    typealias LobbyPeek = LinkPeek
}

/// The front camera for the preview, started and stopped off the main thread.
@MainActor
final class LobbyCameraPreview: ObservableObject {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "kulan.lobby.camera")
    private var configured = false

    func start() {
        let session = self.session
        let needsSetup = !configured
        configured = true
        queue.async {
            if needsSetup {
                session.beginConfiguration()
                session.sessionPreset = .high
                if let dev = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
                   let input = try? AVCaptureDeviceInput(device: dev), session.canAddInput(input) {
                    session.addInput(input)
                }
                session.commitConfiguration()
            }
            if !session.isRunning { session.startRunning() }
        }
    }

    func stop() {
        let session = self.session
        queue.async { if session.isRunning { session.stopRunning() } }
    }
}

/// The capture session's own preview layer, mirrored like a selfie camera.
private struct LobbyPreviewLayer: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.backgroundColor = .black
        v.previewLayer.session = session
        v.previewLayer.videoGravity = .resizeAspectFill
        return v
    }

    func updateUIView(_ v: PreviewView, context: Context) {}
}
