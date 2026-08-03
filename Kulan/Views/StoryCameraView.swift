import SwiftUI
import AVFoundation
import UIKit
import Photos
import PhotosUI

// Full-screen story camera (standard story-camera style): live preview, capture, flip,
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

/// The story camera, to the owner's reference (2026-08-03): the preview is a rounded card, the close
/// and flash controls float on it, the zoom pill and the shutter sit at its foot, and a black bar
/// underneath carries the library, the CAMERA / TEXT switch and the flip button.
///
/// It is also the FIRST thing "Add Story" opens now — the picker page it used to open is reached
/// from the library button at the bottom left, which is his instruction and the way every story
/// camera works.
struct StoryCameraView: View {
    var onCapture: (Data) -> Void
    var onClose: () -> Void
    var onTextMode: () -> Void = {}
    /// Bottom-left. Opens the photo/album grid rather than Apple's picker, so a story can still be a
    /// VIDEO — the system picker here would hand back an image and quietly drop that.
    var onLibrary: () -> Void = {}

    @StateObject private var cam = StoryCamera()
    @State private var zoom: CGFloat = 1
    @State private var baseZoom: CGFloat = 1
    @State private var libraryThumb: UIImage?
    @Environment(\.scenePhase) private var scenePhase

    private let previewCorner: CGFloat = 40
    private let barHeight: CGFloat = 88

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                preview
                    .clipShape(RoundedRectangle(cornerRadius: previewCorner, style: .continuous))
                    .padding(.horizontal, 6)
                    .padding(.top, 6)
                bottomBar
                    .frame(height: barHeight)
            }
        }
        .onAppear { cam.onCapture = onCapture; cam.start(); loadLibraryThumb() }
        .onDisappear { cam.stop() }
        .onChange(of: scenePhase) { _, phase in   // free the camera when backgrounded
            if phase == .active { cam.start() } else { cam.stop() }
        }
    }

    // MARK: Preview card

    private var preview: some View {
        ZStack {
            Color.black
            CameraPreview(session: cam.session)
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

            VStack(spacing: 0) {
                HStack(alignment: .top) {
                    Button { onClose() } label: { chromeIcon("xmark") }
                        .buttonStyle(.plain)
                    Spacer()
                    // A capsule because the reference has one, holding the flash on its own for now.
                    // Signal's second glyph there is their single/multi CAPTURE MODE
                    // (PhotoCaptureViewController.swift:989, `captureModeButton` → `didTapBatchMode`),
                    // which takes a burst and sends them together. We have no such thing, and drawing
                    // a button that does nothing is the one thing this project never does.
                    HStack(spacing: 0) {
                        Button { cam.torchOn.toggle() } label: {
                            Image(systemName: cam.torchOn ? "bolt.fill" : "bolt.slash.fill")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 46, height: 44)
                        }
                        .buttonStyle(.plain)
                    }
                    .liquidGlass(Capsule(), interactive: true)
                }
                .padding(.horizontal, 14)
                .padding(.top, 14)

                Spacer(minLength: 0)

                zoomPill
                    .padding(.bottom, 26)

                shutter
                    .padding(.bottom, 26)
            }
        }
    }

    /// Apple's own arrangement: the lenses you can switch to are small, and the one you are on shows
    /// its factor, wider and in yellow.
    private var zoomPill: some View {
        HStack(spacing: 6) {
            zoomButton(0.5, ".5")
            zoomButton(1, "1")
            zoomButton(3, "3")
        }
        .padding(5)
        .background(.ultraThinMaterial, in: Capsule())
        .environment(\.colorScheme, .dark)
        .animation(.easeInOut(duration: 0.2), value: zoom)
    }

    private var shutter: some View {
        Button { cam.capture() } label: {
            ZStack {
                Circle().stroke(.white.opacity(0.55), lineWidth: 3).frame(width: 84, height: 84)
                Circle().fill(.white).frame(width: 72, height: 72)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Take photo")
    }

    // MARK: Black bar under the card

    private var bottomBar: some View {
        HStack {
            Button { onLibrary() } label: { libraryCard }
                .buttonStyle(.plain)
                .accessibilityLabel("Choose from library")
            Spacer(minLength: 8)
            modePicker
            Spacer(minLength: 8)
            Button { cam.flip() } label: {
                // The symbol the app already used for this, not a newer one I would be guessing at:
                // a wrong SF Symbol name is a BLANK button on the device and a green build in CI.
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 46, height: 46)
                    .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 1.5))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Flip camera")
        }
        .padding(.horizontal, 20)
    }

    /// A little deck of pictures, which is what the reference draws: the newest photo in front with a
    /// white edge, one more leaning behind it. Empty until the library has been allowed — asking for
    /// the whole photo library just to draw a thumbnail would be a permission prompt for decoration.
    private var libraryCard: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(.white.opacity(0.28))
                .frame(width: 30, height: 38)
                .rotationEffect(.degrees(-12))
                .offset(x: -6)
            Group {
                if let libraryThumb {
                    Image(uiImage: libraryThumb).resizable().scaledToFill()
                } else {
                    Color.white.opacity(0.16)
                }
            }
            .frame(width: 32, height: 40)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(.white, lineWidth: 2))
        }
        .frame(width: 52, height: 46)
        .contentShape(Rectangle())
    }

    private var modePicker: some View {
        HStack(spacing: 0) {
            modeLabel("CAMERA", selected: true) {}
            modeLabel("TEXT", selected: false) { onTextMode() }
        }
        .padding(4)
        .background(.white.opacity(0.14), in: Capsule())
    }

    private func modeLabel(_ title: String, selected: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .bold))
                .kerning(0.6)
                .foregroundStyle(selected ? .white : .white.opacity(0.55))
                .padding(.horizontal, 20).frame(height: 34)
                .background(selected ? AnyShapeStyle(.white.opacity(0.22)) : AnyShapeStyle(.clear), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: Pieces

    private func chromeIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 44, height: 44)
            .liquidGlass(Circle(), interactive: true)
    }

    private func zoomButton(_ level: CGFloat, _ label: String) -> some View {
        let on = zoom == level
        return Button {
            zoom = level
            baseZoom = max(1, level)   // a pinch after tapping a lens continues from THAT lens
            cam.setZoom(level)
        } label: {
            Text(on ? "\(label)×" : label)
                .font(.system(size: on ? 14 : 13, weight: .semibold))
                .foregroundStyle(on ? .yellow : .white)
                .frame(minWidth: on ? 44 : 34, minHeight: 34)
                .background(.black.opacity(on ? 0.35 : 0.22), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    /// The newest thing in the library, for the button that opens it. Only if access has ALREADY been
    /// granted, so this screen never raises a prompt of its own.
    private func loadLibraryThumb() {
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized
                || PHPhotoLibrary.authorizationStatus(for: .readWrite) == .limited else { return }
        let opts = PHFetchOptions()
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        opts.fetchLimit = 1
        guard let asset = PHAsset.fetchAssets(with: opts).firstObject else { return }
        let req = PHImageRequestOptions()
        req.deliveryMode = .opportunistic
        req.resizeMode = .fast
        req.isNetworkAccessAllowed = false
        PHImageManager.default().requestImage(for: asset,
                                              targetSize: CGSize(width: 160, height: 200),
                                              contentMode: .aspectFill,
                                              options: req) { img, _ in
            if let img { DispatchQueue.main.async { libraryThumb = img } }
        }
    }
}
