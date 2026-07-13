import SwiftUI
import AVFoundation
import UIKit
import PhotosUI

// Full-screen story camera (Snapchat/Instagram-style): live preview, capture, flip,
// flash, zoom levels, and a library shortcut. Hands back JPEG Data on capture/pick.
// NOTE: camera can't be exercised in CI — verify on a real device.

// MARK: - Capture session controller

final class StoryCamera: NSObject, ObservableObject, AVCapturePhotoCaptureDelegate {
    let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private var input: AVCaptureDeviceInput?
    private(set) var position: AVCaptureDevice.Position = .back
    @Published var torchOn = false
    @Published var denied = false   // camera access denied/restricted → the view shows a Settings prompt
    var onCapture: ((Data) -> Void)?

    private func device(for position: AVCaptureDevice.Position, ultraWide: Bool = false) -> AVCaptureDevice? {
        if ultraWide, let uw = AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: position) { return uw }
        return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
    }

    private func setInput(position: AVCaptureDevice.Position, ultraWide: Bool = false) {
        if let input { session.removeInput(input) }
        guard let dev = device(for: position, ultraWide: ultraWide) ?? device(for: position),
              let newInput = try? AVCaptureDeviceInput(device: dev) else { return }
        if session.canAddInput(newInput) { session.addInput(newInput); input = newInput; self.position = position }
    }

    private func configureIfNeeded() {
        guard session.inputs.isEmpty else { return }
        session.beginConfiguration()
        session.sessionPreset = .photo
        setInput(position: .back)
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()
    }

    func start() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard let self else { return }
            // Surface a denial instead of silently leaving a dead black preview.
            DispatchQueue.main.async { self.denied = !granted }
            guard granted else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                self.configureIfNeeded()
                if !self.session.isRunning { self.session.startRunning() }
            }
        }
    }

    func stop() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    func flip() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            self.session.beginConfiguration()
            self.setInput(position: self.position == .back ? .front : .back)
            self.session.commitConfiguration()
        }
    }

    // .5 → ultra-wide camera (if the device has one); 1×/3× → zoom factor on the wide lens.
    func setZoom(_ level: CGFloat) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            if level < 1 {
                self.session.beginConfiguration()
                self.setInput(position: self.position, ultraWide: true)
                self.session.commitConfiguration()
                return
            }
            // ensure we're on the wide lens for 1×/3×
            if self.input?.device.deviceType == .builtInUltraWideCamera {
                self.session.beginConfiguration()
                self.setInput(position: self.position, ultraWide: false)
                self.session.commitConfiguration()
            }
            guard let dev = self.input?.device, (try? dev.lockForConfiguration()) != nil else { return }
            dev.videoZoomFactor = max(1, min(level, dev.activeFormat.videoMaxZoomFactor))
            dev.unlockForConfiguration()
        }
    }

    func capture() {
        guard session.isRunning else { return }   // don't capture before the session is ready
        let settings = AVCapturePhotoSettings()
        if output.supportedFlashModes.contains(.on) { settings.flashMode = torchOn ? .on : .off }
        if let conn = output.connection(with: .video), conn.isVideoRotationAngleSupported(90) {
            conn.videoRotationAngle = 90   // lock captured photo to portrait
        }
        output.capturePhoto(with: settings, delegate: self)
    }

    // Continuous zoom for pinch gestures (clamped to the lens range).
    func zoomContinuous(_ factor: CGFloat) {
        guard let dev = input?.device, (try? dev.lockForConfiguration()) != nil else { return }
        dev.videoZoomFactor = max(1, min(factor, dev.activeFormat.videoMaxZoomFactor))
        dev.unlockForConfiguration()
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard error == nil, let data = photo.fileDataRepresentation() else { return }
        DispatchQueue.main.async { self.onCapture?(data) }
    }
}

// MARK: - Live preview (AVCaptureVideoPreviewLayer)

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.layer.session = session
        v.layer.videoGravity = .resizeAspectFill
        return v
    }
    func updateUIView(_ uiView: PreviewView, context: Context) {}

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        override var layer: AVCaptureVideoPreviewLayer { super.layer as! AVCaptureVideoPreviewLayer }
    }
}

