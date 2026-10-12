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

    /// Set by the app: true while one of ITS calls is live. Only that owns the session against a
    /// story; nil (no app answer) keeps the old rule.
    public static var callIsLive: (() -> Bool)?

    /// Before a clip plays. Takes `.playback` once per viewer sitting.
    public static func claim() {
        let s = AVAudioSession.sharedInstance()
        // ⛔ A LEFTOVER RECORDING SESSION IS NOT AN OWNER — owner 2026-10-12, twice: video stories
        // stopped playing after the story camera, and "sometimes story audio comes out of the
        // earpiece". `.playAndRecord` is left behind by the camera (`.videoRecording`), by the voice
        // recorder that warms itself on every chat open and never hands back, and by our calls after
        // they end. Standing aside for any of those played the clip in a recording session: the
        // earpiece, or nothing at all while another app's call held the mic. Only a LIVE call of ours
        // keeps the session now; everything else is taken over like an idle session.
        let leftover = s.category == .playAndRecord && !(callIsLive?() ?? (s.mode != .videoRecording))
        guard s.category != .playAndRecord || leftover else { return }   // a live call owns it
        if !claimed {
            // Hand back the system default, not the leftover, when the viewer closes: whatever left
            // it (the voice recorder's warm path, a call) configures its own session when it next runs.
            previous = leftover ? (.soloAmbient, .default, []) : (s.category, s.mode, s.categoryOptions)
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
