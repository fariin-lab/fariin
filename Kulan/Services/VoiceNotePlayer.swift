import SwiftUI
import AVFoundation
import MediaPlayer
import UIKit

/// THE ONE VOICE-NOTE PLAYER IN THE APP, and it does not belong to a bubble.
///
/// His 2026-08-10 report, and the research behind it: for a user who communicates mostly by voice,
/// playback stopping the moment you leave the chat does not read as a missing feature, it reads as
/// the app being broken. The reference app keeps the note playing and shows a bar; ours died.
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
/// Carries a built-and-prerolled player from the background thread that made it to the main actor that
/// will own it. AVAudioPlayer is not Sendable, and it does not need to be: exactly one thread touches
/// this object at a time, and the handoff below is the only crossing. Spelled out in a box rather than
/// left to the compiler's concurrency mode, which is what decides whether the bare capture is a
/// warning or an error.
private final class PreparedPlayer: @unchecked Sendable {
    let player: AVAudioPlayer?
    init(_ player: AVAudioPlayer?) { self.player = player }
}

// ⛔ THE `voiceNoteInteraction` NOTIFICATION IS GONE, AND SO IS THE GUARD IT ARMED. It existed for
// one report — keyboard open, press play or the speed pill, keyboard closes — on the theory that
// something in the audio stack was taking the first responder, and it defended the composer for a
// second after every tap rather than name the call. The owner declined to keep it: "I want the
// underlying cause fixed, not just the symptom temporarily blocked."
//
// The cause was never in this file. `cycleRate` opens no session, changes no category and touches no
// proximity monitoring, and it closed the keyboard exactly as readily as `toggle` did — which rules
// the audio stack out on its own. Both are taps on the conversation, and the conversation carries a
// tap-to-dismiss gesture that hears every touch on it and cannot tell a control from wallpaper. It
// is fixed where it happens: see `VoiceBubbleView.controlTouch`.

@MainActor
final class VoiceNotePlayer: NSObject, ObservableObject {
    /// Is a text field or text view currently the first responder anywhere on screen? Used only to
    /// decide whether arming proximity monitoring is safe — see the note where it is armed. Walks the
    /// key window's responder chain, which is the only way UIKit exposes the question.
    static var isEditingText: Bool {
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap({ $0.windows })
            .first(where: { $0.isKeyWindow }) else { return false }
        return window.findFirstResponderIsTextInput()
    }

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
    /// PAUSED BY THE PERSON, as opposed to paused by the world. His rule (2026-08-13): play a note,
    /// stop it yourself, walk out of the chat — no bar. You were finished with it.
    ///
    /// ⚠️ AND THIS IS WHY IT IS A FLAG RATHER THAN JUST `!playing`. Unplugging headphones pauses, and
    /// so does a phone call, and both of those pause a note the person very much has NOT finished
    /// with. Hiding the bar there strands it: paused, in a chat they have left, with the only control
    /// that could restart it gone. Who paused it is the difference, so who paused it is what is
    /// recorded.
    private(set) var pausedByUser = false