// MARK: - The camera UI

struct StoryCameraView: View {
    var onCapture: (Data) -> Void
    var onClose: () -> Void
    var onTextMode: () -> Void = {}

    @StateObject private var cam = StoryCamera()
    @State private var libraryItem: PhotosPickerItem?
    @State private var zoom: CGFloat = 1
    @State private var baseZoom: CGFloat = 1
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            CameraPreview(session: cam.session).ignoresSafeArea()
                .gesture(MagnificationGesture()
                    .onChanged { scale in cam.zoomContinuous(baseZoom * scale) }
                    .onEnded { scale in baseZoom = max(1, baseZoom * scale) })

            // Camera access denied/restricted → explain + route to Settings instead of a dead black screen.
            if cam.denied {
                VStack(spacing: 14) {
                    Image(systemName: "camera.fill").font(.system(size: 34)).foregroundStyle(.white.opacity(0.6))
                    Text("Camera access is off — enable it in Settings")
                        .font(.subheadline).foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.black)
                    .padding(.horizontal, 18).padding(.vertical, 9)
                    .background(.white, in: Capsule())
                }
                .padding(.horizontal, 40)
            }

            VStack {
                // Top: close + flash
                HStack {
                    Button { onClose() } label: { circleIcon("xmark") }
                    Spacer()
                    Button { cam.torchOn.toggle() } label: { circleIcon(cam.torchOn ? "bolt.fill" : "bolt.slash.fill") }
                }
                .padding(.horizontal, 16).padding(.top, 8)

                Spacer()

                // Zoom levels
                HStack(spacing: 4) {
                    zoomButton(0.5, "·5")
                    zoomButton(1, "1×")
                    zoomButton(3, "3")
                }
                .padding(5).liquidGlass(Capsule(), interactive: true)
                .animation(.easeInOut(duration: 0.2), value: zoom)   // smooth zoom-level selection

                // Shutter
                Button { cam.capture() } label: {
                    ZStack {
                        Circle().stroke(.white, lineWidth: 5).frame(width: 76, height: 76)
                        Circle().fill(.white).frame(width: 62, height: 62)
                    }
                }
                .buttonStyle(.plain)
                .padding(.top, 16).padding(.bottom, 14)

                // Bottom: library + text-story + flip
                HStack {
                    PhotosPicker(selection: $libraryItem, matching: .images) { circleIcon("photo.on.rectangle") }
                    Spacer()
                    Button { onTextMode() } label: {
                        Text("Aa").font(.system(size: 18, weight: .heavy)).foregroundStyle(.primary)
                            .frame(width: 44, height: 44).liquidGlass(Circle(), interactive: true)
                    }
                    Spacer()
                    Button { cam.flip() } label: { circleIcon("arrow.triangle.2.circlepath") }
                }
                .padding(.horizontal, 24).padding(.bottom, 16)
            }
        }
        .onAppear { cam.onCapture = onCapture; cam.start() }
        .onDisappear { cam.stop() }
        .onChange(of: scenePhase) { _, phase in   // free the camera when backgrounded
            if phase == .active { cam.start() } else { cam.stop() }
        }
        .onChange(of: libraryItem) { _, it in
            guard let it else { return }
            Task {
                if let d = try? await it.loadTransferable(type: Data.self) {
                    await MainActor.run { onCapture(d) }
                }
            }
        }
    }

    private func circleIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(.primary)
            .frame(width: 44, height: 44)
            .liquidGlass(Circle(), interactive: true)
    }

    private func zoomButton(_ level: CGFloat, _ label: String) -> some View {
        Button {
            zoom = level
            cam.setZoom(level)
        } label: {
            Text(label)
                .font(.system(size: zoom == level ? 15 : 12, weight: .semibold))
                .foregroundStyle(zoom == level ? .yellow : .white)
                .frame(width: zoom == level ? 38 : 30, height: zoom == level ? 38 : 30)
                .background(zoom == level ? AnyShapeStyle(.thinMaterial) : AnyShapeStyle(.ultraThinMaterial), in: Circle())
        }
        .buttonStyle(.plain)
    }
}
