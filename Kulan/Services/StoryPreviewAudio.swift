import AVFoundation
import CallKit

/// ⚠️ SOMEBODY ELSE'S CALL IS NOT A REASON A CLIP WILL NOT PLAY, AND IT WAS ONE.
///
/// His report: be on a call in another app, come into ours, put a video into the story editor —
/// and the clip never plays. No error, no first frame, a play button that does nothing.
///
/// The editor previews through a plain `AVPlayer`, and an AVPlayer ACTIVATES THE SHARED AUDIO
/// SESSION FOR ITSELF the moment it is told to play. Nothing on that screen had ever set a
/// category, so the session was still on the process default, `.soloAmbient` — a category that is
/// NOT MIXABLE, which means activating it asks whoever currently holds the session to stop. A call
/// refuses, the activation fails, and AVFoundation quietly declines to start. Everything above the
/// player is fine and there is nothing anywhere to see, which is why this reads as a broken editor
/// rather than as an audio problem.
///
/// `.ambient` is the same category one mixable step over: it still obeys the ring/silent switch, it
/// still lets the clip make its own sound, and it asks NOBODY to stop — so it is granted while a
/// call is up and the clip plays.
///
/// ⚠️ IT IS ONLY BORROWED WHILE A CALL IS ACTUALLY UP, and it is given back. With no call the
/// session is left exactly as it was found, so previewing a clip on an ordinary screen behaves
/// today the way it behaved yesterday — that is deliberate: the fix is for the case that was
/// broken, not a new audio policy for the app.
///
/// ⚠️ THE SESSION IS NOT ACTIVATED HERE. `setActive(true)` on the main thread costs a visible
/// freeze — the voice player carries the note about the 100-300ms it measured — and the player
/// performs its own activation anyway. All this has to do is make the activation the player is
/// about to perform one that can succeed.
enum StoryPreviewAudio {

    /// Held for the life of the process: an observer that is not retained reports nothing. It needs
    /// no permission and no delegate — `calls` is read on the spot.
    private static let callObserver = CXCallObserver()

    /// Did we take the category, and therefore do we owe it back? Guarded so that the give-back can
    /// never touch a session some other part of the app has since claimed for itself.
    private static var borrowed = false

    /// A call is in progress somewhere on this phone — the cellular one or any app that reports
    /// through CallKit, which every mainstream calling app does.
    static var callInProgress: Bool {
        callObserver.calls.contains { !$0.hasEnded }
    }

    /// Called immediately before a preview clip is told to play.
    @MainActor static func prepare() {
        // OUR OWN call owns the session outright (CallService drives the route and the mode), and a
        // story preview must never reach in and change it. See `VoiceAudio.callActive`.
        guard !VoiceAudio.callActive else { return }
        guard callInProgress else { give(); return }
        let s = AVAudioSession.sharedInstance()
        // Only ever taken FROM the default. If a voice note or the recorder has the session on
        // `.playback` or `.playAndRecord`, that belongs to them and is left alone.
        guard s.category == .soloAmbient else { return }
        try? s.setCategory(.ambient)
        borrowed = true
    }

    /// The last resort, and it exists because CallKit cannot be the whole answer: an app that does
    /// not report its calls, or anything else holding a session it will not give up, would leave the
    /// clip exactly as he found it. Reached only after a player has been told to play and has not.
    @MainActor static func forceMixable() {
        guard !VoiceAudio.callActive else { return }
        let s = AVAudioSession.sharedInstance()
        guard s.category == .soloAmbient || s.category == .ambient else { return }
        try? s.setCategory(.ambient, options: [.mixWithOthers])
        borrowed = true
    }

    /// Give the category back when the preview is over. Never a `setActive(false)`: we never
    /// activated it, and deactivating a session we do not own is how another app's audio dies.
    @MainActor static func give() {
        guard borrowed else { return }
        borrowed = false
        let s = AVAudioSession.sharedInstance()
        guard s.category == .ambient else { return }   // somebody else has claimed it since
        try? s.setCategory(.soloAmbient)
    }
}