    /// Show the floating bar? Only when a note is open AND its chat is not the one on screen (there
    /// the bubble already shows everything the bar would) AND the person did not stop it themselves.
    var barVisible: Bool {
        hasNote && !messageId.isEmpty && cid != (AppRouter.shared.activeChatId ?? "")
            && !(pausedByUser && !playing)
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
    /// A loaded one-time note's decrypted bytes live here (never the AudioCache). Belt only now —
    /// one-time notes play in OneTimeVoicePage, not through this engine.
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
        // ⚠️ CONSECUTIVE, NOT "ALL THE VOICE NOTES BELOW" (his 2026-08-13 screenshot: two notes, a
        // text, then a third note — "I can't play 3 because it has a gap"). A `filter` walked PAST
        // anything in between, so a run of two would carry on into a note further down the chat with
        // a message sitting between them. A run is what was sent one after another and nothing else,
        // so it stops at the first thing that is not a voice note.
        //
        // One-time notes end a run for the same reason they are never auto-played: advancing into
        // one would SPEND its single listen on somebody who never chose to open it.
        //
        // A NOTICE IS NOT SOMETHING ANYBODY SENT, so it does not end a run — his rule, in his own
        // words: everything sendable breaks the group. "You pinned a photo" and "messages
        // auto-delete in 1 week" are lines the app writes about the chat, drawn down the middle of
        // the screen rather than as a bubble, and stopping a run of notes on one would be stopping
        // it on nothing.
        var run: [Message] = []
        for m in items.dropFirst(idx + 1) {
            if m.isSystem || m.pinNotice != nil { continue }
            guard m.isAudio, !m.viewOnce else { break }
            run.append(m)
            if run.count >= Self.followOnCap { break }
        }
        followOn = run
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
                Self.setCategoryIfNeeded(toEar ? .playAndRecord : .playback)
                if toEar {
                    // AND CLEAR ANY SPEAKER OVERRIDE, which is the half that was missing. `.playAndRecord`
                    // routes to the earpiece by DEFAULT, so this looked complete — but an override set
                    // earlier SURVIVES on the shared session, and CallService sets `.speaker` in seven
                    // places. Take a call on speaker, end it, raise a note to your ear, and the note came
                    // out of the loudspeaker. The reference app clears the override every single time it
                    // routes to the ear, and this is the reason.
                    try? AVAudioSession.sharedInstance().overrideOutputAudioPort(.none)
                }
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
                self.pause(byUser: false)   // the cable was pulled, not the button — see pausedByUser
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
                    self.pause(byUser: false)   // a call is not them finishing — see pausedByUser
                    // The system took the session; `pause()` deliberately does not give it back, so
                    // nothing else would clear this. Without the line, `.ended` below reaches
                    // `start()`, which skips re-activating and plays into a dead session — silence.
                    self.sessionActive = false
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
        // AND THE KNOB MOVES WITH IT. `progress` is ONE shared number, and `progress(for:)` hands it to
        // whichever bubble currently owns `messageId` — so the instant the id moves, the new bubble
        // starts drawing the position the PREVIOUS note was paused at. It then holds that wrong
        // position for the whole load (a download, or just the session activation below) until the
        // first tick corrects it to zero. That flash forward and snap back is his "the wave jumps,
        // comes back to the start, then starts", and it is first-time-only per note because after the
        // first play the id already matches. Set with the id, never after the player exists.
        progress = pausedProgress[message.id] ?? 0
        self.cid = cid
        self.isMine = isMe
        // Kept for the played receipt below, which needs the message's OWN timestamp rather than now.
        self.createdAt = message.createdAt

        // Optimistic note (still uploading): play the bytes we just recorded.
        if let local = message.localAudioData {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("local-\(message.rowId).m4a")
            try? local.write(to: tmp)
            open(tmp, for: message.id)
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
            // ⚠️ ONLY CLEAR MY OWN SPINNER. Two loads can overlap, and an unconditional clear meant
            // whichever finished FIRST stopped the other note's disc spinning while it was still
            // downloading.
            defer { if loadingId == message.id { loadingId = "" } }
            guard let (cipher, _) = try? await MediaSession.shared.data(from: url),
                  let data = await Crypto.shared.decryptBytes(cid, cipher: cipher, meta: meta) else {
                clearNowPlaying(); return
            }
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("voice-once-\(message.id).m4a")
            try? data.write(to: tmp)
            transientURL = tmp
            open(tmp, for: message.id)
            return
        }
        // Persistent cache hit → instant, no download and no decrypt, and it survives relaunch. The
        // clientId is tried as a belt because my own note is cached under BOTH ids at send time; without
        // it a reconciled own-note fell through to the download path and span on "loading".
        if let cached = AudioCache.url(for: message.id)
            ?? message.clientId.flatMap({ AudioCache.url(for: $0) }) {
            open(cached, for: message.id)
            return
        }
        // Nothing to fetch, or the fetch/decrypt failed: hand the lock screen back rather than leaving
        // the previous note's entry sitting on it with no player behind it.
        guard let urlStr = message.audioUrl, let url = URL(string: urlStr), let meta = message.enc else {
            clearNowPlaying(); return
        }
        loadingId = message.id
        defer { if loadingId == message.id { loadingId = "" } }   // see the note above — mine only
        guard let (cipher, _) = try? await MediaSession.shared.data(from: url),
              let data = await Crypto.shared.decryptBytes(cid, cipher: cipher, meta: meta) else {
            clearNowPlaying(); return
        }
        // Persist the decrypted note so it never downloads twice.
        open(AudioCache.store(data, for: message.id), for: message.id)
    }

