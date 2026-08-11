import SwiftUI
import AVFoundation
import MediaPlayer
import UIKit

/// THE ONE VOICE-NOTE PLAYER IN THE APP, and it does not belong to a bubble.
///
/// His 2026-08-10 report, and the research behind it: for a user who communicates mostly by voice,
/// playback stopping the moment you leave the chat does not read as a missing feature, it reads as
/// the app being broken. WhatsApp keeps the note playing and shows a bar; ours died.
///
/// ⚠️ IT DIED BY CONSTRUCTION, NOT BY A BUG. `VoiceMessageView` held its `AVAudioPlayer` in `@State`,
/// so the player's lifetime was the *view's* lifetime: leave the chat, SwiftUI tears the view down,
/// the last strong reference goes with it and the audio stops mid-sentence. `onDisappear` then called
/// `stop()` on top of that. No amount of session configuration could have survived it, because there
/// was nothing left holding the player. The fix is ownership: the engine outlives every view.
///
/// Everything the bubble used to do is here, and the hard-won rules it carried are kept verbatim,
/// because each one is a bug somebody already found:
///   • ONE note at a time (`activeId` + `.voiceNoteStopOthers`).
///   • OWNER-ONLY teardown of the shared audio session. Every off-screen bubble used to deactivate
///     it, which cut the user's music and the auto-advance chain's own playback.
///   • NEVER touch the session while a call owns it.
///   • A paused position survives scrolling away and coming back.
///   • Speed sticks per conversation.
///   • Raise-to-ear only while something is actually playing.
///
/// Background audio is already declared (`UIBackgroundModes: audio` in project.yml, for calls), and
/// the category here is `.playback`, so with the engine holding the player the note now also survives
/// the screen locking.
@MainActor
final class VoiceNotePlayer: NSObject, ObservableObject {
    static let shared = VoiceNotePlayer()

    /// The note being played right now. Empty means nothing is loaded.
    @Published private(set) var messageId: String = ""
    @Published private(set) var cid: String = ""
    @Published private(set) var playing = false
    @Published private(set) var loadingId: String = ""
    @Published private(set) var progress: Double = 0
    /// Whether the note now playing is one of mine, so the bar can say "You".
    @Published private(set) var isMine = false
    /// A note is OPEN: it has been started and has not finished or been dismissed. Not the same as
    /// `playing`.
    ///
    /// ⚠️ THE BAR USED TO KEY OFF `playing`, AND THAT ONLY WORKED WHILE NOTHING COULD PAUSE US BUT THE
    /// USER. It cannot survive the two handlers added below: unplugging headphones pauses, and so does
    /// a phone call, and both would have taken the bar away with them — pausing a note and removing the
    /// only control that could restart it, with the note stranded in a chat the person has left. Open
    /// is the honest condition, and the bar draws play-vs-pause from `playing`.
    @Published private(set) var hasNote = false
    /// Show the floating bar? Only when a note is open AND its chat is not the one on screen, because
    /// there the bubble already shows everything the bar would.
    ///
    /// ⚠️ `AppRouter.activeChatId` IS ALREADY THE ANSWER — I nearly added a second copy of it. It is
    /// set by `ThreadView` (and the official channel) on appear and cleared on disappear, and three
    /// other features already lean on it to mean "the chat currently on screen". A second field
    /// saying the same thing is how two sources of truth start disagreeing.
    ///
    /// Loading deliberately does not count: a bar that flashes for the half second before audio
    /// starts, in the chat you are already reading, is noise.
    var barVisible: Bool {
        hasNote && !messageId.isEmpty && cid != (AppRouter.shared.activeChatId ?? "")
    }

    /// Who the open note is from, for the bar and for the lock screen. One answer, because those two
    /// must never disagree about what is playing.
    ///
    /// `displayName` is the app's own answer and the only correct one: `title` is the GROUP name and is
    /// empty for a one-to-one chat, where the name lives in the `names` map instead. Reading `title`
    /// directly would have labelled every private chat "Voice message".
    var noteTitle: String {
        let me = AuthService.shared.uid ?? ""
        let conv = ConversationsRepository.shared.conversations.first { $0.id == cid }
        let title = conv?.displayName(me) ?? ""
        if isMine { return title.isEmpty ? "You" : "You · \(title)" }
        return title.isEmpty ? "Voice message" : title
    }

