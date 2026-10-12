import AVFoundation

/// ⛔ THE STORY CAMERA BORROWS THE AUDIO SESSION AND GIVES IT BACK — owner 2026-10-12: "open a video
/// story, it plays; open the story camera, close it; video stories no longer play. Photos are fine."
///
/// THE CAUSE. Once microphone permission exists the camera attaches a mic input on every open
/// (`StoryCamera.attachAudioIfNeeded`). An `AVCaptureSession` left on its default
/// `automaticallyConfiguresApplicationAudioSession = true` then switches the APP's shared session to
/// `.playAndRecord` / `.videoRecording` and never switches it back when it stops. The story viewer's
/// `StoryAudioSession.claim` reads `.playAndRecord` as "a call or a recording owns it" and stands
/// aside, so every clip after the camera played in a recording session it never activated: no
/// `.playback`, and with another app holding audio (his call in another app) nothing activates at all.
/// A photo has no audio, which is why photos kept working.
///
/// THE FIX is the camera owning its audio the way the session's own setting cannot: it is switched
/// OFF, this sets `.playAndRecord` / `.videoRecording` only while a mic input is attached and the
/// camera runs, and `giveBack` restores exactly what was there before and deactivates with
/// `.notifyOthersOnDeactivation`. Leaving the session as it found it is also the reference
/// messengers' shape for their cameras.
enum CameraAudio {
    private static let lock = NSLock()
    private static var before: (category: AVAudioSession.Category,
                                mode: AVAudioSession.Mode,
                                options: AVAudioSession.CategoryOptions)?

    /// The camera's own session shape. `.videoRecording` is the mode nothing else in the app uses
    /// (calls are WebRTC's, voice notes are `.default`), which is how `giveBack` and
    /// `StoryAudioSession` know a leftover is the camera's and not a call's.
    static let category: AVAudioSession.Category = .playAndRecord
    static let mode: AVAudioSession.Mode = .videoRecording

    /// Before a capture session with a mic input starts. Remembers the shape once per borrowing.
    static func take() {
        let s = AVAudioSession.sharedInstance()
        lock.lock()
        if before == nil { before = (s.category, s.mode, s.categoryOptions) }
        lock.unlock()
        try? s.setCategory(category, mode: mode, options: [.defaultToSpeaker, .allowBluetoothA2DP])
        try? s.setActive(true)
    }

    /// After the capture session stops. Restores only if the session is still the camera's: a call
    /// or a voice note that took it over since is left alone.
    static func giveBack() {
        lock.lock()
        let saved = before
        before = nil
        lock.unlock()
        guard let saved else { return }
        let s = AVAudioSession.sharedInstance()
        guard s.category == category, s.mode == mode else { return }
        try? s.setActive(false, options: .notifyOthersOnDeactivation)
        // A snapshot that was itself a camera leftover (an older build, or the automatic setting)
        // goes back to the system default instead, or the bug is restored along with it.
        if saved.category == category, saved.mode == mode {
            try? s.setCategory(.soloAmbient, mode: .default, options: [])
        } else {
            try? s.setCategory(saved.category, mode: saved.mode, options: saved.options)
        }
    }
}