    /// ⛔ `forNote` IS AN ARGUMENT, NOT A READ OF THE CURRENT STATE.
    ///
    /// This used to capture `let forNote = messageId` — the engine's id AT THE MOMENT THE FILE WAS
    /// READY, not the id the load was actually for. Loads run in detached tasks, so two can overlap:
    /// tap note A (needs a download), tap note B while A is still fetching, and B overwrites
    /// `messageId`. When A's download finishes it captures B as its own, the guard below compares B
    /// against B and passes, and **note A's audio plays out of note B's bubble** with B's waveform
    /// tracking it.
    ///
    /// The id has to travel with the load from the point the load was decided, which is what every
    /// caller now passes.
    private func open(_ url: URL, for forNote: String) {
        // A call owns the session, or the file will not open (truncated, still uploading, wrong bytes).
        // Either way nothing is going to play, so leave nothing behind claiming otherwise.
        guard !VoiceAudio.callActive else { clearNowPlaying(); return }
        // ⚠️ ACTIVATION OFF THE MAIN THREAD — his "the wave jumps on the first play, then normal".
        // setActive(true) renegotiates the audio hardware for ~100-300ms, and doing it on main
        // froze whatever frame was mid-flight: the eye reads the dropped frames as a jump it
        // cannot quite catch. Only the FIRST play pays it (pause holds the session since the
        // late-play fix), which is exactly the first-time-only shape he reported.
        Task.detached(priority: .userInitiated) {
            VoiceNotePlayer.setCategoryIfNeeded(.playback)
            try? AVAudioSession.sharedInstance().setActive(true)
            // AND THE PLAYER IS BUILT OUT HERE TOO. `AVAudioPlayer(contentsOf:)` parses the file header
            // and stands the decoder up on whatever thread calls it, and the preroll that `play()`
            // would otherwise do lazily allocates buffers and wakes the hardware on that same thread.
            // Both were landing on main, and they are the half of the first-play freeze that the
            // session move did not cover. The reference app never pays either on main — it drives
            // AVPlayer, which loads its asset asynchronously by construction — so this is how the same
            // answer is reached from AVAudioPlayer.
            let built = PreparedPlayer(try? AVAudioPlayer(contentsOf: url))
            built.player?.prepareToPlay()
            await MainActor.run { [weak self] in
                guard let self, self.messageId == forNote else { return }   // another note took over meanwhile
                guard let p = built.player else { self.clearNowPlaying(); return }
                self.player = p
                // Activated off-main just above, so `start()` must not pay for it again on main.
                self.sessionActive = true
                self.start()
            }
        }
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
        // SOUND FIRST, PAPERWORK AFTER — his "play/pause is not as fast as the reference app".
        // Everything this method used to do before `play()` (two UserDefaults writes for the played
        // receipt, the receipt throttle, a category set, a session activation) ran between his finger
        // and the audio. None of it has to. The reference app orders it the same way and goes one
        // further: it flips its own playing state BEFORE telling the engine anything, so the button
        // answers the tap even when the audio needs a moment. `playing = true` below is that flip.
        //
        // ⛔ AND THE FLIP HAS TO COME FIRST TO BE THE FLIP — his "play/pause feels laggy",
        // 2026-08-25. It sat BELOW `p.play()`, so the icon still waited on the two session calls
        // underneath this comment: `setActive(true)` renegotiates the audio hardware and blocks
        // MAIN for 100-300ms, which is the whole delay he is describing. The note above already
        // said the reference flips its state first; the code just never did it.
        playing = true
        // ⛔ AND THE SESSION IS ONLY TOUCHED WHEN IT IS NOT ALREADY OURS. `pause()` deliberately
        // keeps the session (see its own note), and `open()` activates it off-main before ever
        // calling here — so on every resume, and on every first play, these two lines were
        // re-doing work that was already done, on the main thread, in front of the finger.
        //
        // The CATEGORY check stays unconditional: it is a property read that returns immediately in
        // the normal case, and it is the one that catches the recorder having left the session on
        // `.playAndRecord` — which would otherwise route a note to the earpiece and keep the mic hot.
        // Only `setActive` is gated, because only `setActive` is the one that blocks.
        Self.setCategoryIfNeeded(.playback)
        if !sessionActive {
            try? AVAudioSession.sharedInstance().setActive(true)
            sessionActive = true
        }
        p.enableRate = true
        p.rate = rateByCid[cid] ?? 1
        // Resume where it was left, including a position chosen by scrubbing before the first play.
        // Must precede `play()`: setting currentTime on a running player is an audible seek.
        if let saved = pausedProgress[messageId], saved > 0, saved < 0.98, p.currentTime == 0 {
            p.currentTime = saved * p.duration
            progress = saved
        }
        // ⛔ A REFUSED PLAY IS NOT A FINISHED ONE. `play()` returns false when the session was lost
        // between `open` and here — a call starting, another app taking the hardware — or when the
        // file is truncated. The result was discarded, and the tick below treats ANY non-playing
        // player as playback having completed: it clears the position, releases the note and
        // advances the run. So one failure tore through an entire consecutive run in about a second,
        // marking each note played on the way — telling the sender their notes had been heard when
        // nothing came out of the speaker.
        //
        // Theirs distinguishes the two because it uses the delegate's `successfully` flag; this is
        // the same distinction reached from `play()`'s own return value.
        guard p.play() else {
            playing = false
            timer?.invalidate(); timer = nil
            clearNowPlaying()
            return
        }
        hasNote = true
        // (One-time notes are not consumed here any more: they play in OneTimeVoicePage, never
        // through this engine, and CLOSING that page is what spends the listen — his order, the
        // photo model. The engine's no-cache viewOnce path below stays as a belt: if any future
        // code routes one here, the bytes still never touch the persistent cache.)
        // Playing it counts as heard. NOT inside withAnimation any more — that global transaction
        // animated EVERY view update landing in the same instant (the waveform's recolor, the
        // icon swap), which was the second half of his first-play "jump". The bubble's own
        // `.animation(value: unheard)` animates the dot's fade by itself, locally.
        if !isMine {
            let id = messageId, c = cid, at = createdAt
            PlayedVoice.shared.markPlayed(cid: c, messageId: id, createdAt: at)
            // And now the SENDER is told too, which is the half that never existed: the line above only
            // ever wrote to this phone's own UserDefaults, so somebody could send a two-minute note and
            // never learn whether it was heard. Throttled and gated on the read-receipts setting inside.
            ChatService.markVoicePlayedThrottled(c, createdAtMillis: at.timeIntervalSince1970 * 1000)
        }
        SleepBlocker.shared.add("voice-play")
        // ⛔ NOT WHILE SOMEONE IS TYPING — owner, on a screenshot: "when i open keyboard then i play
        // voice or i click play or i click 1x, keyboard starts to close".
        //
        // Turning proximity monitoring on tells iOS to prepare to blank the screen when the phone is
        // raised to the ear, and the system resigns the first responder as part of that. Nothing in
        // the chat asked for the keyboard to go; pressing play did, through here.
        //
        // Monitoring only exists to catch the raise-to-ear so the note can move to the earpiece (see
        // the proximity observer above). Someone with the keyboard open and a thumb on the screen is
        // not raising the phone to their ear, so there is nothing to catch and nothing is lost by
        // waiting: the keyboard closing is itself the moment this becomes worth arming, and the next
        // note played without a keyboard arms it normally.
        if !Self.isEditingText { UIDevice.current.isProximityMonitoringEnabled = true }
        enable(true)
        updateNowPlaying()
        timer?.invalidate()
        // ⚠️ `.common` MODE, like the recorder's meter — `Timer.scheduledTimer` lands in .default,
        // which the run loop STARVES while a finger tracks a scroll. The knob froze mid-play and
        // the bubbles' mirrored state went stale exactly while the person browsed the chat (his
        // "sound plays but nothing shows playing, sometimes" report — the sometimes was scrolling).
        let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
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
            // THE END OF THE RUN LEAVES THE BAR STANDING, PAUSED (his rule, 2026-08-13: "it must
            // pause on the chat list so the user has to play again or tap x"). It used to close
            // itself, which is the one moment a person is most likely to want the thing again — the
            // note just ended and there is nothing on screen to press. So the note stays OPEN at
            // second zero with a play button, and the X is how you say you are done.
            //
            // ⚠️ EXCEPT A ONE-TIME NOTE. Its bytes are thrown away the moment it finishes and it has
            // no second listen by design, so leaving a play button over it would be a lie.
            //
            // ⚠️ AND ONLY WHEN THE BAR IS ALREADY UP. His question, which caught this: what if it
            // finishes while I am IN the chat and I leave afterwards? Keeping the note open there
            // would raise a bar on the chat list for something that ended while he was watching it —
            // a player appearing for a sound that is already over. The bar is for a note that was
            // still going when he walked away, so a note that ends inside its own chat closes, and
            // one that ends outside it stays for the replay.
            let oneTime = transientURL != nil
            let insideItsChat = cid == (AppRouter.shared.activeChatId ?? "")
            if oneTime || insideItsChat { hasNote = false }
            pausedByUser = false     // the note ended by itself; nobody pressed anything
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
        pausedByUser = false
        start()
    }