    private var player: AVAudioPlayer?
    private var timer: Timer?
    /// The playing note's own timestamp. `PlayedVoice` keys its receipts on it, so it has to be the
    /// message's date and not the moment we happened to press play.
    private var createdAt: Date = .distantPast
    /// The loaded note is a ONE-TIME listen. Its decrypted bytes live at `transientURL` (never the
    /// AudioCache), and starting it marks it consumed on this device.
    private var isViewOnce = false
    private var transientURL: URL?

    /// Shred a one-time note's decrypted file. Called wherever the engine moves off a note —
    /// another load, the bar's dismiss, or the note finishing.
    private func disposeTransient() {
        guard let t = transientURL else { return }
        try? FileManager.default.removeItem(at: t)
        transientURL = nil
    }
    /// A finger owns the scrubber. The 20Hz tick must not fight it.
    private var scrubbing = false

    /// Speed is remembered for the whole conversation, and a paused note's position survives its cell
    /// being recycled. Both used to be `static` on the view; they belong to the engine now, but the
    /// behaviour is unchanged.
    private var rateByCid: [String: Float] = [:]
    private var pausedProgress: [String: Double] = [:]
    /// Set only when an interruption is what stopped us, so `.ended` never resumes a note the person
    /// paused themselves, and never resumes one that a pulled headphone stopped on purpose.
    private var resumeAfterInterruption = false

    /// THE REST OF THE RUN, so leaving the chat does not end it.
    ///
    /// People do not send one voice note, they send four, and the second most common thing that happens
    /// to a note is the next one starting by itself. That chaining lived entirely in `ThreadView` — it
    /// reads the loaded message list, which dies with the view — so walking away finished the note in
    /// your ear and stopped dead.
    ///
    /// The chat hands this over on its way out. Inside the chat nothing changes and the chat still
    /// drives the chain, because it can also scroll the next bubble into view and the engine cannot.
    /// Capped, because a long history can hold far more voice notes than any run a person means to sit
    /// through.
    private var followOn: [Message] = []
    private static let followOnCap = 30

    /// Called by the chat as it disappears. Anything that is not a voice note after `id` is dropped, and
    /// an `id` that is not in this list at all (nothing playing, or a note from a different chat) empties
    /// the run rather than guessing.
    func handOff(followOn items: [Message], after id: String) {
        guard !id.isEmpty, let idx = items.firstIndex(where: { $0.id == id }) else {
            followOn = []
            return
        }
        // One-time notes are excluded: auto-advance playing one would SPEND its single listen on a
        // person who never chose to open it. They are only ever played by a deliberate tap.
        followOn = Array(items.dropFirst(idx + 1).filter { $0.isAudio && !$0.viewOnce }.prefix(Self.followOnCap))
    }

    private override init() {
        super.init()
        // RAISE TO EAR, owned here now. It was on the bubble, which meant it stopped working the
        // moment the bubble went away — exactly the case this class exists for.
        NotificationCenter.default.addObserver(
            forName: UIDevice.proximityStateDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.playing else { return }
                let toEar = UIDevice.current.proximityState
                try? AVAudioSession.sharedInstance().setCategory(toEar ? .playAndRecord : .playback)
                try? AVAudioSession.sharedInstance().setActive(true)
            }
        }

