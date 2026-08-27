import SwiftUI
import AVFoundation
// The volume-button shutter only. `AVCaptureEventInteraction` and its `AVCaptureEvent` live in
// AVKit, not AVFoundation — see `CaptureEventCatcher`.
import AVKit
import UIKit
import Photos
import PhotosUI

// Full-screen story camera (standard story-camera style): live preview, capture, flip,
// flash, zoom levels, and a library shortcut. Hands back JPEG Data on capture/pick.
// NOTE: camera can't be exercised in CI — verify on a real device.

// MARK: - Capture session controller

final class StoryCamera: NSObject, ObservableObject, AVCapturePhotoCaptureDelegate,
                         AVCaptureFileOutputRecordingDelegate,
                         AVCaptureMetadataOutputObjectsDelegate,
                         AVCaptureVideoDataOutputSampleBufferDelegate {
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

    // MARK: - Focus and exposure

    /// A QR code framed right now, as its payload. Nil the moment it leaves the frame for good.
    /// Only links this app can actually open are ever published — see `metadataOutput`.
    @Published var framedCode: URL?

    /// The blurred last frame of the previous session, drawn while the camera boots so the screen is
    /// never black. Another mainstream messenger keeps exactly this (a blurred JPEG of the last frame, written to tmp and
    /// shown as the boot placeholder); ours lives for the app's lifetime rather than on disk, which
    /// covers the case that actually looks broken — leaving the camera and coming straight back.
    @Published var bootPlaceholder: UIImage?

    private let metaOutput = AVCaptureMetadataOutput()
    private let frameOutput = AVCaptureVideoDataOutput()
    private let frameQueue = DispatchQueue(label: "story.camera.frames")
    /// The most recent frame, kept small and blurred, refreshed at most every 2 seconds — the same
    /// throttle another mainstream messenger uses, for the same reason: this exists to paper over a black screen, not to
    /// be a viewfinder, and decoding every frame to do it would cost more than it saves.
    private var lastFrameAt: CFTimeInterval = 0
    private let frameContext = CIContext(options: [.useSoftwareRenderer: false])

    /// FOCUS AND EXPOSURE AT A POINT, which is the gesture every camera has and ours had none of.
    ///
    /// Both at once and from one tap, which is what the reference app and another mainstream messenger both do
    /// (`focus(with: .autoFocus, exposureMode: .autoExpose, monitorSubjectAreaChange: true)`), rather
    /// than offering two controls for what a person thinks of as "look here".
    ///
    /// `isSubjectAreaChangeMonitoringEnabled` is the other half and it is not optional: without it a
    /// tap locks the lens on that spot for good, so walking to another room leaves the picture soft
    /// with nothing to tell the camera to try again. With it, the device posts
    /// `AVCaptureDeviceSubjectAreaDidChange` when the scene moves and `resetFocus` puts it back to
    /// continuous — see the observer in `configureIfNeeded`.
    func focus(atDevicePoint point: CGPoint) {
        sessionQueue.async { [weak self] in
            guard let dev = self?.input?.device, (try? dev.lockForConfiguration()) != nil else { return }
            if dev.isFocusPointOfInterestSupported, dev.isFocusModeSupported(.autoFocus) {
                dev.focusPointOfInterest = point
                dev.focusMode = .autoFocus
            }
            if dev.isExposurePointOfInterestSupported, dev.isExposureModeSupported(.autoExpose) {
                dev.exposurePointOfInterest = point
                dev.exposureMode = .autoExpose
            }
            dev.isSubjectAreaChangeMonitoringEnabled = true
            dev.unlockForConfiguration()
        }
    }

    /// Back to the middle, and back to continuous. Called when the scene itself changes, never from a
    /// tap: a person who has just chosen a subject has not asked for it to be forgotten.
    /// The system has taken the camera. Nothing to do but stop pretending: a recording that was
    /// running is already over as far as the pipeline is concerned, and the torch belongs to a
    /// session we no longer own.
    @objc private func sessionInterrupted(_ n: Notification) {
        sessionQueue.async { [weak self] in self?.setTorch(false) }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.recording else { return }
            self.recording = false
        }
    }

    /// ⚠️ `wantsRunning`, NOT AN UNCONDITIONAL RESTART. The interruption ending says the camera is
    /// available again, not that anybody wants it — the person may have switched to the text page
    /// while the call was up, and starting the session behind an opaque screen lights the green
    /// indicator over a preview nobody can see.
    @objc private func sessionInterruptionEnded(_ n: Notification) {
        guard wantsRunning else { return }
        sessionQueue.async { [weak self] in
            guard let self, !self.session.isRunning else { return }
            self.session.startRunning()
        }
    }

    /// A media services reset is the recoverable one and it is the common one; anything else is left
    /// alone rather than restarted in a loop.
    @objc private func sessionRuntimeError(_ n: Notification) {
        guard let err = n.userInfo?[AVCaptureSessionErrorKey] as? AVError,
              err.code == .mediaServicesWereReset, wantsRunning else { return }
        sessionQueue.async { [weak self] in
            guard let self, !self.session.isRunning else { return }
            self.session.startRunning()
        }
    }

    @objc private func subjectAreaChanged() {
        sessionQueue.async { [weak self] in
            guard let dev = self?.input?.device, (try? dev.lockForConfiguration()) != nil else { return }
            let centre = CGPoint(x: 0.5, y: 0.5)
            if dev.isFocusPointOfInterestSupported, dev.isFocusModeSupported(.continuousAutoFocus) {
                dev.focusPointOfInterest = centre
                dev.focusMode = .continuousAutoFocus
            }
            if dev.isExposurePointOfInterestSupported, dev.isExposureModeSupported(.continuousAutoExposure) {
                dev.exposurePointOfInterest = centre
                dev.exposureMode = .continuousAutoExposure
            }
            // Off again, or the reset re-arms itself and fires forever on a moving scene.
            dev.isSubjectAreaChangeMonitoringEnabled = false
            dev.unlockForConfiguration()
        }
    }

    /// How far the shutter-drag zoom may go, in the pill's units. The device's own ceiling divided by
    /// the virtual-device base, so it means the same thing the pill means, and capped at 8 because
    /// past that a hand-held phone is photographing its own shake.
    var maxDisplayedZoom: CGFloat {
        guard let dev = input?.device else { return 1 }
        let base = dev.virtualDeviceSwitchOverVideoZoomFactors.first.map { CGFloat(truncating: $0) } ?? 1
        return min(8, max(1, dev.maxAvailableVideoZoomFactor / base))
    }

    /// ⚠️ ONE VIRTUAL DEVICE FIRST, AND THAT IS WHAT REMOVES THE LENS POP.
    ///
    /// His report: tapping .5 / 1 / 3 "feels like a sudden pop… no popping, flashing, or sudden
    /// camera/lens switching, like the reference app". Two separate causes, and this is the first.
    ///
    /// Asking for `.builtInUltraWideCamera` and `.builtInWideAngleCamera` separately means .5 is a
    /// DIFFERENT PIECE OF HARDWARE from 1, so going between them tore the input out of a running
    /// session and put another one in — a reconfiguration you can see, which is the flash.
    ///
    /// `.builtInTripleCamera` / `.builtInDualWideCamera` are Apple's VIRTUAL devices: all the lenses
    /// behind one `AVCaptureDevice`, where the switchover is the system's own and is cross-faded in
    /// hardware. It is the same device Apple's Camera app and the reference app use, and it is why theirs does
    /// not flash. Nothing switches inputs any more — .5, 1 and 3 are all zoom factors on one device
    /// (see `deviceZoom`).
    ///
    /// The old pair stays as the fallback, because a phone with a single rear lens and every front
    /// camera has no virtual device to offer and must still work exactly as before.
    private func device(for position: AVCaptureDevice.Position, ultraWide: Bool = false) -> AVCaptureDevice? {
        if !ultraWide {
            for t in [AVCaptureDevice.DeviceType.builtInTripleCamera, .builtInDualWideCamera] {
                if let v = AVCaptureDevice.default(t, for: .video, position: position) { return v }
            }
        }
        if ultraWide, let uw = AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: position) { return uw }
        return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
    }

    /// The real zoom factor for a factor as the PILL WRITES IT.
    ///
    /// On a virtual device `videoZoomFactor` 1.0 is the widest lens it has, which on a triple camera
    /// is the ultra-wide — what the pill calls .5. `virtualDeviceSwitchOverVideoZoomFactors` says
    /// where the next lens takes over, and its first entry is therefore exactly what the pill calls
    /// 1×. So the whole mapping is one multiplication, and it is correct on every device without
    /// knowing which one it is: a triple answers 2 (so .5→1, 1→2, 3→6), a phone with one rear lens
    /// answers nothing and the base is 1 (so 1→1, 3→3, and .5 clamps to the widest it has).
    private func deviceZoom(_ displayed: CGFloat, on device: AVCaptureDevice? = nil) -> CGFloat {
        guard let dev = device ?? input?.device else { return max(1, displayed) }
        let base = dev.virtualDeviceSwitchOverVideoZoomFactors.first.map { CGFloat(truncating: $0) } ?? 1
        return max(dev.minAvailableVideoZoomFactor,
                   min(displayed * base, dev.maxAvailableVideoZoomFactor))
    }

    /// Where the PILL says we are. Kept here rather than only in the view because `setInput` has to
    /// re-apply it, and `setInput` runs on the session queue where the view's `@State` is unreachable.
    ///
    /// ⚠️ WITHOUT THIS THE CAMERA OPENS AT .5 WHILE THE PILL SAYS 1×. A virtual device's resting
    /// `videoZoomFactor` is 1.0, and on that device 1.0 IS the ultra-wide. Every fresh session and
    /// every flip therefore lands one lens wider than the control claims, which is a new bug the
    /// moment `device(for:)` starts returning a triple camera. Applying it at the end of every input
    /// change is what keeps the picture and the pill saying the same thing.
    private var displayedZoom: CGFloat = 1

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
        // THE NEW LENS STARTS WHERE THE PILL SAYS, not at the device's resting 1.0 — see
        // `displayedZoom`. A front camera has no virtual device, so this resolves to 1.0 there and
        // costs nothing; on a triple camera it is the difference between opening at 1x and opening
        // at .5x with the control lit on 1x.
        if (try? dev.lockForConfiguration()) != nil {
            dev.videoZoomFactor = deviceZoom(displayedZoom, on: dev)
            dev.unlockForConfiguration()
        }
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
        // ⚠️ EVERY ONE OF THESE IS OPTIONAL, AND THE GUARDS ARE THE POINT. A movie output and a video
        // data output can refuse to share a session on some configurations, and a session that
        // refuses to configure is a black camera. Each of the two additions below is asked for
        // politely and simply does not happen if the answer is no: the QR chip and the boot
        // placeholder are both features you would not miss, and neither is worth the camera itself.
        if session.canAddOutput(metaOutput) {
            session.addOutput(metaOutput)
            metaOutput.setMetadataObjectsDelegate(self, queue: .main)
            // AFTER `addOutput`, never before: the available types are empty until the output belongs
            // to a session, and assigning a type that is not available raises.
            if metaOutput.availableMetadataObjectTypes.contains(.qr) {
                metaOutput.metadataObjectTypes = [.qr]
            }
        }
        if session.canAddOutput(frameOutput) {
            frameOutput.alwaysDiscardsLateVideoFrames = true
            frameOutput.setSampleBufferDelegate(self, queue: frameQueue)
            session.addOutput(frameOutput)
        }
        session.commitConfiguration()
        // The scene moved, so whatever a tap chose is no longer what is in front of the lens. One
        // registration for the life of the camera; the device it names changes with every flip, so it
        // is deliberately not scoped to an object.
        NotificationCenter.default.addObserver(
            self, selector: #selector(subjectAreaChanged),
            name: AVCaptureDevice.subjectAreaDidChangeNotification, object: nil)
        // ⛔ THE SESSION CAN BE TAKEN AWAY WITHOUT THE APP EVER LEAVING THE SCREEN, and until these
        // three registrations existed nothing brought it back. An incoming call is the everyday
        // case: the banner does not change the scene phase, so neither of the two handlers that
        // call `start()` fires, iOS stops the session, and both capture entry points then dead-end
        // on their own `session.isRunning` guards — a frozen preview under a shutter that answers
        // taps and does nothing, for good, until the person leaves the page.
        NotificationCenter.default.addObserver(
            self, selector: #selector(sessionInterrupted(_:)),
            name: AVCaptureSession.wasInterruptedNotification, object: session)
        NotificationCenter.default.addObserver(
            self, selector: #selector(sessionInterruptionEnded(_:)),
            name: AVCaptureSession.interruptionEndedNotification, object: session)
        NotificationCenter.default.addObserver(
            self, selector: #selector(sessionRuntimeError(_:)),
            name: AVCaptureSession.runtimeErrorNotification, object: session)
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
        // THE FRONT CAMERA HAS A LAMP AFTER ALL — the screen. Without this line the flash button is
        // hidden on the selfie camera (no hardware flash, no torch), so the screen flash added for it
        // could never be switched on and would have been dead code. See `needsScreenFlash`.
        let can = input?.device.hasFlash == true || input?.device.hasTorch == true || position == .front
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

    // MARK: - QR in the frame

    /// ⚠️ ONLY LINKS THIS APP CAN OPEN, which is another mainstream messenger's rule (it filters to `t.me/…` and ignores
    /// everything else) and it is the difference between a feature and a nuisance. A general QR
    /// reader on a story camera would offer to open a stranger's website every time a poster drifts
    /// through the frame; this offers a Fariin profile and nothing else.
    ///
    /// Published on the main queue because the delegate is set with `queue: .main` — a `@Published`
    /// write from anywhere else would be a purple runtime warning at best.
    func metadataOutput(_ output: AVCaptureMetadataOutput,
                        didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        let found = metadataObjects
            .compactMap { $0 as? AVMetadataMachineReadableCodeObject }
            .compactMap(\.stringValue)
            .compactMap { Self.openableLink(from: $0) }
            .first
        // Nil is only written when the code has genuinely gone: a QR wobbling at the edge of
        // detection would otherwise flicker the chip on and off several times a second.
        if let found {
            if framedCode != found { framedCode = found }
        } else if framedCode != nil, metadataObjects.isEmpty {
            framedCode = nil
        }
    }

    /// A profile link this build knows how to open, or nil. Accepts the app's own scheme and the
    /// website's profile path, which are the two shapes a Fariin profile QR can be.
    static func openableLink(from raw: String) -> URL? {
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        if url.scheme == "kulan" { return url }
        guard let host = url.host?.lowercased(),
              host == "fariin.com" || host == "www.fariin.com" else { return nil }
        // `/u/<handle>` is the profile route the app already resolves; anything else on the domain
        // is a web page and not ours to open.
        let parts = url.path.split(separator: "/")
        guard parts.count == 2, parts[0] == "u" else { return nil }
        return URL(string: "kulan://u/\(parts[1])")
    }

    // MARK: - The last frame, for the boot placeholder and the flip

    /// A small blurred copy of what the camera can see, refreshed at most every two seconds.
    ///
    /// It costs one downscale and one blur per two seconds, on a background queue, and it buys two
    /// things that both read as polish: a picture instead of black while the session starts, and
    /// something to hold over the preview while the lens is being swapped.
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        let now = CACurrentMediaTime()
        guard now - lastFrameAt > 2, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastFrameAt = now
        let ci = CIImage(cvPixelBuffer: buffer)
        // Downscaled FIRST and then blurred: a gaussian over a full-size frame is many times the
        // work for a picture that is about to be shown at a fortieth of the detail.
        let small = ci.transformed(by: CGAffineTransform(scaleX: 0.08, y: 0.08))
        guard let blurred = CIFilter(name: "CIGaussianBlur",
                                     parameters: [kCIInputImageKey: small, kCIInputRadiusKey: 3])?.outputImage,
              let cg = frameContext.createCGImage(blurred, from: small.extent) else { return }
        // The preview is mirrored for the front camera and the raw buffer is not, so a placeholder
        // taken on the front camera would be a reversed picture of the person looking at it.
        let orientation: UIImage.Orientation = position == .front ? .leftMirrored : .right
        let image = UIImage(cgImage: cg, scale: 1, orientation: orientation)
        DispatchQueue.main.async { [weak self] in self?.bootPlaceholder = image }
    }

    /// ⚠️ WHETHER THE CAMERA IS MEANT TO BE RUNNING, WHICH IS NOT THE SAME QUESTION AS WHETHER IT IS.
    /// The system stops the session on its own for an incoming call, Siri, another app taking the
    /// camera, or a media services reset, and only this flag can say whether we should take it back.
    /// Without it an interruption handler cannot tell "the call ended, resume" from "the person is on
    /// the text page and asked for the camera to be off".
    private var wantsRunning = false

    func start() {
        wantsRunning = true
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
        wantsRunning = false
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
        // Raised BEFORE the queue hop, so the cover is already on screen by the time the session
        // starts tearing the input out — dispatching first would show the cut it exists to hide.
        switching = true
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
            // The new lens needs a beat to produce its first frame; lifting the cover the instant the
            // session commits would uncover a black layer, which is the cut with extra steps.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { self.switching = false }
        }
    }

    /// TAP A LENS AND THE PICTURE TRAVELS THERE — it does not arrive.
    ///
    /// The second half of his zoom report. This assigned `videoZoomFactor` outright, which is an
    /// instant cut: 1× to 3× was one frame wide and one frame tight with nothing between them, and
    /// no amount of smoothing on the SwiftUI side can help because the pop is in the video itself.
    ///
    /// `ramp(toVideoZoomFactor:withRate:)` is AVFoundation's animated zoom and it is what the reference app
    /// uses (their zoom-change handler calling `ramp`). The rate is in STOPS PER SECOND, so it is geometric:
    /// the same rate covers .5→1 and 1→3 in proportionate time, which is why a single number feels
    /// right in both directions rather than fast one way and slow the other. 4.0 lands a lens change
    /// in about a quarter of a second.
    ///
    /// ⚠️ NO `beginConfiguration` ANYWHERE IN HERE ANY MORE. Swapping the input was the flash, and
    /// with a virtual device there is nothing to swap — see `device(for:)`. A phone that only has
    /// the plain wide lens simply ramps within it; it never had a .5 to give.
    func setZoom(_ level: CGFloat) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            // A DEVICE THAT CANNOT DO IT IN ONE STILL SWAPS, because the fallback path is a phone
            // with two separate rear cameras and no virtual one. `virtualDeviceSwitchOverVideoZoom-
            // Factors` is empty there, so this is the same test as "is the mapping meaningful".
            let virtual = !(self.input?.device.virtualDeviceSwitchOverVideoZoomFactors.isEmpty ?? true)
            if !virtual {
                if level < 1, self.input?.device.deviceType != .builtInUltraWideCamera {
                    self.session.beginConfiguration()
                    self.setInput(position: self.position, ultraWide: true)
                    self.session.commitConfiguration()
                    return
                }
                if level >= 1, self.input?.device.deviceType == .builtInUltraWideCamera {
                    self.session.beginConfiguration()
                    self.setInput(position: self.position, ultraWide: false)
                    self.session.commitConfiguration()
                }
            }
            self.displayedZoom = level
            let target = self.deviceZoom(level)
            guard let dev = self.input?.device, (try? dev.lockForConfiguration()) != nil else { return }
            dev.cancelVideoZoomRamp()      // a second tap re-aims from where the picture IS
            dev.ramp(toVideoZoomFactor: target, withRate: 4.0)
            dev.unlockForConfiguration()
        }
    }

    /// TRUE for the moment a lens change is in flight, so the view can hold something over the
    /// preview instead of letting the picture cut. Another mainstream messenger covers the same window with a snapshot
    /// and a blur; ours is the blur, over the frame the preview layer is still showing.
    @Published var switching = false

    /// Does THIS lens need the screen to light the shot? The front camera has no flash on any phone
    /// we ship to, so with the flash switched on the only light available is the display itself —
    /// which is exactly what another mainstream messenger does (the reference implementation's front-flash overlay plus a brightness
    /// ramp). The view owns the overlay and the brightness; this is the question it asks.
    var needsScreenFlash: Bool { flashOn && position == .front && input?.device.hasFlash != true }

    func capture() {
        guard session.isRunning else { return }   // don't capture before the session is ready
        let settings = AVCapturePhotoSettings()
        // The PHOTO half of the flash: a per-shot setting on the request. The video half is the
        // torch, in `setTorch`, and it is the half that was missing.
        if output.supportedFlashModes.contains(.on) { settings.flashMode = flashOn ? .on : .off }
        if let conn = output.connection(with: .video) {
            if conn.isVideoRotationAngleSupported(90) { conn.videoRotationAngle = 90 }   // portrait
            // ⚠️ THE SAME MIRROR THE VIDEO HALF HAS ALWAYS SET, AND THE STILL WAS THE ONE THING IN
            // THE WHOLE FLOW WITHOUT IT. The preview layer mirrors the front camera by itself and
            // `startRecording` mirrors the movie connection on purpose, so a tapped photo came out
            // reversed against both — most visible on the frozen shot, which is the un-mirrored file
            // drawn over the mirrored preview, so the picture flipped at the moment of the handover.
            if conn.isVideoMirroringSupported { conn.isVideoMirrored = (position == .front) }
        }
        output.capturePhoto(with: settings, delegate: self)
    }

    /// Continuous zoom for pinch gestures, in the SAME units the pill speaks — a pinch and a tap
    /// that land on 3 must put the picture in the same place, and before this one meant the device's
    /// factor and the other meant the pill's.
    ///
    /// Assigned rather than ramped, deliberately: the finger IS the animation here, and a ramp under
    /// a live gesture fights it. The ramp belongs to the taps, which have no finger to follow.
    func zoomContinuous(_ displayed: CGFloat) {
        guard let dev = input?.device, (try? dev.lockForConfiguration()) != nil else { return }
        displayedZoom = displayed
        dev.cancelVideoZoomRamp()   // a pinch during a tap's ramp takes over cleanly
        dev.videoZoomFactor = deviceZoom(displayed)
        dev.unlockForConfiguration()
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard error == nil, let data = photo.fileDataRepresentation() else { return }
        DispatchQueue.main.async { self.onCapture?(data) }
    }
}