    func pause(byUser: Bool = true) {
        guard player != nil else { return }
        // ⚠️ "THEY ARE DONE WITH IT" ONLY COUNTS INSIDE ITS OWN CHAT (his report, 2026-08-14: pausing
        // from the bar made the bar vanish as if he had pressed X). His rule was about stopping a
        // note in the chat and walking out — the pause he presses THERE is the bubble's. A pause on
        // the BAR is the opposite: the bar is where the play button lives, so hiding it for pressing
        // pause takes away the only way back. Same flag, decided by where the finger was.
        pausedByUser = byUser && cid == (AppRouter.shared.activeChatId ?? "")
        // The icon flips first, same order as the reference app's pause. The engine call is quick, but
        // "quick" is not "before the next frame", and the button is what the finger is watching.
        playing = false
        player?.pause()
        timer?.invalidate(); timer = nil
        pausedProgress[messageId] = progress
        // ⚠️ THE AUDIO SESSION IS NOT GIVEN BACK ON A PAUSE ANY MORE — his "still late play"
        // report. `release()` here deactivated the session, so EVERY resume paid setActive(true)'s
        // audio-hardware renegotiation (~100-300ms of silence after the tap) before a sound came
        // out. A paused note is still open (`hasNote`) and still the owner; only finishing or
        // dismissing releases now. The cost, accepted knowingly: another app's music will not
        // resume while a note sits paused — the trade every reference messenger makes, because a
        // play button that answers instantly is the thing a voice-first user touches most.
        // Screen-sleep and raise-to-ear still stand down, they never needed the session.
        SleepBlocker.shared.remove("voice-play")
        UIDevice.current.isProximityMonitoringEnabled = false
        // The note stays OPEN on a pause — that is the whole point of `hasNote`. The lock screen keeps
        // its entry, now reading paused, so play is still one tap away without unlocking.
        updateNowPlaying()
    }

