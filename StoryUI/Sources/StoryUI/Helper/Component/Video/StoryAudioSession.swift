import AVFoundation

/// ⛔ THE STORY VIEWER BORROWS THE AUDIO SESSION AND GIVES IT BACK (owner, 2026-10-12, from the
/// reference-app research: "opening a video story stops my music and it never comes back").
///
/// Every clip used to set `.playback` on the shared session and nothing ever undid it. `.playback`
/// without options interrupts other apps' audio, which is the stopped music; and since no one ever
/// deactivated the session or restored its category, the music had no signal to resume and the app
/// stayed on `.playback` after the viewer closed. The reference app takes the session for the
/// viewer and releases it when the viewer goes, so other audio resumes.
///
/// Sound-on stays exactly as it was (his rule: stories play through the silent switch). What is
/// new is only the hand-back: the category in force before the first clip is restored, and the
/// session is deactivated with `.notifyOthersOnDeactivation`, the documented way to tell the music
/// app it can carry on.
///
/// A call owns the session outright: while the category is `.playAndRecord` (our calls, voice
/// notes being recorded) the viewer neither takes nor gives anything.
@MainActor
public enum StoryAudioSession {
    private static var claimed = false
    private static var previous: (category: AVAudioSession.Category,
                                  mode: AVAudioSession.Mode,
                                  options: AVAudioSession.CategoryOptions)?

    /// Before a clip plays. Takes `.playback` once per viewer sitting.
    public static func claim() {
        let s = AVAudioSession.sharedInstance()
        // ⛔ A CAMERA'S LEFTOVER IS NOT A CALL (owner 2026-10-12: video stories stopped playing after
        // the story camera, photos did not). A capture session leaves `.playAndRecord` with mode
        // `.videoRecording` behind; nothing that really owns the session (our calls, voice notes)
        // runs in that mode, so it is taken over like any idle session. See the app's `CameraAudio`.
        let cameraLeftover = s.category == .playAndRecord && s.mode == .videoRecording
        guard s.category != .playAndRecord || cameraLeftover else { return }   // a call or a recording owns it
        if !claimed {
            // Hand back the system default, not the leftover, when the viewer closes.
            previous = cameraLeftover ? (.soloAmbient, .default, []) : (s.category, s.mode, s.categoryOptions)
            claimed = true
        }
        if s.category != .playback { try? s.setCategory(.playback) }
    }

    /// When the viewer goes. Restores what was there and lets other audio resume.
    public static func release() {
        guard claimed else { return }
        claimed = false
        let s = AVAudioSession.sharedInstance()
        let before = previous
        previous = nil
        // Somebody else (a call, the recorder) has claimed the session since: leave it to them.
        guard s.category == .playback else { return }
        try? s.setActive(false, options: .notifyOthersOnDeactivation)
        if let before {
            try? s.setCategory(before.category, mode: before.mode, options: before.options)
        }
    }
}
