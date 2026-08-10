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
    /// ⚠️ ONE SERIAL QUEUE OWNS THE SESSION, AND THAT IS THE BLACK PREVIEW.
    ///
    /// Every one of these calls used to go to `DispatchQueue.global(qos:)`, which is CONCURRENT: two
    /// blocks submitted to it run AT THE SAME TIME on different threads. An `AVCaptureSession` may
    /// not be configured that way — Apple's own camera sample gives it a dedicated serial queue for
    /// exactly this reason — and this screen submits from six places, two of which the CAMERA / TEXT
    /// switch fires back to back.
    ///
    /// His 2026-08-10 report is that pair: TEXT dispatches `stop()`, CAMERA dispatches `start()`, and
    /// they race. Two endings, both photographed. If `stopRunning` lands after `startRunning` the
    /// session is stopped while the camera page is on screen — dead black. If instead
    /// `configureIfNeeded`'s `beginConfiguration` overlaps the stop, the session keeps its input (so
    /// the green privacy dot is LIT, which is what his screenshot shows) while the preview layer's
    /// connection never comes back — a live camera nobody can see.
    ///
    /// `configureIfNeeded`'s own `guard session.inputs.isEmpty` was unsafe for the same reason: two
    /// threads can both read "empty" before either adds anything, and configure it twice.
    ///
    /// Serial means the operations happen in the order they were asked for, which is all this ever
    /// needed. It is not a lock and it does not block the main thread.
    private let sessionQueue = DispatchQueue(label: "story.camera.session")
    private let output = AVCapturePhotoOutput()
    private let movieOutput = AVCaptureMovieFileOutput()
    private var input: AVCaptureDeviceInput?
    /// Never attached at setup: a microphone permission prompt the moment you open a camera to take
    /// a PHOTO is a prompt for something you did not ask for. But once permission EXISTS, it is
    /// attached as soon as the session is configured — see `attachAudioIfNeeded`, and the note on
    /// `startRecording` for why doing it at press time is what made holding the shutter feel heavy.
    private var audioInput: AVCaptureDeviceInput?
    private(set) var position: AVCaptureDevice.Position = .back
    /// FLASH, not torch, and the rename is the bug. It was called `torchOn` and only ever reached
    /// `AVCapturePhotoSettings.flashMode` — so it lit a photo and did precisely nothing for a video,
    /// because video has no flash at all. Video needs the TORCH, which nothing ever switched on.
    @Published var flashOn = false
    /// Whether the lens now in use can produce light at all. The front camera has neither flash nor
    /// torch on most phones, and a button that cannot do anything should not look like it can.
    @Published var hasLight = false
    @Published var denied = false   // camera access denied/restricted → the view shows a Settings prompt
    @Published var recording = false
    var onCapture: ((Data) -> Void)?
    var onVideo: ((URL) -> Void)?

    private func device(for position: AVCaptureDevice.Position, ultraWide: Bool = false) -> AVCaptureDevice? {
        if ultraWide, let uw = AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: position) { return uw }
        return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
    }

    /// ⚠️ THE OLD LENS IS NOT LET GO OF UNTIL THE NEW ONE IS IN. This removed the current input on
    /// its FIRST line and then had two ways to give up — no device, or `canAddInput` saying no — and
    /// either left the session running with no camera attached at all. `input` still pointed at the
    /// removed one, so `configureIfNeeded` (which asks whether `session.inputs` is empty, and the
    /// audio input keeps it non-empty) would never rebuild it either: black for the rest of the
    /// screen's life, through every flip and every zoom tap after it.
    ///
    /// Now the new input is built and accepted BEFORE the old one goes, and if anything refuses, the
    /// old input is put back. A failed lens change leaves the camera exactly as it was.
    private func setInput(position: AVCaptureDevice.Position, ultraWide: Bool = false) {
        guard let dev = device(for: position, ultraWide: ultraWide) ?? device(for: position),
              let newInput = try? AVCaptureDeviceInput(device: dev) else { return }
        let previous = input
        if let previous { session.removeInput(previous) }
        guard session.canAddInput(newInput) else {
            // Put back what was working. `canAddInput` was true for it a moment ago, so this
            // restores the state rather than hoping.
            if let previous, session.canAddInput(previous) { session.addInput(previous) }
            return
        }
        session.addInput(newInput)
        input = newInput
        self.position = position
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
        // ALREADY ALLOWED THE MICROPHONE? Then take it now, while nothing is happening, instead of
        // in the middle of the gesture that starts a recording. This asks for nothing: without
        // permission it is a no-op and the old press-time path still runs, so the first-ever video
        // still prompts and every one after that starts clean.
        attachAudioIfNeeded(promptIfNeeded: false)
        publishLightAvailability()
    }

    // MARK: - Video

    /// WHY THIS USED TO FEEL HEAVY. `attachAudioIfNeeded` was called from here, and it wraps a
    /// `beginConfiguration`/`commitConfiguration` pair. Reconfiguring a RUNNING capture session
    /// stalls it — the preview hitches and nothing records until it comes back — and that happened
    /// on every single press-and-hold, right under the finger. It is done at configure time now when
    /// permission already exists, so this path is nothing but "start".
    ///
    /// The flag is also raised OPTIMISTICALLY by the caller rather than waiting for
    /// `didStartRecordingTo`. The shutter has to answer the finger, not the capture pipeline.
    func startRecording() {
        guard session.isRunning, !movieOutput.isRecording else { return }
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.attachAudioIfNeeded()   // no-op after the first time; the prompt path only
            self.setTorch(self.flashOn)  // VIDEO'S FLASH IS THE TORCH, and it was never switched on
            if let conn = self.movieOutput.connection(with: .video) {
                if conn.isVideoRotationAngleSupported(90) { conn.videoRotationAngle = 90 }
                // The selfie camera shows you mirrored, so a video that is NOT mirrored looks like
                // somebody else the moment it plays back.
                if self.position == .front, conn.isVideoMirroringSupported { conn.isVideoMirrored = true }
            }
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("story-\(UUID().uuidString).mov")
            self.movieOutput.startRecording(to: url, recordingDelegate: self)
            // THE OPTIMISTIC FLAG, PUT RIGHT. The view raises `recording` on the press so the button
            // answers the finger; if the pipeline never actually opened a file, take it back down
            // rather than leave a stop button over a camera that is not recording.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self, !self.movieOutput.isRecording, self.recording else { return }
                self.recording = false
                self.setTorch(false)
            }
        }
    }

    func stopRecording() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.setTorch(false)   // never leave the lamp burning after the clip
            guard self.movieOutput.isRecording else { return }
            self.movieOutput.stopRecording()
        }
    }

    /// Answer the flash button while a clip is already running. Everything else about the flag is a
    /// setting for the NEXT shot, so this is the one case that has to reach the hardware at once.
    func applyTorchNow() {
        let want = flashOn
        sessionQueue.async { [weak self] in self?.setTorch(want) }
    }

    /// The lamp, for video. Separate from the photo flash, which is a per-shot setting on the
    /// capture request and cannot light a movie.
    private func setTorch(_ on: Bool) {
        guard let dev = input?.device, dev.hasTorch, dev.isTorchAvailable else { return }
        guard (try? dev.lockForConfiguration()) != nil else { return }
        dev.torchMode = on ? .on : .off
        dev.unlockForConfiguration()
    }

    private func publishLightAvailability() {
        let can = input?.device.hasFlash == true || input?.device.hasTorch == true
        DispatchQueue.main.async { self.hasLight = can }
    }

    /// Called twice over: once at configure time (silent — it returns immediately unless permission
    /// is already granted) and once from `startRecording`, which is the path that may prompt.
    private func attachAudioIfNeeded(promptIfNeeded: Bool = true) {
        // The silent pass. `AVCaptureDevice.default(for: .audio)` is itself what raises the prompt,
        // so the check has to come first — asking politely afterwards is asking.
        if !promptIfNeeded, AVCaptureDevice.authorizationStatus(for: .audio) != .authorized { return }
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
            self.sessionQueue.async {
                self.configureIfNeeded()
                if !self.session.isRunning { self.session.startRunning() }
            }
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            // Before the session goes, or the lamp is left burning on a camera nobody is looking
            // at — backgrounding the app mid-clip is the way to reach that.
            self.setTorch(false)
            guard self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    func flip() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            // The lamp belongs to the lens being left behind: switch it off BEFORE the swap, or it
            // stays lit on a device nothing is pointing at any more.
            self.setTorch(false)
            self.session.beginConfiguration()
            self.setInput(position: self.position == .back ? .front : .back)
            self.session.commitConfiguration()
            if self.movieOutput.isRecording { self.setTorch(self.flashOn) }
            self.publishLightAvailability()
        }
    }

    // .5 → ultra-wide camera (if the device has one); 1×/3× → zoom factor on the wide lens.
    func setZoom(_ level: CGFloat) {
        sessionQueue.async { [weak self] in
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
        // The PHOTO half of the flash: a per-shot setting on the request. The video half is the
        // torch, in `setTorch`, and it is the half that was missing.
        if output.supportedFlashModes.contains(.on) { settings.flashMode = flashOn ? .on : .off }
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

    /// How far a page sits off to the side when it is not the one being shown. A whole screen width,
    /// so the resting page is fully outside the card's clip whatever the padding is doing.
    private var pageSlide: CGFloat { UIScreen.main.bounds.width }

    /// ⚠️ ONE CURVE FOR BOTH WAYS IN. The swipe animated and the TAP DID NOT — the segmented control
    /// wrote `mode` straight through its binding, so tapping CAMERA or TEXT teleported while swiping
    /// between them slid. Same switch, two different behaviours depending on how you touched it, and
    /// the tap is the one he uses. Anything that changes `mode` goes through here now.
    private static let modeCurve: Animation = .snappy(duration: 0.25)

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                // ⚠️ BOTH PAGES STAY MOUNTED AND SLIDE. This was `if mode == .camera { preview }
                // else { card }`, and a SwiftUI if/else is not a page change, it is a REPLACEMENT:
                // the camera view is destroyed on the way to text and built again on the way back,
                // and the default transition fades one into the other — so for a quarter of a second
                // both pages are on screen at once over black. That is his "both page", and the
                // rebuild of an AVCaptureVideoPreviewLayer is the part that does not feel smooth.
                //
                // Signal moves the screen the same way the pill reads, left word on the left
                // (`didSwipeToTextComposer` / `didSwipeToCamera`), and the comment on the swipe
                // below already says so — the swipe was honest about the direction and the view was
                // not. Now the two pages sit side by side and translate, clipped by the card's own
                // shape, so nothing is created or destroyed by a mode change and the motion matches
                // the gesture that caused it.
                //
                // The session still stops when text is on screen (see `onChange(of: mode)`); what
                // stays alive is the VIEW, which costs nothing and is what made the return jump.
                ZStack {
                    preview
                        .offset(x: mode == .camera ? 0 : -pageSlide)
                    StoryTextCard(text: $storyText, styleIndex: $styleIndex,
                                  fontIndex: $fontIndex, typing: $typing,
                                  onClose: { onClose() })
                        .offset(x: mode == .text ? 0 : pageSlide)
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
                // SWIPE BETWEEN THE TWO, which is the half that was missing — tapping worked, so the
                // switch looked like a tab strip and did not behave like one.
                //
                // Signal's rule, from PhotoCaptureViewController (`didSwipeToTextComposer` /
                // `didSwipeToCamera`): swipe LEFT off the camera to reach TEXT, swipe RIGHT off the
                // text composer to come back. The screen therefore moves the same way the pill reads,
                // left word on the left. Signal refuses the swipe mid-recording; so does this.
                //
                // A FLICK, NOT A DRAG. Signal uses UISwipeGestureRecognizer, which fires once on a
                // quick directional swipe and never tracks the finger. SwiftUI has no equivalent, so
                // this is a DragGesture judged ONLY in onEnded, with a distance floor and a
                // mostly-horizontal test — otherwise a pinch or a vertical drag reads as a mode change.
                //
                // `.simultaneousGesture`, never `.gesture` or `.highPriorityGesture`: the preview
                // already carries pinch-to-zoom and the text card carries a text editor, and a
                // gesture that CLAIMS the touch eats both (kulan-scroll-gesture-rules; this exact
                // mistake has cost us a build before).
                .simultaneousGesture(
                    DragGesture(minimumDistance: 24)
                        .onEnded { v in
                            guard !typing, !cam.recording else { return }
                            let dx = v.translation.width, dy = v.translation.height
                            guard abs(dx) > 60, abs(dx) > abs(dy) * 1.5 else { return }
                            let next: Mode = dx < 0 ? .text : .camera
                            guard next != mode else { return }
                            withAnimation(Self.modeCurve) { mode = next }
                        }
                )

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
                    // NOT DRAWN AT ALL on a lens with no flash and no torch — the front camera on
                    // most phones. This project's own rule: a button that does nothing is the one
                    // thing it never draws.
                    if cam.hasLight {
                        HStack(spacing: 0) {
                            Button {
                                cam.flashOn.toggle()
                                // Mid-clip the lamp answers immediately; otherwise this is a setting
                                // that takes effect at the next shot.
                                if cam.recording { cam.applyTorchNow() }
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            } label: {
                                Image(systemName: cam.flashOn ? "bolt.fill" : "bolt.slash.fill")
                                    .font(.system(size: 17, weight: .semibold))
                                    .foregroundStyle(cam.flashOn ? .yellow : .white)
                                    .frame(width: 46, height: 44)
                                    .contentShape(Rectangle())   // the whole 46×44, not just the bolt
                            }
                            .buttonStyle(.plain)
                        }
                        .liquidGlass(Capsule(), interactive: true)
                    }
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
        // 0.22s, not 0.3. Long enough that a photo tap is never mistaken for a hold, short enough
        // that the hold does not feel like it is waiting for permission to begin — the reference
        // cameras sit around this figure and 0.3 reads as a beat of nothing.
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.22)
                .onEnded { _ in
                    guard !cam.recording else { return }
                    locked = false
                    // THE FLAG GOES UP HERE, not in the capture callback. It used to wait for
                    // `didStartRecordingTo`, which lands after the pipeline has actually opened a
                    // file — so the red square, the clock and the lock all appeared well after the
                    // finger went down and the control felt dead. The model corrects it back down
                    // if the start genuinely fails.
                    cam.recording = true
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    cam.startRecording()
                }
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

    /// ⚠️ EXACTLY ONE SWITCH, AND IT LIVES OUT HERE. His 2026-08-10 screenshot: tap TEXT and BOTH
    /// words light up at once, the pill glass under each of them, the letters faintly doubled.
    ///
    /// This was `if mode == .text { textBar } else { cameraBar }` with a `modePicker` inside EACH
    /// branch. The two branches of an `if` are two different views to SwiftUI, so changing `mode`
    /// inserts one and removes the other — and `mode` is only ever written inside
    /// `withAnimation(modeCurve)`, so that swap is a 0.25s CROSS-FADE. For those 0.25s there are two
    /// `UISegmentedControl`s alive, centred in the same ZStack, sitting exactly on top of each
    /// other: the outgoing one still selecting CAMERA, the incoming one already selecting TEXT. Two
    /// highlights, because there were two controls.
    ///
    /// Now the switch is declared once, outside the branch, so it is the SAME view before and after
    /// and it simply slides its own indicator across. Only the side controls — which really are
    /// different per mode — cross-fade.
    ///
    /// THE SWITCH IS DEAD CENTRE, and that is why this is a ZStack rather than an HStack.
    ///
    /// It used to be one HStack per mode with the side controls as siblings, so the switch sat
    /// wherever the Spacers left it: pushed left by the send button, and roughly centred in CAMERA
    /// only because the library card and the flip button happen to weigh about the same. So it
    /// JUMPED sideways when he changed tab — his two screenshots, one above the other. Centred in a
    /// ZStack with the side controls floating over it, nothing beside it can move it, whatever
    /// appears or disappears there.
    private var bottomBar: some View {
        ZStack {
            modePicker
            if mode == .text { textSideControls } else { cameraSideControls }
        }
        .padding(.horizontal, 20)
    }

    /// TEXT mode: the send button. No library and no flip — neither has anything to do here, and his
    /// drawing has neither.
    private var textSideControls: some View {
            HStack {
                Spacer(minLength: 0)
                // 40x40, the arrow and nothing else (owner 2026-08-06: "remove the NEXT text…
                // replace it with a 40x40 circular button that contains only the send icon"). The
                // word was doing no work the arrow was not already doing, and a wide pill beside a
                // capsule switch made the bottom row read as two competing bars.
                Button {
                    if let data = renderTextStory(text: storyText, styleIndex: styleIndex, fontIndex: fontIndex) {
                        onTextStory(data)
                    }
                } label: {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(hasText ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.white.opacity(0.18)),
                                    in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(StoryPressStyle())
                .disabled(!hasText)
                .accessibilityLabel("Next")
            }
    }

    /// Centred exactly as TEXT is — see the note on `bottomBar`. It also means the switch cannot
    /// drift when the library card and the flip button step aside mid-recording, which was the old
    /// comment's whole worry and was being held together by the two side controls happening to match.
    private var cameraSideControls: some View {
            HStack {
            // While recording, the library and the flip step aside: neither can be used mid-clip,
            // and his mock has only the switch down there.
            Button { onLibrary() } label: { libraryCard }
                .buttonStyle(.plain)
                .accessibilityLabel("Choose from library")
                .opacity(cam.recording ? 0 : 1)
                .disabled(cam.recording)
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

    /// THE SELECTED SEGMENT IS A PIECE OF GLASS, NOT A WHITE CAPSULE DRAWN ON GLASS (owner
    /// 2026-08-07: "this bar looks like custom, please use real Apple liquid glass, follow
    /// guidelines"). He is right about what it was. The track was real `glassEffect`, but the thing
    /// that marks the chosen word was `Capsule().fill(.white.opacity(0.22))` — an opaque wash, which
    /// is the one thing Apple's material never is, and it is what made the whole control read as
    /// moulded plastic.
    ///
    /// Apple's own moving-highlight pattern is a `GlassEffectContainer` with a shared
    /// `glassEffectID`: the highlight is a glass element in its own right, the container is what
    /// lets it MELT out of one position and into the other rather than fading in place, and it
    /// merges with the track it sits in instead of stacking a second material on top of it. That is
    /// also why `matchedGeometryEffect` is gone — two systems animating the same puck would fight,
    /// and the glass one is the one that carries the material with it.
    ///
    /// Below iOS 26 nothing here exists, so the old wash stays exactly as it was.
    /// ⚠️ 2026-08-07, HIS THIRD TIME ON THIS CONTROL: "plz dont use custom liquid glas, use real
    /// apple liquid glass, no custom, i said real apple." The API was already Apple's. What was
    /// custom was the SHAPE OF THE DESIGN: a glass track with a second glass pill sitting on it, so
    /// two materials were stacked and, on the black strip under the card where neither has anything
    /// to refract, both resolved to flat grey. That is the moulded-plastic look in his screenshot,
    /// and no amount of correct API fixes it while there are two of them.
    ///
    /// Apple's own segmented glass is ONE piece of glass: the track carries no material at all, and
    /// the selected segment is the single glass element that slides between positions. So the track
    /// is gone, the pill keeps the `GlassEffectContainer` + shared `glassEffectID` that lets it melt
    /// across, and the tint is gone with it — a tint is a wash, which is the exact thing he keeps
    /// calling custom.
    /// ⚠️ APPLE'S OWN CONTROL, NOT OURS WEARING APPLE'S MATERIAL. Fourth report on this switch:
    /// "you are not using real liqud glass for apple design use native plz."
    ///
    /// He is right, and my previous two answers both missed it. The API was Apple's both times —
    /// first a glass track with a glass pill on it, then a single glass pill — but the CONTROL was
    /// still hand-built out of two Buttons, a Namespace and a capsule we drew. On the black strip
    /// under the card, where a material has nothing behind it to refract, anything we assemble
    /// resolves to flat grey no matter which modifier paints it. That is the moulded plastic he has
    /// now photographed three times.
    ///
    /// ⚠️ FIFTH REPORT. READ SIGNAL'S SOURCE BEFORE TOUCHING THIS AGAIN — I did, and it is short.
    ///
    /// `Signal/src/ViewControllers/Photos/MediaControls.swift`, `ComposerTypeSelectionControl`. It is
    /// the same control on the same screen for the same two words, so there is no interpretation
    /// left to do:
    ///
    /// ```swift
    /// final class ComposerTypeSelectionControl: UISegmentedControl {
    ///     init() {
    ///         super.init(frame: .zero)
    ///         insertSegment(withTitle: titleText.uppercased(), at: 0, animated: false)
    ///         insertSegment(withTitle: titleCamera.uppercased(), at: 0, animated: false)
    ///         if #unavailable(iOS 26) { backgroundColor = .clear; ...clear bg + divider images... }
    ///         ...rounded 14pt font, bold when selected, secondaryLabel / label...
    ///     }
    ///     override var intrinsicContentSize: CGSize {
    ///         var size = super.intrinsicContentSize
    ///         size.width += CGFloat(8 * 2 * numberOfSegments)
    ///         size.height = 40
    ///         return size
    ///     }
    /// }
    /// ```
    ///
    /// THE ANSWER IS THE `#unavailable(iOS 26)`. Every piece of styling they do to the track is
    /// fenced OFF on 26 and later. On 26 they hand UIKit a bare `UISegmentedControl` and let it draw
    /// its own Liquid Glass, and the only things they set at all are the font and the two title
    /// colours. That is the whole difference between their bar and the moulded grey plastic he has
    /// now photographed five times.
    ///
    /// So why was a SwiftUI `Picker(.segmented)` not enough, given it is documented as the same
    /// control. Because it is not the same control: SwiftUI drives it through its own appearance
    /// path and on this screen it came out with the flat legacy track anyway. The previous note here
    /// claimed "there is nothing left of ours", and his screenshot says otherwise. UIKit is native
    /// too, and [[kulan-prefer-native-not-custom]] says to reach for it and decide rather than ask.
    ///
    /// The uppercase comes BACK, because it is Signal's, not ours: they uppercase both titles. The
    /// previous note removed it as a hand-built flourish, which was the wrong call for the same
    /// reason the rest of this was.
    private var modePicker: some View {
        // The tap goes through the SAME curve as the swipe — see `modeCurve`.
        ComposerTypeSwitch(isText: Binding(get: { mode == .text },
                                           set: { v in
            withAnimation(Self.modeCurve) { mode = v ? .text : .camera }
        }))
            // Its own intrinsic size, Signal's: the padding and the 40pt height come from the
            // control, not from a frame we impose. A width we choose is a width that has to be
            // re-chosen every time the font metric changes.
            .fixedSize()
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

/// CAMERA | TEXT, built the way Signal builds it, because five attempts at building it ourselves
/// all came out as grey plastic.
///
/// `ComposerTypeSelectionControl` in `Signal/src/ViewControllers/Photos/MediaControls.swift` is the
/// same control on the same screen for the same two words. What it does on iOS 26 is nothing: every
/// line that touches the track is fenced behind `#unavailable(iOS 26)`, so on 26 a bare
/// `UISegmentedControl` draws its own Liquid Glass and the only things set are the font and the two
/// title colours. Anything painted on the track is what turns it into a flat grey capsule, which is
/// what he has photographed five times.
///
/// The app is iOS 26 only, so their `#unavailable` branch has no equivalent here — this is their
/// iOS 26 path and nothing else.
private struct ComposerTypeSwitch: UIViewRepresentable {
    @Binding var isText: Bool

    /// Signal's intrinsic size, the half of their control we had not copied yet: 40pt tall and
    /// 8pt of extra width either side of each segment. The default ~32pt track is what made ours
    /// read smaller than the Photos album bar he referenced (2026-08-09, "make it 40px") — the
    /// GLASS itself was already right, because nothing below touches the track.
    private final class GlassSegmentedControl: UISegmentedControl {
        override var intrinsicContentSize: CGSize {
            var s = super.intrinsicContentSize
            s.width += CGFloat(8 * 2 * numberOfSegments)
            s.height = 40
            return s
        }
    }

    func makeUIView(context: Context) -> UISegmentedControl {
        // Titles UPPERCASED, which is Signal's, not a flourish of ours.
        let control = GlassSegmentedControl(items: ["CAMERA", "TEXT"])
        control.selectedSegmentIndex = isText ? 1 : 0
        // ⚠️ NOTHING IS SET ON THE TRACK. No backgroundColor, no background image, no divider image,
        // no tint. That is the entire reason this reads as glass and the last five did not.
        //
        // Rounded 14, bold when selected — their two lines, and their two colours. The composer is
        // always dark, and these are trait colours, so the trait is pinned rather than hardcoding
        // white: a hardcoded white is a restyle, and a restyled segmented control is a custom one.
        control.overrideUserInterfaceStyle = .dark
        var descriptor = UIFontDescriptor.preferredFontDescriptor(withTextStyle: .body)
        if let rounded = descriptor.withDesign(.rounded) { descriptor = rounded }
        let normal = UIFont(descriptor: descriptor, size: 14)
        let selected = descriptor.withSymbolicTraits(.traitBold).map { UIFont(descriptor: $0, size: 14) } ?? normal
        control.setTitleTextAttributes([.font: normal, .foregroundColor: UIColor.secondaryLabel], for: .normal)
        control.setTitleTextAttributes([.font: selected, .foregroundColor: UIColor.label], for: .selected)
        control.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .valueChanged)
        return control
    }

    func updateUIView(_ control: UISegmentedControl, context: Context) {
        context.coordinator.onChange = { isText = $0 }
        let want = isText ? 1 : 0
        // Only when it actually differs: writing the same index back mid-update restarts the
        // selection animation, so a swipe between modes would fight the tap that started it.
        if control.selectedSegmentIndex != want { control.selectedSegmentIndex = want }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var onChange: (Bool) -> Void = { _ in }
        @objc func changed(_ sender: UISegmentedControl) { onChange(sender.selectedSegmentIndex == 1) }
    }
}