// MARK: - The focus reticle

/// Apple's own shape for "the camera is looking here": a thin square that arrives a little large,
/// settles, holds, and fades. It is given a fresh identity on every tap (`.id(focusShownAt)`), so a
/// second tap restarts the animation instead of inheriting the first one's half-faded state.
private struct FocusReticle: View {
    @State private var scale: CGFloat = 1.35
    @State private var shown = true

    var body: some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .stroke(Color.yellow, lineWidth: 1.5)
            .frame(width: 74, height: 74)
            .overlay(alignment: .leading) { tick.offset(x: -1) }
            .overlay(alignment: .trailing) { tick.offset(x: 1) }
            .scaleEffect(scale)
            .opacity(shown ? 1 : 0)
            .onAppear {
                withAnimation(.easeOut(duration: 0.2)) { scale = 1 }
                // Held long enough to be read, then gone on its own. Nothing clears it: the view
                // simply stops drawing, which is why there is no state to leak.
                withAnimation(.easeInOut(duration: 0.35).delay(1.1)) { shown = false }
            }
    }

    private var tick: some View {
        Rectangle().fill(Color.yellow).frame(width: 6, height: 1.5)
    }
}

// MARK: - The volume buttons, as a shutter

/// PRESS FOR A PHOTO, HOLD FOR A VIDEO — the same rule as the on-screen shutter, on the buttons
/// people actually brace the phone with. Both reference cameras have it.
///
/// `AVCaptureEventInteraction` is the public API for this and the only one that is allowed: reading
/// the volume keys by observing audio session changes is the old trick and it is rejected. It hands
/// over a press phase, so the tap-versus-hold decision is ours to make, and it matches the shutter's
/// own 0.22s so the two controls cannot disagree about what a hold is.
private struct CaptureEventCatcher: UIViewRepresentable {
    var onPhoto: () -> Void
    var onHoldStart: () -> Void
    var onHoldEnd: () -> Void

    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.isUserInteractionEnabled = false   // it is a listener, not a control
        let interaction = AVCaptureEventInteraction { event in
            context.coordinator.handle(event)
        }
        v.addInteraction(interaction)
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onPhoto = onPhoto
        context.coordinator.onHoldStart = onHoldStart
        context.coordinator.onHoldEnd = onHoldEnd
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var onPhoto: () -> Void = {}
        var onHoldStart: () -> Void = {}
        var onHoldEnd: () -> Void = {}
        private var holdTimer: DispatchWorkItem?
        private var holding = false