        // HEADPHONES OUT MUST NOT PUT A PRIVATE NOTE ON THE SPEAKER.
        //
        // iOS does not do this for you. With `.playback` and an AVAudioPlayer, pulling the cable or
        // taking an AirPod out reroutes to the built-in speaker and playback carries straight on, out
        // loud, in front of whoever is standing there. `CallService` has always handled this for calls;
        // voice notes never did. It is a privacy fault, not a rough edge.
        //
        // ⚠️ ONLY `.oldDeviceUnavailable`. Route changes fire constantly, and two of them are our own
        // doing: raise-to-ear swaps the category (`.categoryChange`) and the speaker override fires
        // `.override`. Pausing on those would stop the note every time the phone came off the ear.
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, self.playing else { return }
                guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                      AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable
                else { return }
                // Deliberately no auto-resume when they are plugged back in. Apple's own rule, and the
                // right one: the person pulled them out, and starting again by itself is the exact
                // thing this handler exists to prevent.
                self.resumeAfterInterruption = false
                self.pause()
            }
        }

        // A CALL, SIRI OR AN ALARM NO LONGER ENDS THE NOTE FOR GOOD.
        //
        // `AudioRecorder` has handled this since it was written: it hears the interruption, pauses, and
        // keeps the file. The player had no handler at all, so a call arriving mid-note stopped the
        // audio, left the progress where it fell, and never came back — with nothing on screen saying
        // why. The system tells us when it is safe to carry on; we only had to listen.
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
                switch type {
                case .began:
                    guard self.playing else { return }
                    self.resumeAfterInterruption = true
                    self.pause()
                case .ended:
                    guard self.resumeAfterInterruption else { return }
                    self.resumeAfterInterruption = false
                    let opts = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt)
                        .map(AVAudioSession.InterruptionOptions.init) ?? []
                    // `.shouldResume` is the system saying the thing that took the audio has given it
                    // back. Without it — Siri still open, another app now playing — resuming would be
                    // us fighting for the speaker.
                    guard opts.contains(.shouldResume), !VoiceAudio.callActive, self.player != nil
                    else { return }
                    self.start()
                @unknown default:
                    break
                }
            }
        }

        wireRemoteCommands()
    }

    // MARK: - What the bubble asks

    func isPlaying(_ id: String) -> Bool { playing && messageId == id }
    func isLoading(_ id: String) -> Bool { loadingId == id }
    /// The progress THIS note should draw: the live one while it owns playback, otherwise whatever it
    /// was paused at, otherwise zero.
    func progress(for id: String) -> Double {
        if messageId == id { return progress }
        return pausedProgress[id] ?? 0
    }
    func rate(for cid: String) -> Float { rateByCid[cid] ?? 1 }

    func cycleRate(cid: String) {
        let next: Float = rate(for: cid) == 1 ? 1.5 : (rate(for: cid) == 1.5 ? 2 : 1)
        rateByCid[cid] = next
        if playing { player?.rate = next; updateNowPlaying() }   // the lock screen clock runs at 2× too
        objectWillChange.send()
    }

    /// Scrub or tap the waveform. Works BEFORE the first play too: with no player yet the position is
    /// stashed and `play` picks it up, which is why you can drag to a spot and then press play.
    func seek(_ pct: Double, id: String) {
        let pct = max(0, min(1, pct))
        guard messageId == id, let p = player else {
            pausedProgress[id] = pct
            objectWillChange.send()
            return
        }
        progress = pct
        p.currentTime = pct * p.duration
        // The lock screen follows the bubble's scrub — but NOT on every frame of it. A drag calls this
        // at gesture rate, and pushing a whole new now-playing dictionary sixty times a second is the
        // waste the comment on `updateNowPlaying` exists to prevent. Mid-drag is skipped and the finger
        // lifting publishes the final position, below. A lock-screen scrub arrives here with `scrubbing`
        // false, so that one lands immediately.
        if !scrubbing { updateNowPlaying() }
    }

    func setScrubbing(_ on: Bool) {
        scrubbing = on
        if !on { updateNowPlaying() }   // finger lifted: publish where it actually landed
    }

    // MARK: - Play / pause

    func toggle(message: Message, cid: String, isMe: Bool) {
        // A DELIBERATE TAP ENDS THE OLD RUN. This is the only entry a person drives, so a run handed
        // over earlier is stale the moment they pick something themselves. The chain below calls `load`
        // directly and so passes straight over this — which is the point, otherwise the run would clear
        // itself after playing exactly one more note.
        followOn = []
        if playing && messageId == message.id { pause(); return }
        if messageId == message.id, player != nil { start(); return }
        Task { await load(message: message, cid: cid, isMe: isMe) }
    }

    private func load(message: Message, cid: String, isMe: Bool) async {
        // Taking over from whatever was playing: park its position first so it can be resumed.
        if playing { pause() }
        // ⚠️ AND THE OLD PLAYER GOES WITH IT. It used to be left alive under the new note's id, so when
        // the new one failed to load — no signal, a key we could not fetch — `toggle` saw
        // `player != nil` for the new id and played the PREVIOUS note's audio under the new bubble.
        // Clearing costs nothing: coming back reloads from the cache and resumes at the position
        // `pause()` just saved.
        player = nil
        // Moving off whatever was loaded ends a one-time note's single listen: its decrypted bytes
        // go now, before anything else can happen to them.
        disposeTransient()
        // Nothing is open until the new note actually starts, so the bar goes now rather than hovering
        // over a note that may never play.
        hasNote = false
        resumeAfterInterruption = false
        self.messageId = message.id
        self.cid = cid
        self.isMine = isMe
        self.isViewOnce = message.viewOnce
        // Kept for the played receipt below, which needs the message's OWN timestamp rather than now.
        self.createdAt = message.createdAt

        // Optimistic note (still uploading): play the bytes we just recorded.
        if let local = message.localAudioData {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("local-\(message.rowId).m4a")
            try? local.write(to: tmp)
            open(tmp)
            return
        }
        // ONE-TIME VOICE: never the cache, in either direction. The decrypted bytes live in one
        // throwaway file for exactly this listen, and `disposeTransient` shreds it the moment the
        // engine moves off the note — finish, dismiss, or another note taking over.
        if message.viewOnce {
            guard let urlStr = message.audioUrl, let url = URL(string: urlStr), let meta = message.enc else {
                clearNowPlaying(); return
            }
            loadingId = message.id
            defer { loadingId = "" }
            guard let (cipher, _) = try? await MediaSession.shared.data(from: url),
                  let data = await Crypto.shared.decryptBytes(cid, cipher: cipher, meta: meta) else {
                clearNowPlaying(); return
            }
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("voice-once-\(message.id).m4a")
            try? data.write(to: tmp)
            transientURL = tmp
            open(tmp)
            return
        }
        // Persistent cache hit → instant, no download and no decrypt, and it survives relaunch. The
        // clientId is tried as a belt because my own note is cached under BOTH ids at send time; without
        // it a reconciled own-note fell through to the download path and span on "loading".
        if let cached = AudioCache.url(for: message.id)
            ?? message.clientId.flatMap({ AudioCache.url(for: $0) }) {
            open(cached)
            return
        }
        // Nothing to fetch, or the fetch/decrypt failed: hand the lock screen back rather than leaving
        // the previous note's entry sitting on it with no player behind it.
        guard let urlStr = message.audioUrl, let url = URL(string: urlStr), let meta = message.enc else {
            clearNowPlaying(); return
        }
        loadingId = message.id
        defer { loadingId = "" }
        guard let (cipher, _) = try? await MediaSession.shared.data(from: url),
              let data = await Crypto.shared.decryptBytes(cid, cipher: cipher, meta: meta) else {
            clearNowPlaying(); return
        }
        // Persist the decrypted note so it never downloads twice.
        open(AudioCache.store(data, for: message.id))
    }

    private func open(_ url: URL) {
        // A call owns the session, or the file will not open (truncated, still uploading, wrong bytes).
        // Either way nothing is going to play, so leave nothing behind claiming otherwise.
        guard !VoiceAudio.callActive else { clearNowPlaying(); return }
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)
        player = try? AVAudioPlayer(contentsOf: url)
        guard player != nil else { clearNowPlaying(); return }
        start()
    }

    private func start() {
        guard let p = player else { return }
        guard !VoiceAudio.callActive else { return }   // never steal the session from a call
        // `activeId` still marks who owns the audio session, because the RECORDER and the call
        // services read it. But the `.voiceNoteStopOthers` broadcast that used to go with it is gone:
        // it existed to make many independent per-bubble players behave like one, and there is only
        // one player now, so nothing can be playing for it to stop. A post with no listener reads to
        // the next person like a rule still being enforced somewhere.
        VoiceAudio.activeId = messageId
        // A one-time note is SPENT the moment it starts, and the mark is written now, not at the
        // end: an app kill mid-listen must not hand back a second listen. Pause and resume within
        // this one load still work — the pill allows them while the engine holds the note.
        if isViewOnce && !isMine { ViewedOnce.mark(messageId) }
        // Playing it counts as heard.
        if !isMine {
            let id = messageId, c = cid, at = createdAt
            withAnimation(.easeOut(duration: 0.25)) {
                PlayedVoice.shared.markPlayed(cid: c, messageId: id, createdAt: at)
            }
            // And now the SENDER is told too, which is the half that never existed: the line above only
            // ever wrote to this phone's own UserDefaults, so somebody could send a two-minute note and
            // never learn whether it was heard. Throttled and gated on the read-receipts setting inside.
            ChatService.markVoicePlayedThrottled(c, createdAtMillis: at.timeIntervalSince1970 * 1000)
        }
        // Resume where it was left, including a position chosen by scrubbing before the first play.
        if let saved = pausedProgress[messageId], saved > 0, saved < 0.98, p.currentTime == 0 {
            p.currentTime = saved * p.duration
            progress = saved
        }
        // Re-activate before playing. `pause()` gives the session back so other audio can carry on, and
        // an interruption takes it away outright — both leave us deactivated, and resuming from either
        // has to ask for it again rather than assume AVAudioPlayer will.
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)
        p.enableRate = true
        p.rate = rateByCid[cid] ?? 1
        p.play()
        playing = true
        hasNote = true
        SleepBlocker.shared.add("voice-play")
        UIDevice.current.isProximityMonitoringEnabled = true
        enable(true)
        updateNowPlaying()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        guard let p = player else { return }
        if p.isPlaying {
            if !scrubbing { progress = p.duration > 0 ? p.currentTime / p.duration : 0 }
        } else {
            let finished = messageId
            playing = false
            progress = 0
            pausedProgress.removeValue(forKey: finished)   // played to the end → next play starts fresh
            timer?.invalidate(); timer = nil
            p.currentTime = 0
            release()
            // Played to the end: the note is no longer open, so the bar goes and the lock screen is
            // handed back. MUST come after `release()`, which identifies itself by `messageId`.
            hasNote = false
            clearNowPlaying()
            disposeTransient()   // a finished one-time note's bytes do not outlive the listen
            // CHAIN ON. Inside the chat the chat still does it, and should: it scrolls the next bubble
            // into view on the way, which nothing in here can do. Outside the chat nobody would, which
            // is what used to end a run of notes the moment you walked away — so the engine plays the
            // next one itself, out of the run the chat handed over as it left.
            if cid != (AppRouter.shared.activeChatId ?? ""), !followOn.isEmpty {
                let next = followOn.removeFirst()
                let mine = next.authorId == (AuthService.shared.uid ?? "")
                Task { await load(message: next, cid: cid, isMe: mine) }
                return
            }
            // Hands the chain on: the chat finds the NEXT voice note and asks it to play.
            NotificationCenter.default.post(name: .voiceNoteFinished, object: finished)
        }
    }

    /// Carry on with the open note. The bar's play button and nothing else — the bubble goes through
    /// `toggle`, which also has to cope with the note not being loaded yet.
    func resume() {
        guard player != nil, !playing else { return }
        start()
    }

    func pause() {
        guard player != nil else { return }
        player?.pause()
        playing = false
        timer?.invalidate(); timer = nil
        pausedProgress[messageId] = progress
        release()
        // The note stays OPEN on a pause — that is the whole point of `hasNote`. The lock screen keeps
        // its entry, now reading paused, so play is still one tap away without unlocking.
        updateNowPlaying()
    }

    /// Stop and forget, for the bar's close button.
    func dismiss() {
        resumeAfterInterruption = false   // they ended it; a call finishing must not bring it back
        followOn = []                     // closing the bar ends the run, not just the note on it
        pause()
        player = nil
        messageId = ""
        progress = 0
        hasNote = false
        clearNowPlaying()
        disposeTransient()   // dismissing a one-time note ends its single listen for good
    }

    /// Give the audio session back. OWNER-ONLY, and never during a call: this is the rule that stopped
    /// every off-screen bubble from cutting the user's music.
    private func release() {
        SleepBlocker.shared.remove("voice-play")
        guard VoiceAudio.activeId == messageId else { return }
        VoiceAudio.activeId = nil
        UIDevice.current.isProximityMonitoringEnabled = false
        if !VoiceAudio.callActive {
            // Back to plain playback first: raise-to-ear may have left it on `.playAndRecord`, and the
            // microphone must not stay hot after a note finishes.
            try? AVAudioSession.sharedInstance().setCategory(.playback)
            try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        }
    }

    // MARK: - The lock screen, the car, and the AirPods

    /// A note already survives the screen locking — and until now there was no way to reach it once it
    /// had. Nothing appeared on the lock screen, pinching an AirPod did nothing, the car showed nothing,
    /// and stopping it meant unlocking the phone and finding the bar. Playing audio the system cannot
    /// see is playing audio the person cannot control.
    ///
    /// ⚠️ TARGETS ARE ADDED EXACTLY ONCE, FROM `init`. `addTarget` appends, so wiring these per note
    /// would stack a new handler on every play and one tap would fire all of them. The commands are
    /// switched on and off with `enable(_:)` instead, and stay off while nothing is open so the system
    /// never routes a play from some other app's controls into ours.
    ///
    /// ⚠️ THESE HOP TO THE MAIN ACTOR RATHER THAN ASSUMING IT. The observers above can use
    /// `MainActor.assumeIsolated` because they were registered with `queue: .main`, which guarantees it.
    /// Apple does not document the same guarantee for remote commands, and `assumeIsolated` on a thread
    /// that is not the main one is not a wrong answer, it is a crash — triggered by a car stereo or a
    /// pinched AirPod, which is exactly the report nobody could ever reproduce. `.success` is returned
    /// up front because the real answer is not known yet; the system does nothing with it either way.
    private func wireRemoteCommands() {
        // `addTarget` hands back a token for removing the handler again. We never remove these — they
        // live as long as the app — so it is dropped deliberately rather than left as a warning.
        let c = MPRemoteCommandCenter.shared()
        _ = c.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.resume() }
            return .success
        }
        _ = c.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }
        // What an AirPod pinch and a steering-wheel button actually send.
        _ = c.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.playing ? self.pause() : self.resume()
            }
            return .success
        }
        _ = c.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let at = e.positionTime
            Task { @MainActor in
                guard let self, let p = self.player, p.duration > 0 else { return }
                self.seek(at / p.duration, id: self.messageId)
            }
            return .success
        }
        enable(false)
    }

    private func enable(_ on: Bool) {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.isEnabled = on
        c.pauseCommand.isEnabled = on
        c.togglePlayPauseCommand.isEnabled = on
        c.changePlaybackPositionCommand.isEnabled = on
    }

    /// Elapsed time is published, not ticked. The system extrapolates from the position and the rate we
    /// hand it, so this is called on state changes only — pushing a new dictionary 20 times a second
    /// behind a locked screen would be pure waste, and it is what makes lock-screen scrubbing jitter.
    private func updateNowPlaying() {
        guard hasNote, let p = player else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: noteTitle,
            MPMediaItemPropertyArtist: "Voice message",
            MPMediaItemPropertyPlaybackDuration: p.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: p.currentTime,
            // Zero means paused. The lock screen reads the rate, not a separate flag, and a paused note
            // left claiming rate 1 keeps a clock running that is not moving. `0.0` spelled out: in an
            // `Any` dictionary a bare `0` gives the type checker room to call it an Int.
            MPNowPlayingInfoPropertyPlaybackRate: playing ? Double(p.rate) : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
    }

    /// Hand the lock screen back. Whatever was playing before us (music, a podcast) becomes the now
    /// playing app again on its own; leaving a finished voice note sitting there would not.
    private func clearNowPlaying() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        enable(false)
    }
}
