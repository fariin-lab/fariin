import SwiftUI
import AVFoundation
import UIKit
import Photos
import PhotosUI

// Full-screen story camera (standard story-camera style): live preview, capture, flip,
// flash, zoom levels, and a library shortcut. Hands back JPEG Data on capture/pick.
// NOTE: camera can't be exercised in CI — verify on a real device.

// MARK: - Capture session controller

final class StoryCamera: NSObject, ObservableObject, AVCapturePhotoCaptureDelegate,
                         AVCaptureFileOutputRecordingDelegate {
    let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private let movieOutput = AVCaptureMovieFileOutput()
    private var input: AVCaptureDeviceInput?
    /// Attached only when the first recording starts, never at setup. A microphone permission prompt
    /// the moment you open a camera to take a PHOTO is a prompt for something you did not ask for.
    private var audioInput: AVCaptureDeviceInput?
    private(set) var position: AVCaptureDevice.Position = .back
    @Published var torchOn = false
    @Published var denied = false   // camera access denied/restricted → the view shows a Settings prompt
    @Published var recording = false
    var onCapture: ((Data) -> Void)?
    var onVideo: ((URL) -> Void)?

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
        // `.high`, not `.photo`, because this session now does BOTH. The photo preset is tuned for
        // stills and is the wrong shape to hand a movie output; `.high` is what a camera that shoots
        // video as well is supposed to run at, and stills off it are still full quality for a story.
        session.sessionPreset = .high
        setInput(position: .back)
        if session.canAddOutput(output) { session.addOutput(output) }
        if session.canAddOutput(movieOutput) { session.addOutput(movieOutput) }
        session.commitConfiguration()
        // A story is short by nature, and a cap means a forgotten recording cannot fill the disk.
        movieOutput.maxRecordedDuration = CMTime(seconds: 60, preferredTimescale: 600)
    }

    // MARK: - Video

    func startRecording() {
        guard session.isRunning, !movieOutput.isRecording else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            self.attachAudioIfNeeded()
            if let conn = self.movieOutput.connection(with: .video) {
                if conn.isVideoRotationAngleSupported(90) { conn.videoRotationAngle = 90 }
                // The selfie camera shows you mirrored, so a video that is NOT mirrored looks like
                // somebody else the moment it plays back.
                if self.position == .front, conn.isVideoMirroringSupported { conn.isVideoMirrored = true }
            }
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("story-\(UUID().uuidString).mov")
            self.movieOutput.startRecording(to: url, recordingDelegate: self)
        }
    }

    func stopRecording() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self, self.movieOutput.isRecording else { return }
            self.movieOutput.stopRecording()
        }
    }

    private func attachAudioIfNeeded() {
        guard audioInput == nil,
              let dev = AVCaptureDevice.default(for: .audio),
              let input = try? AVCaptureDeviceInput(device: dev) else { return }
        session.beginConfiguration()
        if session.canAddInput(input) { session.addInput(input); audioInput = input }
        session.commitConfiguration()
    }

    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL,
                    from connections: [AVCaptureConnection]) {
        DispatchQueue.main.async { self.recording = true }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection], error: Error?) {
        // An error here is not always a failure: hitting the duration cap reports one and still
        // leaves a perfectly good file, which is what this key is for.
        let usable = error == nil ||
            ((error as NSError?)?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool == true)
        DispatchQueue.main.async {
            self.recording = false
            if usable { self.onVideo?(outputFileURL) }
        }
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
    /// A recorded clip, on its way to the same video editor a library video opens in.
    var onVideo: (URL) -> Void = { _ in }
    /// A finished TEXT story, already rendered to the image the pipeline posts.
    var onTextStory: (Data) -> Void = { _ in }
    /// Bottom-left. Opens the photo/album grid rather than Apple's picker, so a story can still be a
    /// VIDEO — the system picker here would hand back an image and quietly drop that.
    var onLibrary: () -> Void = {}

    /// CAMERA and TEXT are two things this ONE page can show, which is what the switch at the bottom
    /// promises. Text used to be a separate full-screen cover, so choosing it took the switch off
    /// screen and there was no way back except closing the whole thing.
    private enum Mode { case camera, text }

    @StateObject private var cam = StoryCamera()
    @State private var mode: Mode = .camera
    @State private var zoom: CGFloat = 1
    @State private var baseZoom: CGFloat = 1
    @State private var libraryThumb: UIImage?
    // Text mode's state lives HERE, not in the card, so switching to the camera and back does not
    // throw away what he typed.
    @State private var storyText = ""
    @State private var styleIndex = 0
    @State private var fontIndex = 0
    @State private var typing = false
    @State private var locked = false          // recording continues with the finger lifted
    @State private var recordSeconds = 0
    @Environment(\.scenePhase) private var scenePhase

    private let previewCorner: CGFloat = 40
    private let barHeight: CGFloat = 88

    private var hasText: Bool { !storyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                Group {
                    if mode == .camera {
                        preview
                    } else {
                        StoryTextCard(text: $storyText, styleIndex: $styleIndex,
                                      fontIndex: $fontIndex, typing: $typing,
                                      onClose: { onClose() })
                    }
                }
                // WHILE TYPING THE CARD MEETS THE KEYBOARD (owner 2026-08-03, circling the two bottom
                // corners: "left and right i see empty black"). The card normally floats with 6pt of
                // black down each side and rounded corners all round, which reads as a card. Once the
                // keyboard is up it is not floating any more, it is the top half of the screen — so
                // the side margins go and the bottom corners square off, and the colour runs into the
                // keyboard instead of leaving two black wedges beside the Aa and the tick.
                //
                // The TOP keeps its radius and its 6pt either way: that edge is under the status bar,
                // not against anything.
                .clipShape(UnevenRoundedRectangle(
                    topLeadingRadius: previewCorner,
                    bottomLeadingRadius: typing ? 0 : previewCorner,
                    bottomTrailingRadius: typing ? 0 : previewCorner,
                    topTrailingRadius: previewCorner,
                    style: .continuous))
                .padding(.horizontal, typing ? 0 : 6)
                .padding(.top, 6)
                .animation(.easeInOut(duration: 0.2), value: typing)

                // Gone while the keyboard is up, as he drew it: the card takes that space instead,
                // and the switch would otherwise be riding on top of the keyboard.
                if !typing {
                    bottomBar
                        .frame(height: barHeight)
                }
            }
        }
        // THE PAGE DOES NOT RESIZE FOR THE KEYBOARD (owner 2026-08-04: "the entire editor frame moves
        // upward and a black background appears behind the keyboard").
        //
        // SwiftUI's automatic avoidance shrinks the available height, so the card was being made
        // shorter and everything in it moved — and the space the card no longer covered was black.
        // The card now keeps the whole screen and the keyboard simply sits over its lower part;
        // inside it, the words and the two buttons lift themselves. Nothing else moves at all.
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .onAppear {
            cam.onCapture = onCapture
            cam.onVideo = onVideo
            cam.start()
            loadLibraryThumb()
        }
        .onDisappear { cam.stopRecording(); cam.stop() }
        // The clock, ticking only while there is something to count. Restarting from zero lives here
        // rather than in the gesture, so every way a recording can begin is counted the same way.
        .onChange(of: cam.recording) { _, on in
            recordSeconds = 0
            if !on { locked = false }
        }
        .task(id: "\(cam.recording)-\(recordSeconds)") {
            guard cam.recording else { return }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if cam.recording { recordSeconds += 1 }
        }
        .onChange(of: scenePhase) { _, phase in   // free the camera when backgrounded
            if phase == .active { cam.start() } else { cam.stop() }
        }
        // The camera is a power draw with nothing to show while text is on screen.
        .onChange(of: mode) { _, m in
            if m == .camera { cam.start() } else { cam.stop() }
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
                    // the reference app's second glyph there is their single/multi CAPTURE MODE
                    // (PhotoCaptureViewController.swift:989, `captureModeButton` → `didTapBatchMode`),
                    // which takes a burst and sends them together. We have no such thing, and drawing
                    // a button that does nothing is the one thing this project never does.
                    HStack(spacing: 0) {
                        Button { cam.torchOn.toggle() } label: {
                            Image(systemName: cam.torchOn ? "bolt.fill" : "bolt.slash.fill")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 46, height: 44)
                                .contentShape(Rectangle())   // the whole 46×44, not just the bolt
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

                // The lock rides BESIDE the shutter without moving it: an overlay, so the shutter
                // stays dead centre whether or not you are recording.
                shutter
                    .overlay(alignment: .trailing) {
                        if cam.recording { lockButton.offset(x: 78) }
                    }
                    .padding(.bottom, 26)
            }
            .overlay(alignment: .top) {
                if cam.recording { recordingClock.padding(.top, 18) }
            }
            .animation(.easeInOut(duration: 0.2), value: cam.recording)
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

    /// TAP TAKES A PHOTO, HOLD RECORDS, SLIDE RIGHT LOCKS — the gesture every camera in every
    /// messenger uses, and the owner's request (2026-08-03) with his own mock of the recording state.
    ///
    /// Two gestures, not one clever one. A long press starts the recording and a drag decides
    /// whether you slid far enough to lock, and the Button underneath keeps the plain tap for a
    /// photo. Trying to express all three as a single sequenced gesture is how a tap starts
    /// recording a half-second film, and it is much harder to read six months from now.
    ///
    /// STOPPING IS GUARDED ON `cam.recording`, so the drag ending after an ordinary tap — which it
    /// always does — cannot stop something that never started.
    private var shutter: some View {
        // Recording → this is the stop button, which is the whole point of the lock. Not recording →
        // an ordinary shutter. One control, two jobs, decided by what is happening.
        Button { if cam.recording { cam.stopRecording() } else { cam.capture() } } label: {
            ZStack {
                Circle().stroke(.white.opacity(0.55), lineWidth: 3).frame(width: 84, height: 84)
                if cam.recording {
                    RoundedRectangle(cornerRadius: locked ? 8 : 36, style: .continuous)
                        .fill(Color.red)
                        .frame(width: locked ? 34 : 62, height: locked ? 34 : 62)
                } else {
                    Circle().fill(.white).frame(width: 72, height: 72)
                }
            }
            .animation(.snappy(duration: 0.2), value: cam.recording)
            .animation(.snappy(duration: 0.2), value: locked)
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.3)
                .onEnded { _ in if !cam.recording { locked = false; cam.startRecording() } }
        )
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { v in
                    // Far enough right, hands free. 60pt is past anything a thumb wobbles.
                    if cam.recording, !locked, v.translation.width > 60 {
                        locked = true
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    }
                }
                .onEnded { _ in if cam.recording, !locked { cam.stopRecording() } }
        )
        .accessibilityLabel(cam.recording ? "Stop recording" : "Take photo, hold to record")
    }

    /// How long you have been recording, in the one place nothing else occupies.
    private var recordingClock: some View {
        Text(String(format: "%02d:%02d", recordSeconds / 60, recordSeconds % 60))
            .font(.system(size: 15, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 14).frame(height: 30)
            .background(Color.red, in: Capsule())
            .transition(.opacity)
    }

    /// The lock, to the right of the shutter, exactly where his mock puts it. It is a target as well
    /// as a sign: slide onto it, or tap it, and the recording keeps going without your finger.
    private var lockButton: some View {
        Button { locked = true } label: {
            Image(systemName: locked ? "lock.fill" : "lock")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 48, height: 48)
                .background(.ultraThinMaterial, in: Circle())
                .environment(\.colorScheme, .dark)
                .overlay(Circle().strokeBorder(.white.opacity(locked ? 0.9 : 0.35), lineWidth: 1.5))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Keep recording without holding")
    }

    // MARK: Black bar under the card

    @ViewBuilder private var bottomBar: some View {
        if mode == .text { textBar } else { cameraBar }
    }

    /// TEXT mode: the switch, and NEXT. No library and no flip — neither has anything to do here,
    /// and his drawing has neither.
    private var textBar: some View {
        HStack {
            Spacer(minLength: 0)
            modePicker
            Spacer(minLength: 10)
            Button {
                if let data = renderTextStory(text: storyText, styleIndex: styleIndex, fontIndex: fontIndex) {
                    onTextStory(data)
                }
            } label: {
                HStack(spacing: 4) {
                    Text("NEXT").font(.system(size: 15, weight: .bold)).kerning(0.5)
                    Image(systemName: "chevron.right").font(.system(size: 13, weight: .bold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 18).frame(height: 42)
                .background(hasText ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.white.opacity(0.18)),
                            in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!hasText)
        }
        .padding(.horizontal, 20)
    }

    private var cameraBar: some View {
        HStack {
            // While recording, the library and the flip step aside: neither can be used mid-clip,
            // and his mock has only the switch down there. The switch keeps its place rather than
            // sliding to the middle, so nothing moves under a finger that is holding the shutter.
            Button { onLibrary() } label: { libraryCard }
                .buttonStyle(.plain)
                .accessibilityLabel("Choose from library")
                .opacity(cam.recording ? 0 : 1)
                .disabled(cam.recording)
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
                    // Same fix as the X above, applied here before it is reported here: a ring drawn
                    // around a glyph is not a surface you can press.
                    .contentShape(Circle())
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
            modeLabel("CAMERA", selected: mode == .camera) { withAnimation(.snappy(duration: 0.2)) { mode = .camera } }
            modeLabel("TEXT", selected: mode == .text) { withAnimation(.snappy(duration: 0.2)) { mode = .text } }
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

    /// THE `.contentShape` IS THE WHOLE POINT OF THIS FUNCTION, not decoration (owner on 450: "the X
    /// button is not working, touch area is soo small"). `.frame(44, 44)` gives a 17pt glyph a 44pt
    /// LAYOUT slot, but it does not give it a 44pt HIT area — the taps that count are still the ones
    /// that land on the glyph itself, so the visible circle was mostly dead. `CloseXButton` in
    /// Theme.swift has carried this line since the day it was written; I left it out here.
    private func chromeIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 46, height: 46)
            .liquidGlass(Circle(), interactive: true)
            .contentShape(Circle())
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
                .contentShape(Capsule())
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