        func handle(_ event: AVCaptureEvent) {
            switch event.phase {
            case .began:
                holding = false
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.holding = true
                    self.onHoldStart()
                }
                holdTimer = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: work)
            case .ended:
                holdTimer?.cancel()
                holdTimer = nil
                // A press that never became a hold is a photo; one that did is a recording ending.
                if holding { onHoldEnd() } else { onPhoto() }
                holding = false
            case .cancelled:
                holdTimer?.cancel()
                holdTimer = nil
                if holding { onHoldEnd() }
                holding = false
            @unknown default:
                break
            }
        }
    }
}

// MARK: - Live preview (AVCaptureVideoPreviewLayer)

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    /// A tap, reported as BOTH points: where the lens should look (0-1 in the device's own space) and
    /// where the finger landed in this view (for the reticle).
    ///
    /// ⚠️ THE CONVERSION CAN ONLY HAPPEN HERE. `captureDevicePointConverted(fromLayerPoint:)` belongs
    /// to the preview layer, and the layer knows things nothing else does: the video gravity, the
    /// crop the aspect fill is applying, and the mirroring on the front camera. A SwiftUI gesture
    /// outside this view would have to reinvent all three and would be wrong on every phone whose
    /// preview is not exactly the sensor's shape.
    var onTapToFocus: ((_ devicePoint: CGPoint, _ viewPoint: CGPoint) -> Void)?
    /// Double tap flips the camera. It lives HERE rather than as a SwiftUI `.onTapGesture(count: 2)`
    /// so the two taps can be arbitrated properly — see `require(toFail:)` below.
    var onDoubleTap: (() -> Void)?

    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.layer.session = session
        v.layer.videoGravity = .resizeAspectFill
        let double = UITapGestureRecognizer(target: context.coordinator,
                                            action: #selector(Coordinator.handleDouble(_:)))
        double.numberOfTapsRequired = 2
        let single = UITapGestureRecognizer(target: context.coordinator,
                                            action: #selector(Coordinator.handleSingle(_:)))
        // ⚠️ THE FOCUS TAP MUST LOSE TO THE FLIP, and this is the only way to say it properly. The reference app
        // wires exactly this pair (their focus-tap gesture requiring their camera-flip gesture to
        // fail). Without it a double-tap-to-flip also drops a focus reticle on the way past — and
        // doing it with a timer instead lands the focus AFTER the flip, on the other camera.
        single.require(toFail: double)
        v.addGestureRecognizer(double)
        v.addGestureRecognizer(single)
        context.coordinator.view = v
        return v
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        context.coordinator.onTap = onTapToFocus
        context.coordinator.onDouble = onDoubleTap
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        weak var view: PreviewView?
        var onTap: ((CGPoint, CGPoint) -> Void)?
        var onDouble: (() -> Void)?

        @objc func handleSingle(_ g: UITapGestureRecognizer) {
            guard let view else { return }
            let point = g.location(in: view)
            onTap?(view.layer.captureDevicePointConverted(fromLayerPoint: point), point)
        }

        @objc func handleDouble(_ g: UITapGestureRecognizer) { onDouble?() }
    }

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
    /// ⚠️ THE TAP AREAS TRAVEL WITH THE PICTURE. A text story with a link is a flat JPEG like any
    /// other, so the rectangle the card landed on has to go beside it or the link is a photograph of
    /// a card. Same channel a photo story's Link sticker already uses — see `StoryTapTarget`.
    var onTextStory: (Data, [StoryTapTarget]) -> Void = { _, _ in }
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
    /// The one link this status carries. Lives here rather than in the card because it is part of
    /// what gets posted, and this is the page that posts. See `StoryTextLink`.
    @State private var storyLink: StoryTextLink?
    @State private var styleIndex = 0
    @State private var fontIndex = 0
    @State private var typing = false
    @State private var locked = false          // recording continues with the finger lifted
    @State private var recordSeconds = 0
    @Environment(\.scenePhase) private var scenePhase

    /// Where the last focus tap landed, in the preview's own coordinates, and when — the `id` on the
    /// reticle so a second tap restarts the animation rather than joining the first one's.
    @State private var focusPoint: CGPoint?
    @State private var focusShownAt = Date.distantPast
    /// The screen-flash overlay for the front camera, and the brightness to put back afterwards.
    @State private var screenFlash = false
    @State private var brightnessBeforeFlash: CGFloat?
    /// How far the phone is turned, for the controls only — the preview itself never rotates.
    @State private var deviceTilt: Angle = .zero
    /// The zoom the shutter drag started from, so an upward drag ramps from where the picture WAS
    /// rather than from 1× every time.
    @State private var zoomAtRecordStart: CGFloat = 1
    // ⛔ THE PULL-DOWN IS GONE — owner, 2026-08-24: "story camera scroll down, now I need
    // remove please", with the preview dragged halfway down the screen and black above it.
    //
    // What lived here was `dismissY` / `dismissActive`: a downward drag that carried the whole camera
    // with the finger and closed it past 200pt. The ✕ is the way out now, and the door's own
    // transition owns the closing animation — a second way to leave, with its own geometry, is what
    // put the preview in the middle of a black screen in his shot.
    //
    // ⚠️ THE GESTURE ITSELF STAYS, because it is not only a dismissal: the same recognizer carries
    // swipe-UP-to-library and the sideways CAMERA/TEXT switch. Only the downward branch is cut.
    /// How close the finger is to locking the recording, 0 to 1. Drives the lock's own growth so the
    /// gesture can be FELT before it completes.
    @State private var lockProgress: CGFloat = 0
    /// THE LOCK WAS SET BY THE TOUCH THAT IS ENDING RIGHT NOW — his 2026-08-16 report, "slide onto
    /// the lock, let go, and it stops anyway".
    ///
    /// A release over the shutter means two opposite things depending on how it got there, and the
    /// only thing that tells them apart is whether THIS touch is the one that locked: the tail of a
    /// hold-and-slide must leave the recording running, while a fresh tap on the same control is the
    /// stop button being pressed. Raised where the slide latches, lowered when that touch ends.
    @State private var lockedByThisTouch = false

    private let previewCorner: CGFloat = 40
    private let barHeight: CGFloat = 88

    /// THE HANDOVER TO THE EDITOR, WHICH USED TO BE A SLIDE.
    ///
    /// His report: take a photo and the editor "slides up from the bottom" — his second screenshot
    /// caught it mid-slide, camera on top and the editor's rounded card climbing in underneath.
    /// That slide is not ours: `.fullScreenCover` is a UIKit modal and `.coverVertical` is what a
    /// modal does. Nothing in this file asked for it and nothing here could style it.
    ///
    /// What he asked for is another mainstream messenger's: the camera's buttons go, the picture stays where it is, the
    /// editor's buttons arrive. Three steps that are all about CHROME, and the picture never moves —
    /// so the fix is to stop moving anything and animate only the things that actually change.
    ///
    ///   1. `frozenShot` pins the captured frame inside the card the moment it exists, so the live
    ///      preview cannot show one more frame of a scene the photo is no longer of.
    ///   2. `handingOver` fades every camera control out over 0.22s, on the still.
    ///   3. The cover is then raised with its animation disabled (see `AddStorySheet`), so it
    ///      REPLACES rather than slides, and the editor fades its own controls in over the picture.
    ///
    /// A recording ends the same way — his "dont forget is i reacord video use same Transaction" —
    /// minus the still, because the clip's own first frame is what the video editor opens on.
    @State private var handingOver = false
    @State private var frozenShot: UIImage?

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
            // ⚠️ SOLID BLACK, NEVER THINNED. The wall used to fade as the card travelled, meaning to
            // show "what is behind the camera" — but this is a `fullScreenCover`, and a .fullScreen
            // modal REMOVES the presenting screen from the window once it is up. There was nothing
            // behind the wall but the hosting controller's flat systemBackground, so a thinned black
            // over it rendered as a featureless GREY wall — his 2026-08-11 screenshot exactly.
            // The reference app's own story camera (presented full-screen from
            // its own story controller) drags over plain black for the same structural reason; only
            // their chat-list camera, presented over the existing screen, reveals the real screen. Black is
            // the honest floor here, and it is also their look.
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                // ⚠️ BOTH PAGES STAY MOUNTED AND SLIDE. This was `if mode == .camera { preview }
                // else { card }`, and a SwiftUI if/else is not a page change, it is a REPLACEMENT:
                // the camera view is destroyed on the way to text and built again on the way back,
                // and the default transition fades one into the other — so for a quarter of a second
                // both pages are on screen at once over black. That is his "both page", and the
                // rebuild of an AVCaptureVideoPreviewLayer is the part that does not feel smooth.
                //
                // The reference app moves the screen the same way the pill reads, left word on the left
                // (their text-composer / camera swipe handlers), and the comment on the swipe
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
                                  fontIndex: $fontIndex, typing: $typing, link: $storyLink,
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
                // ⚠️ THE CARD IS THE SPACE IT WAS GIVEN, WHATEVER IS INSIDE IT. Both pages stay
                // mounted (see above), so ANY child of either one that reports more than it was
                // offered — a fill image, a representable with an intrinsic size — silently becomes
                // the card's size, and the bar below inherits the same wrong width. That is his "top
                // is entering status bar, right side is entering right screen angel but left side is
                // oky": a card wider and taller than the screen, hanging off the corners it was not
                // anchored to.
                //
                // This is the fence rather than a second cure: the picture above is fixed at its
                // source, and this makes the next one impossible. `maxWidth`/`maxHeight` .infinity
                // accepts exactly the proposal and centres anything oversized inside it, and the
                // clip below then cuts it at the card's edge.
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(UnevenRoundedRectangle(
                    topLeadingRadius: previewCorner,
                    bottomLeadingRadius: typing ? 0 : previewCorner,
                    bottomTrailingRadius: typing ? 0 : previewCorner,
                    topTrailingRadius: previewCorner,
                    style: .continuous))
                // ⚠️ NO SIDE MARGINS AT ALL NOW — his 2026-08-16 report on both pages: "camera page
                // and text page left and right is not tucking… i see space."
                //
                // This was 6pt of black down each side at rest, dropped only while the keyboard was
                // up. That was his OWN 2026-08-03 fix ("left and right i see empty black") applied to
                // the state he was in when he reported it, and the same complaint has come back for
                // the state he was not: a card that floats 6pt in from the screen also holds its
                // rounded corners 6pt in from the phone's, so the two curves never meet and the
                // corner shows a black wedge between them. Second report, so the margin goes rather
                // than the state it applies to.
                //
                // The TOP keeps its 6pt: that edge sits under the status bar and is not against
                // anything, which is the one place a gap is the design rather than a leak.
                .padding(.top, 6)
                // ⚠️ THE KEYBOARD'S OWN CURVE AND DURATION, MATCHING THE CARD'S. It was
                // `.easeInOut(duration: 0.2)` against the card's `.easeOut(duration: 0.22)`, and
                // this one changes the card's WIDTH by 12pt while that one moves its contents.
                // Two clocks over one subtree started by one event, so for a fifth of a second the
                // card's edges and everything centred inside them were moving to different tunes —
                // and a `TextField` whose content changes on every keystroke re-enters both. The
                // reference app has one animation here, taking the keyboard's duration and curve, and its
                // composer's frame does not change at all.
                .animation(.easeOut(duration: 0.22), value: typing)
                // SWIPE BETWEEN THE TWO, which is the half that was missing — tapping worked, so the
                // switch looked like a tab strip and did not behave like one.
                //
                // The reference app's rule, from its own capture view controller (its text-composer /
                // camera swipe handlers): swipe LEFT off the camera to reach TEXT, swipe RIGHT off the
                // text composer to come back. The screen therefore moves the same way the pill reads,
                // left word on the left. The reference app refuses the swipe mid-recording; so does this.
                //
                // A FLICK, NOT A DRAG. The reference app uses UISwipeGestureRecognizer, which fires once on a
                // quick directional swipe and never tracks the finger. SwiftUI has no equivalent, so
                // this is a DragGesture judged ONLY in onEnded, with a distance floor and a
                // mostly-horizontal test — otherwise a pinch or a vertical drag reads as a mode change.
                //
                // `.simultaneousGesture`, never `.gesture` or `.highPriorityGesture`: the preview
                // already carries pinch-to-zoom and the text card carries a text editor, and a
                // gesture that CLAIMS the touch eats both (kulan-scroll-gesture-rules; this exact
                // mistake has cost us a build before).
                .simultaneousGesture(
                    // `.global` is kept, though the bug it was added for is gone with the
                    // pull-down. It was there because a `DragGesture` measures in its own view's
                    // LOCAL space, and this gesture's view was inside the very stack the dismissal
                    // offset moved — so the drag moved the ruler it was measured with and the camera
                    // vibrated under the finger (his 2026-08-12 "shakes/jitters"). Nothing is offset
                    // by this gesture now, so local space would behave; window space is simply the
                    // honest one to measure a finger in, and changing it would be churn.
                    DragGesture(minimumDistance: 24, coordinateSpace: .global)
                        // Nothing to track while the finger is down any more — the dismissal
                        // was the only part of this gesture that followed the finger live. The
                        // library swipe and the mode switch are both judged at the release.
                        .onEnded { v in
                            guard !typing, !cam.recording else { return }
                            let dx = v.translation.width, dy = v.translation.height
                            // VERTICAL FIRST, and only when it is clearly vertical. Both reference
                            // cameras put the gallery above and the exit below, and reading the axes
                            // in one place is what stops a lazy diagonal doing both.
                            if abs(dy) > 60, abs(dy) > abs(dx) * 1.5 {
                                guard mode == .camera else { return }
                                if dy < 0 { onLibrary() }
                                return
                            }
                            guard abs(dx) > 60, abs(dx) > abs(dy) * 1.5 else { return }
                            let next: Mode = dx < 0 ? .text : .camera
                            guard next != mode else { return }
                            withAnimation(Self.modeCurve) { mode = next }
                        }
                )

                // Invisible while the keyboard is up, as he drew it — the switch would otherwise be
                // riding on top of the keyboard.
                //
                // ⚠️ HIDDEN, NOT REMOVED FROM THE STACK, AND THAT IS HIS "THE PAGE ZOOMS IN".
                //
                // This was `if !typing { bottomBar }`. Taking the bar out gives its 88pt back to the
                // card AND makes the `VStack` re-centre what is left, so the card grew by 88 and its
                // top edge slid up by about half of that, under the status bar, on the frame the
                // keyboard opened. The card is a flat colour with centred words, so a frame that
                // changes size reads as the whole page being zoomed.
                //
                // Reserving the space costs nothing to look at: with the page not resizing for the
                // keyboard (see below), the card's bottom edge is behind the keyboard either way, so
                // the 88pt was never visible while typing. What it buys is that the card's frame is
                // the SAME rectangle before and after — nothing moves except what lifts itself.
                bottomBar
                    .frame(height: barHeight)
                    .opacity(typing || handingOver ? 0 : 1)
                    .allowsHitTesting(!typing)
            }
            // THE WHOLE CAMERA RIDES THE FINGER — translation ONLY. The reference app's camera dismiss never
            // scales (that transition belongs to their media VIEWER, not the camera); the token
            // shrink this carried (3.8% at a real drag) read as nothing anyway. No animation
            // modifier here on purpose: while the finger is down the FINGER is the animation, and
            // the put-back is applied at the release instead.
        }
        // THE PAGE DOES NOT RESIZE FOR THE KEYBOARD (owner 2026-08-04: "the entire editor frame moves
        // upward and a black background appears behind the keyboard").
        //
        // SwiftUI's automatic avoidance shrinks the available height, so the card was being made
        // shorter and everything in it moved — and the space the card no longer covered was black.
        // The card now keeps the whole screen and the keyboard simply sits over its lower part;
        // inside it, the words and the two buttons lift themselves. Nothing else moves at all.
        .ignoresSafeArea(.keyboard, edges: .bottom)
        // THE VOLUME KEYS, AS A SHUTTER. Zero-sized and non-interactive: it exists only to host the
        // capture interaction, and it must not take a point of layout or a single touch from
        // anything on the screen. Only in camera mode — the keys belong to the system again while a
        // text story is being typed.
        .background {
            if mode == .camera {
                CaptureEventCatcher(
                    onPhoto: {
                        guard !cam.recording else { cam.stopRecording(); return }
                        captureWithScreenFlashIfNeeded()
                    },
                    onHoldStart: {
                        guard !cam.recording else { return }
                        locked = false
                        cam.recording = true
                        zoomAtRecordStart = baseZoom
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        cam.startRecording()
                    },
                    onHoldEnd: { if cam.recording { cam.stopRecording() } })
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
            }
        }
        // THE SCREEN IS THE FRONT CAMERA'S FLASH — white, over everything, ignoring the safe area so
        // it lights the whole panel. See `captureWithScreenFlashIfNeeded`.
        .overlay {
            if screenFlash {
                Color.white.ignoresSafeArea().allowsHitTesting(false).transition(.opacity)
            }
        }
        // A QR IN THE FRAME, OFFERED RATHER THAN OBEYED. Another mainstream messenger shows a chip you may tap; nothing
        // opens itself, because a camera that navigates away on its own is a camera you cannot point
        // at a poster. Only Fariin profile links ever reach here — see `openableLink`.
        .overlay(alignment: .top) {
            if let code = cam.framedCode, mode == .camera, !cam.recording {
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    onClose()
                    // After the camera has gone, or the route opens behind a full-screen cover.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        // A scanned code can be anything; WebLink sends a web page to the sheet
                        // and hands everything else (tel:, our own links) to the system.
                        WebLink.open(code)
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "qrcode.viewfinder").font(.system(size: 15, weight: .semibold))
                        Text("Open profile").font(.subheadline.weight(.semibold))
                    }
                    .foregroundStyle(.black)
                    .padding(.horizontal, 16).frame(height: 40)
                    .background(.white, in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(.top, 84)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: cam.framedCode)
        // ⚠️ THE PREVIEW NEVER ROTATES, ONLY THE CONTROLS. That is what every camera does: the
        // picture stays the right way up under your thumb and the glyphs turn to meet your eye. The
        // whole chrome is counter-rotated by one angle, so nothing can turn a different amount from
        // anything else.
        .onReceive(NotificationCenter.default.publisher(
            for: UIDevice.orientationDidChangeNotification)) { _ in
                let next: Angle
                switch UIDevice.current.orientation {
                case .landscapeLeft:      next = .degrees(90)
                case .landscapeRight:     next = .degrees(-90)
                case .portraitUpsideDown: next = .zero   // ignored: a story is portrait
                default:                  next = .zero   // face up/down/unknown keep the last upright
                }
                guard next != deviceTilt else { return }
                withAnimation(.easeInOut(duration: 0.3)) { deviceTilt = next }
            }
        .onAppear {
            // A camera left framing a shot must not dim and lock — the reference app blocks the idle timer for
            // exactly the time the camera is up. Released in `onDisappear`, which is the only place
            // it can be, or the whole app stops sleeping.
            // ⚠️ THROUGH `SleepBlocker`, NOT THE SHARED FLAG DIRECTLY. Writing
            // `isIdleTimerDisabled` by hand gave the one system flag two owners with no agreement:
            // closing this screen during a voice recording or a call wrote `false` and let the phone
            // lock under them, and any other holder releasing its last reason wrote `false` while
            // the camera was still up and started dimming it. Voice record, voice playback and calls
            // all hold their reason here; the camera is now the fourth.
            SleepBlocker.shared.add("story-camera")
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        }
        .onAppear {
            // ⚠️ THE CHROME LEAVES BEFORE THE EDITOR ARRIVES — see `handingOver`. Both of these used
            // to hand straight on, so the first thing that moved was a whole modal sliding up from
            // the floor. Now the buttons fade off the picture, and only then is the editor asked for.
            cam.onCapture = { d in
                frozenShot = UIImage(data: d)
                withAnimation(.easeOut(duration: 0.22)) { handingOver = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) {
                    onCapture(d)
                    resetHandover()
                }
            }
            cam.onVideo = { url in
                // No still for a clip: the video editor opens on the clip's own first frame, which
                // is the same picture the preview was showing when the recording stopped.
                withAnimation(.easeOut(duration: 0.22)) { handingOver = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) {
                    onVideo(url)
                    resetHandover()
                }
            }
            cam.start()
            loadLibraryThumb()
        }
        .onDisappear {
            cam.stopRecording(); cam.stop()
            SleepBlocker.shared.remove("story-camera")
            UIDevice.current.endGeneratingDeviceOrientationNotifications()
            // A screen flash interrupted by leaving would otherwise leave the display pinned at full
            // brightness for the rest of the session.
            if let b = brightnessBeforeFlash { UIScreen.main.brightness = b; brightnessBeforeFlash = nil }
        }
        // The clock, ticking only while there is something to count. Restarting from zero lives here
        // rather than in the gesture, so every way a recording can begin is counted the same way.
        .onChange(of: cam.recording) { _, on in
            recordSeconds = 0
            // The lock and its growth belong to ONE recording. Carrying either into the next one
            // would draw a lit, grown lock over a clip nobody has locked.
            if !on { locked = false; lockProgress = 0 }
        }
        .task(id: "\(cam.recording)-\(recordSeconds)") {
            guard cam.recording else { return }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if cam.recording { recordSeconds += 1 }
        }
        .onChange(of: scenePhase) { _, phase in   // free the camera when backgrounded
            // ⚠️ `mode == .camera` ON THE WAY BACK, AND THAT CONDITION IS THE FIX. Two handlers own
            // this session and neither used to read the other: coming back from the background
            // started the camera unconditionally, and because `mode` had not CHANGED the handler
            // below never fired to stop it again. The session then ran behind the opaque text page
            // with the green indicator lit and nothing being previewed, until the mode was toggled.
            if phase == .active {
                if mode == .camera { cam.start() }
            } else {
                // Stop the recording before the session, not after. `stop()` alone tears the session
                // down with the movie output still running, and the delegate's error path can still
                // report a usable file — which then hands a clip to the editor from the background,
                // handover animation and all. `onDisappear` has always had this order.
                cam.stopRecording()
                cam.stop()
            }
        }
        // The camera is a power draw with nothing to show while text is on screen.
        .onChange(of: mode) { _, m in
            if m == .camera { cam.start() } else { cam.stop() }
        }
    }

    /// PUT THE CAMERA BACK, UNDERNEATH THE EDITOR THAT IS NOW COVERING IT.
    ///
    /// ⚠️ IT IS DONE ON A DELAY RATHER THAN ON THE WAY BACK, AND THAT IS DELIBERATE. The obvious
    /// place is `onAppear` when the editor closes, but a `fullScreenCover` does not promise the view
    /// underneath either an `onDisappear` or an `onAppear` — and if that promise is not kept, closing
    /// the editor returns you to a camera with no buttons and a frozen photo, which is a far worse
    /// failure than the slide this replaces. Resetting from the same place that set it cannot strand:
    /// by the time this runs the editor owns the whole screen, so nobody sees it happen.
    private func resetHandover() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            frozenShot = nil
            handingOver = false
        }
    }

    /// The flip, from the button and from the double tap, so the two can never drift apart.
    ///
    /// ⚠️ THE ZOOM GOES BACK TO 1× WITH IT, and that is not tidying. The pill's number is a REAR-lens
    /// idea: `deviceZoom` multiplies by the virtual device's first switch-over factor, and the front
    /// camera has no such device. Carrying .5 or 3 across would leave the pill saying one thing and
    /// the picture showing another — the mismatch build 526 went to some trouble to remove. All three
    /// are reset because they are three different things: `zoom` is what the pill draws, `baseZoom`
    /// is what the next pinch multiplies from, and `setZoom` is the device.
    private func flipCamera() {
        guard !cam.denied else { return }
        cam.flip()
        zoom = 1
        baseZoom = 1
        cam.setZoom(1)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// A PHOTO ON THE FRONT CAMERA IN THE DARK, lit by the only lamp that phone has: its screen.
    ///
    /// Another mainstream messenger's shape exactly — a white overlay, the display pushed to full brightness, a beat for
    /// the exposure to settle, then the shot, then the brightness put back. The 0.12s wait is not
    /// decoration: auto-exposure needs a moment to see the new light, and without it the picture is
    /// taken in the dark it was trying to fix.
    private func captureWithScreenFlashIfNeeded() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        guard cam.needsScreenFlash else { cam.capture(); return }
        // ⚠️ THE SAVE HAPPENS ONCE PER FLASH, AND A SECOND SHOT INSIDE THE 0.47s DOES NOT RE-SAVE.
        // Without this test the second capture read the brightness the FIRST one had just set — 1.0
        // — and stored it as the value to restore, so both restores wrote full brightness and the
        // display stayed at maximum. That is a system setting, not app state: it survived leaving
        // the camera, leaving the app, and relaunching, until the person turned it down by hand.
        if brightnessBeforeFlash == nil { brightnessBeforeFlash = UIScreen.main.brightness }
        withAnimation(.easeOut(duration: 0.08)) { screenFlash = true }
        UIScreen.main.brightness = 1.0
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            cam.capture()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                withAnimation(.easeOut(duration: 0.18)) { screenFlash = false }
                if let b = brightnessBeforeFlash { UIScreen.main.brightness = b }
                brightnessBeforeFlash = nil
            }
        }
    }

    // MARK: Preview card

    private var preview: some View {
        ZStack {
            Color.black
            // A PICTURE INSTEAD OF BLACK WHILE THE SESSION STARTS. Another mainstream messenger keeps a blurred last
            // frame for exactly this; ours is the same idea, held in memory. Under the live preview,
            // so it is simply covered the moment there is a real frame — no timing, no fade to get
            // wrong. Also what the flip cover blurs over.
            // ⚠️ THE FILL IS DRAWN THROUGH `Color.clear`, AND THAT IS HIS "THE TEXT CARD GROWS WHEN I
            // TAP THE TEXT". A `.scaledToFill()` image REPORTS the size it filled to, not the size it
            // was offered — a 9:16 camera frame in a 416×751 card reports 422×751 — and a ZStack takes
            // the LARGEST of its children, so the card became whatever the picture wanted. Measured on
            // his own screenshots: 3pt of overhang each side at rest, and 508×904 (exactly 9:16) once
            // the keyboard had re-run the layout, with the X and the tick pushed off the screen.
            //
            // A `Color.clear` takes exactly what it is offered, an OVERLAY cannot change its host's
            // size, and `.clipped()` throws away the overhang. Same picture, same crop, no vote on the
            // layout. The rule is general: `.scaledToFill()` with nothing under it is a view that sizes
            // its own parent.
            if let placeholder = cam.bootPlaceholder {
                Color.clear
                    .overlay {
                        Image(uiImage: placeholder)
                            .resizable()
                            .scaledToFill()
                    }
                    .clipped()
                    .allowsHitTesting(false)
            }
            CameraPreview(session: cam.session,
                          onTapToFocus: { devicePoint, viewPoint in
                              cam.focus(atDevicePoint: devicePoint)
                              focusPoint = viewPoint
                              focusShownAt = Date()
                              UIImpactFeedbackGenerator(style: .light).impactOccurred()
                          },
                          onDoubleTap: { flipCamera() })
                .gesture(MagnificationGesture()
                    .onChanged { scale in cam.zoomContinuous(baseZoom * scale) }
                    // 0.5 IS A REAL FLOOR NOW, not 1. Both of these used to clamp at 1 because a
                    // pinch spoke the DEVICE's units, where 1 is as wide as it goes; they speak the
                    // pill's units now, where the widest lens is .5 — so clamping at 1 would have
                    // made the ultra-wide unreachable by pinch and reset it on release.
                    .onEnded { scale in baseZoom = max(0.5, baseZoom * scale) })
                // (The double tap that flips lives in `CameraPreview` now, beside the focus tap, so
                // the two can be arbitrated with `require(toFail:)`. See `flipCamera`.)
                //
                // THE FLIP'S COVER. Another mainstream messenger pins a snapshot over the preview and fades a dark blur
                // across it while the session swaps inputs; ours is the blur over the frame the
                // preview layer is still holding, which comes to the same picture without asking
                // `drawHierarchy` for a snapshot it cannot reliably take of a video layer.
                .overlay {
                    if cam.switching {
                        Rectangle()
                            .fill(.ultraThinMaterial)
                            .environment(\.colorScheme, .dark)
                            .allowsHitTesting(false)
                            .transition(.opacity)
                    }
                }
                .animation(.easeOut(duration: 0.16), value: cam.switching)
                // THE FOCUS RETICLE — Apple's own shape: a square that lands slightly large and
                // settles, then fades. The reference app animates a Lottie file here; this is the same gesture
                // read in one view, and it disappears on its own so there is no state to clear.
                .overlay(alignment: .topLeading) {
                    if let p = focusPoint {
                        FocusReticle()
                            .position(x: p.x, y: p.y)
                            .allowsHitTesting(false)
                            .id(focusShownAt)
                    }
                }

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

            // THE CAPTURED FRAME, PINNED WHERE THE PREVIEW WAS. Above the live layer so the scene
            // cannot move on underneath while the controls are still fading, and filling the same
            // card, so nothing about the picture changes at the moment the photo is taken.
            // Through `Color.clear` for the same reason as the boot placeholder above: a captured photo
            // is 4:3, and a 4:3 fill in this card reports ~563pt of width. It would resize the card at
            // the exact moment the shutter fires, which is the one moment nothing may move.
            if let shot = frozenShot {
                Color.clear
                    .overlay {
                        Image(uiImage: shot)
                            .resizable()
                            .scaledToFill()
                    }
                    .clipped()
                    .allowsHitTesting(false)
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
                                    // ⚠️ THE ONE GLYPH ON THIS SCREEN THAT NEVER TURNED, and the
                                    // reason is that it is the one that does not go through
                                    // `chromeIcon`. That helper rotates its glyph and the X beside
                                    // this button gets it for free; the bolt is built by hand here
                                    // because it needs a capsule rather than a circle, and the
                                    // rotation was simply not copied across. So on a phone held
                                    // sideways the flash was the single control lying on its side.
                                    // The label turns, not the 46×44 hit area: what you press is
                                    // exactly what you pressed before.
                                    .rotationEffect(deviceTilt)
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
            .opacity(handingOver ? 0 : 1)
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
        // ⚠️ THE PILL DOES NOT ROTATE. ONLY THE NUMBERS INSIDE IT DO — his 2026-08-12 landscape
        // report, and his screenshot is the whole of it: `.rotationEffect(deviceTilt)` used to sit
        // HERE, on the capsule, so a quarter turn of the phone stood the whole control on its end.
        // A horizontal pill became a vertical stack rooted at the same centre, and its bottom
        // number came down on top of the shutter.
        //
        // Apple's own camera keeps the pill horizontal and turns only the glyphs, which is what the
        // comment on that line always claimed it was doing. The rotation moved into `zoomButton`.
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
        Button {
            // ⚠️ THE PHOTO ONLY. STOPPING BELONGS TO THE DRAG, AND THAT MOVE IS HIS 2026-08-16
            // "slide to lock, let go, and the recording stops anyway".
            //
            // This used to read `if cam.recording { cam.stopRecording() }`, which is the one stop on
            // the release path that never asked whether the recording had just been LOCKED. A
            // SwiftUI button fires its action on touch-up within a generous slop region around
            // itself, and the lock sits about 96pt from this button's centre — comfortably inside
            // it. So the slide latched the lock (the control went yellow, exactly as he described)
            // and then the same release fired this action and stopped the clip regardless. The
            // drag's own `onEnded` was already correct and was simply not the only stopper.
            //
            // One owner now: the drag ends every recording, because it is the only place that knows
            // where the finger travelled. This keeps the shutter's other job, which the drag has no
            // opinion about.
            guard !cam.recording else { return }
            captureWithScreenFlashIfNeeded()
        } label: {
            ZStack {
                // ⚠️ THE RING IS GLASS, NOT A PAINTED STROKE — his 2026-08-17 "make the recording
                // button liquid glass".
                //
                // It was `Circle().stroke(.white.opacity(0.55))`: a white line over whatever the
                // camera happened to be pointing at, which is the flat look this app keeps replacing.
                // A glass ring takes its brightness from the scene behind it, so it reads on a white
                // wall and on a night sky without either being chosen. `interactive` because it is a
                // control and the press should be felt in the material, the same call the zoom pill
                // and the flip button next door already make. Nothing is painted underneath it —
                // that is the rule this file learned five times on the camera switch.
                Color.clear
                    .frame(width: 84, height: 84)
                    .liquidGlass(Circle(), interactive: true)
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
                    lockedByThisTouch = false
                    // THE FLAG GOES UP HERE, not in the capture callback. It used to wait for
                    // `didStartRecordingTo`, which lands after the pipeline has actually opened a
                    // file — so the red square, the clock and the lock all appeared well after the
                    // finger went down and the control felt dead. The model corrects it back down
                    // if the start genuinely fails.
                    cam.recording = true
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    // Where the picture is as the recording starts, so an upward drag ramps FROM here
                    // rather than snapping to 1× first.
                    zoomAtRecordStart = baseZoom
                    cam.startRecording()
                }
        )
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { v in
                    // ⚠️ THE SLIDE IS FELT AS IT HAPPENS (owner 2026-08-11: "there's no animation,
                    // i am not feeling if i locked"). The lock used to be a pure threshold — nothing
                    // moved for 59 points and then it silently latched — so the only way to learn
                    // whether it had worked was to lift your finger and find out.
                    //
                    // The reference app drives its own lock control from a continuous tracking-progress value with
                    // an unlocked/locking/locked state; this is the same idea on our control: the
                    // lock grows and brightens as the thumb approaches it, so the gesture reports on
                    // itself the whole way. See `lockButton`.
                    if cam.recording, !locked {
                        lockProgress = min(1, max(0, v.translation.width / 60))
                    }
                    // Far enough right, hands free. 60pt is past anything a thumb wobbles.
                    if cam.recording, !locked, v.translation.width > 60 {
                        locked = true
                        // This touch is now the tail of a lock, not a press of the stop button.
                        lockedByThisTouch = true
                        lockProgress = 1
                        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
                    }
                    // DRAG UP FROM THE SHUTTER TO ZOOM WHILE RECORDING — both reference cameras have
                    // it, and it is the only way to zoom one-handed with the shutter already held.
                    //
                    // The two axes are kept apart the way the reference app keeps them: sideways is the LOCK and
                    // upward is the ZOOM, and neither is read while the other is winning. Without
                    // that, sliding diagonally to lock also racks the lens to 8×.
                    guard cam.recording else { return }
                    let up = -v.translation.height
                    guard up > 10, abs(v.translation.width) < 40 else { return }
                    // A 60pt-per-step ramp, another mainstream messenger's number, from where the recording started up to
                    // whatever this lens can actually do.
                    let steps = (up - 10) / 60
                    let target = min(cam.maxDisplayedZoom, zoomAtRecordStart + steps)
                    cam.zoomContinuous(target)
                    zoom = 0   // no pill entry matches a dragged zoom; light none of them
                }
                .onEnded { v in
                    // The dragged zoom is where the next pinch continues from, exactly as a tapped
                    // lens is (`zoomButton`), or letting go would silently rewind the picture.
                    if cam.recording, -v.translation.height > 10, abs(v.translation.width) < 40 {
                        baseZoom = min(cam.maxDisplayedZoom,
                                       zoomAtRecordStart + (-v.translation.height - 10) / 60)
                    }
                    // A slide that did NOT reach the lock relaxes it back rather than leaving the
                    // control part-grown over a recording that is ending anyway.
                    if !locked { withAnimation(.easeOut(duration: 0.18)) { lockProgress = 0 } }
                    // EVERY WAY A RECORDING ENDS IS HERE, because this is the only place that knows
                    // what the finger did:
                    //
                    //   not locked            → an ordinary hold, and letting go is the stop.
                    //   locked by THIS touch  → the tail of the slide onto the lock. Hands free; it
                    //                           must keep running, which is the whole feature.
                    //   locked earlier        → a fresh press on what is now the stop button.
                    if cam.recording, !locked || !lockedByThisTouch { cam.stopRecording() }
                    lockedByThisTouch = false
                }
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
        Button {
            // Only when this tap is what latched it: the shutter may be held by another finger, and
            // that finger's release must then be read as the tail of a lock rather than as a press
            // of the stop button — the same rule the slide sets. Tapping a lock that is already
            // locked changes nothing and must not disarm the next stop.
            if !locked { lockedByThisTouch = true }
            locked = true
            lockProgress = 1
            UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        } label: {
            Image(systemName: locked ? "lock.fill" : "lock")
                .font(.system(size: 17, weight: .semibold))
                // Yellow the moment it latches, so the state is readable at a glance and not only by
                // the shape of a small glyph.
                .foregroundStyle(locked ? Color.yellow : .white)
                .frame(width: 48, height: 48)
                // ⚠️ REAL GLASS, NOT `.ultraThinMaterial` — the same swap, and the same reason as the
                // ring above. A material is a blur we ask for; on iOS 26 the system draws glass for a
                // floating control and takes the scene's light with it. `.environment(\.colorScheme,
                // .dark)` went with the material: it existed to stop that blur resolving light over a
                // bright camera feed, and glass has no light and dark to choose between.
                .liquidGlass(Circle(), interactive: true)
                // The ring FILLS as the thumb approaches — the continuous half of the feedback, so
                // the gesture is legible before it completes rather than only after.
                .overlay(
                    Circle().strokeBorder(
                        locked ? Color.yellow.opacity(0.95)
                               : Color.white.opacity(0.35 + 0.55 * lockProgress),
                        lineWidth: 1.5 + 1.5 * lockProgress)
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        // Grows towards the finger on the way, then pops on the latch. Two different motions on
        // purpose: the growth tracks the drag, the pop announces that it took.
        .scaleEffect(locked ? 1.18 : 1 + 0.22 * lockProgress)
        .animation(.spring(response: 0.26, dampingFraction: 0.6), value: locked)
        .animation(.easeOut(duration: 0.1), value: lockProgress)
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
                    if let out = renderTextStory(text: storyText, styleIndex: styleIndex,
                                                 fontIndex: fontIndex, link: storyLink) {
                        onTextStory(out.data, out.linkTap.map { [$0] } ?? [])
                    }
                } label: {
                    // Two different backgrounds, so two different arrows. The idle disc is a
                    // translucent white over the camera and wants a white arrow; the ACTIVE one is
                    // `Color.accentColor`, which is the app's `.primary` tint and therefore white
                    // at night — so the arrow disappeared at the exact moment it became tappable.
                    // `Color(.systemBackground)` is that accent's inverse and needs no plumbing.
                    Image(systemName: "arrow.right")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(hasText ? Color(.systemBackground) : .white)
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
            Button { onLibrary() } label: { libraryCard.rotationEffect(deviceTilt) }
                .buttonStyle(.plain)
                .accessibilityLabel("Choose from library")
                .opacity(cam.recording ? 0 : 1)
                .disabled(cam.recording)
            Spacer(minLength: 8)
            Button { flipCamera() } label: {
                // The symbol the app already used for this, not a newer one I would be guessing at:
                // a wrong SF Symbol name is a BLANK button on the device and a green build in CI.
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(.white)
                    .rotationEffect(deviceTilt)
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
    /// ⚠️ FIFTH REPORT. READ THE REFERENCE APP'S SOURCE BEFORE TOUCHING THIS AGAIN — I did, and it is short.
    ///
    /// The reference implementation's composer type-selection control. It is
    /// the same control on the same screen for the same two words, so there is no interpretation
    /// left to do:
    ///
    /// ```swift
    /// final class ReferenceTypeSelectionControl: UISegmentedControl {
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
    /// The uppercase comes BACK, because it is the reference app's, not ours: they uppercase both titles. The
    /// previous note removed it as a hand-built flourish, which was the wrong call for the same
    /// reason the rest of this was.
    private var modePicker: some View {
        // The tap goes through the SAME curve as the swipe — see `modeCurve`.
        ComposerTypeSwitch(isText: Binding(get: { mode == .text },
                                           set: { v in
            withAnimation(Self.modeCurve) { mode = v ? .text : .camera }
        }))
            // Its own intrinsic size, the reference app's: the padding and the 40pt height come from the
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
            // Only the GLYPH turns. Rotating the circle as well would spin a shape that looks
            // identical at every angle and drag its glass highlight round with it.
            .rotationEffect(deviceTilt)
            .frame(width: 46, height: 46)
            .liquidGlass(Circle(), interactive: true)
            .contentShape(Circle())
    }

    private func zoomButton(_ level: CGFloat, _ label: String) -> some View {
        let on = zoom == level
        return Button {
            zoom = level
            baseZoom = level   // a pinch after tapping a lens continues from THAT lens
            cam.setZoom(level)
        } label: {
            Text(on ? "\(label)×" : label)
                .font(.system(size: on ? 14 : 13, weight: .semibold))
                .foregroundStyle(on ? .yellow : .white)
                // The GLYPH turns, inside a frame that does not — so the number reads upright with
                // the phone on its side while the pill keeps its shape and its place. See the note
                // on `zoomPill`.
                .rotationEffect(deviceTilt)
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

/// CAMERA | TEXT, built the way the reference app builds it, because five attempts at building it ourselves
/// all came out as grey plastic.
///
/// The reference implementation's composer type-selection control is the
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

    /// The reference app's intrinsic size, the half of their control we had not copied yet: 40pt tall and
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
        // Titles UPPERCASED, which is the reference app's, not a flourish of ours.
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
