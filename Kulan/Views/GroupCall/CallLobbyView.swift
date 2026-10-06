import SwiftUI
import AVFoundation
import FirebaseFirestore

/// ⛔ THE SCREEN BEFORE A LINK CALL — owner, 2026-10-06, with a screenshot of the reference app's
/// pre-join screen: your own camera full screen, the call's name with "Call link" under it at the
/// top, a camera and a mic button, then Leave and Join. Join enters the call the way the two
/// buttons were left. A Voice link keeps the camera off and its button dimmed.
///
/// The preview is a plain capture session, not a call track: nothing is published before Join,
/// and the session is stopped before the call starts its own camera.
struct CallLobbyView: View {
    let lobby: GroupCallService.Lobby

    @Environment(\.dismiss) private var dismiss
    @State private var title = "Kulan Call"
    @State private var voiceOnly = false
    @State private var cameraOn = true
    @State private var micOn = true
    @State private var cameraDenied = false
    @StateObject private var preview = LobbyCameraPreview()

    private var me: (name: String, photo: String?) {
        (ProfileStore.shared.me?.name ?? "You", ProfileStore.shared.me?.photoUrl)
    }
    private var showsCamera: Bool { cameraOn && !voiceOnly && !cameraDenied }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if showsCamera {
                LobbyPreviewLayer(session: preview.session)
                    .ignoresSafeArea()
            } else {
                TileBackdrop(photoUrl: me.photo).ignoresSafeArea()
                AvatarView(name: me.name, photoUrl: me.photo, size: 120)
            }
            VStack(spacing: 0) {
                VStack(spacing: 3) {
                    Text(title)
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                    Label("Call link", systemImage: "link")
                        .font(.subheadline)
                        .opacity(0.9)
                }
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.35), radius: 6)
                .padding(.top, 12)
                .padding(.horizontal, 24)
                Spacer()
                controls
            }
        }
        .task { await load() }
        .onChange(of: showsCamera) { _, on in on ? preview.start() : preview.stop() }
        .onDisappear { preview.stop() }
    }

    private var controls: some View {
        VStack(spacing: 20) {
            HStack(spacing: 18) {
                round(icon: showsCamera ? "video.fill" : "video.slash.fill", on: showsCamera) {
                    toggleCamera()
                }
                .disabled(voiceOnly)
                .opacity(voiceOnly ? 0.4 : 1)
                .accessibilityLabel(voiceOnly ? "Camera unavailable on a voice call" : (showsCamera ? "Turn camera off" : "Turn camera on"))
                round(icon: micOn ? "mic.fill" : "mic.slash.fill", on: micOn) { micOn.toggle() }
                    .accessibilityLabel(micOn ? "Mute" : "Unmute")
            }
            HStack(spacing: 12) {
                Button { leave() } label: {
                    Text("Leave")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 54)
                        .background(Color.white.opacity(0.18), in: Capsule())
                }
                Button { join() } label: {
                    Text("Join")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 54)
                        .background(Color.green, in: Capsule())
                }
            }
            .buttonStyle(.plain)
            .padding(10)
            .liquidGlass(Capsule(), interactive: false)
            .padding(.horizontal, 20)
        }
        .padding(.bottom, 12)
    }

    /// White when on, dark glass when off: the screenshot's two round buttons.
    private func round(icon: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(on ? .black : .white)
                .frame(width: 62, height: 62)
                .background(on ? AnyShapeStyle(Color.white) : AnyShapeStyle(Color.black.opacity(0.45)), in: Circle())
        }
        .buttonStyle(.plain)
    }

    private func load() async {
        // The camera first, so the picture is up while the name loads.
        if await GroupCallService.cameraAllowed() { preview.start() } else { cameraDenied = true }
        guard let k = CallLinkKey(text: lobby.key),
              let d = try? await Firestore.firestore().collection("callLinks").document(k.roomId)
                .getDocument().data() else { return }
        if let enc = d["encName"] as? String, !enc.isEmpty, let n = k.decryptName(enc), !n.isEmpty { title = n }
        if (d["video"] as? Bool) == false { voiceOnly = true }
    }

    private func toggleCamera() {
        if cameraDenied {
            // Asked already and refused: Settings is the only way back.
            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            return
        }
        cameraOn.toggle()
    }

    private func leave() {
        preview.stop()
        GroupCallService.shared.lobby = nil
    }

    private func join() {
        let key = lobby.key, video = showsCamera, mic = micOn
        preview.stop()
        GroupCallService.shared.lobby = nil
        Task { @MainActor in
            await GroupCallService.shared.joinLink(key: key, video: video, mic: mic)
        }
    }
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