    /// YOU OPENED THE CHAT THE PAUSED NOTE LIVES IN, so the bar has nothing left to say.
    ///
    /// The other half of the rule his question exposed. A note that ends outside its chat stays open
    /// on purpose, so the bar can offer it again — but walking INTO that chat means you are looking
    /// at the bubble itself, which has its own play button and its own position. Leaving the note
    /// open there means the bar reappears the next time you step out, for a sound that finished long
    /// ago. So opening its chat closes it.
    ///
    /// ⚠️ Only when it is NOT playing. A note still going stays exactly as it is: the bubble takes
    /// over the display and the audio never stops, which is the whole promise of the engine outliving
    /// the view.
    func chatOpened(_ id: String) {
        guard hasNote, cid == id, !playing else { return }
        dismiss()
    }

    /// Stop and forget, for the bar's close button.
    func dismiss() {
        resumeAfterInterruption = false   // they ended it; a call finishing must not bring it back
        followOn = []                     // closing the bar ends the run, not just the note on it
        pause()
        release()   // pause() holds the session now (instant resume); dismissing is the real end,
                    // and this must run BEFORE messageId clears — release identifies itself by it
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
            Self.setCategoryIfNeeded(.playback)
            Self.deactivate()
        }
        // The session is gone, so the next `start()` has to pay for it again. Cleared unconditionally:
        // during a call we did not deactivate, but the call owns the session and will hand it back in
        // its own state, which is not a state we may assume is still activated for us.
        sessionActive = false
    }

    /// Whether the audio session is currently activated FOR US, so `start()` can skip re-activating it.
    ///
    /// Not a question that can be asked of `AVAudioSession` — it has no "is active" property — so it
    /// is tracked. Anything that gives the session up, or that could have taken it from us (a call,
    /// raise-to-ear re-routing, an interruption), clears this; the cost of a wrong `false` is one
    /// redundant activation, and the cost of a wrong `true` is silence, so it errs toward false.
    private var sessionActive = false

    /// Touch the session only when the answer would actually change. `setCategory` is not free — it can
    /// renegotiate the route — and `start()` calls it on every single play. The reference app guards the
    /// same call the same way rather than setting it blind.
    ///
    /// A non-empty options set counts as a difference on its own: we always set plain categories here,
    /// so leftovers from the recorder (`.duckOthers`) or a call must be cleared, not inherited.
    nonisolated private static func setCategoryIfNeeded(_ category: AVAudioSession.Category) {
        let s = AVAudioSession.sharedInstance()
        guard s.category != category || !s.categoryOptions.isEmpty else { return }
        try? s.setCategory(category)
    }

    /// Give the session back, and DO NOT ACCEPT A REFUSAL SILENTLY. AVAudioSession answers `.isBusy`
    /// when the hardware has not finished tearing down, which a `try?` swallows whole — and a session
    /// that never deactivates is a session that never posts `.notifyOthersOnDeactivation`, so the
    /// person's music stays dead after they listen to a note. The reference app retries this exact
    /// error code for this exact reason; everything else is a real failure and is left alone.
    nonisolated private static func deactivate(retries: Int = 3) {
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        } catch let error as NSError {
            guard retries > 0, error.code == AVAudioSession.ErrorCode.isBusy.rawValue else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { deactivate(retries: retries - 1) }
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

private extension UIView {
    /// True when this view, or any view under it, is the first responder AND takes text.
    func findFirstResponderIsTextInput() -> Bool {
        if isFirstResponder { return self is UITextInput }
        for sub in subviews where sub.findFirstResponderIsTextInput() { return true }
        return false
    }
}
