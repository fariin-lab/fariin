import SwiftUI
import AVFoundation
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
    /// Show the floating bar? Only when a note is actually playing AND its chat is not the one on
    /// screen, because there the bubble already shows everything the bar would.
    ///
    /// ⚠️ `AppRouter.activeChatId` IS ALREADY THE ANSWER — I nearly added a second copy of it. It is
    /// set by `ThreadView` (and the official channel) on appear and cleared on disappear, and three
    /// other features already lean on it to mean "the chat currently on screen". A second field
    /// saying the same thing is how two sources of truth start disagreeing.
    ///
    /// Loading deliberately does not count: a bar that flashes for the half second before audio
    /// starts, in the chat you are already reading, is noise.
    var barVisible: Bool {
        playing && !messageId.isEmpty && cid != (AppRouter.shared.activeChatId ?? "")
    }

    private var player: AVAudioPlayer?
    private var timer: Timer?
    /// The playing note's own timestamp. `PlayedVoice` keys its receipts on it, so it has to be the
    /// message's date and not the moment we happened to press play.
    private var createdAt: Date = .distantPast
    /// A finger owns the scrubber. The 20Hz tick must not fight it.
    private var scrubbing = false

    /// Speed is remembered for the whole conversation, and a paused note's position survives its cell
    /// being recycled. Both used to be `static` on the view; they belong to the engine now, but the
    /// behaviour is unchanged.
    private var rateByCid: [String: Float] = [:]
    private var pausedProgress: [String: Double] = [:]

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
        if playing { player?.rate = next }
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
    }

    func setScrubbing(_ on: Bool) { scrubbing = on }

    // MARK: - Play / pause

    func toggle(message: Message, cid: String, isMe: Bool) {
        if playing && messageId == message.id { pause(); return }
        if messageId == message.id, player != nil { start(); return }
        Task { await load(message: message, cid: cid, isMe: isMe) }
    }

    private func load(message: Message, cid: String, isMe: Bool) async {
        // Taking over from whatever was playing: park its position first so it can be resumed.
        if playing { pause() }
        self.messageId = message.id
        self.cid = cid
        self.isMine = isMe
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
        // Persistent cache hit → instant, no download and no decrypt, and it survives relaunch. The
        // clientId is tried as a belt because my own note is cached under BOTH ids at send time; without
        // it a reconciled own-note fell through to the download path and span on "loading".
        if let cached = AudioCache.url(for: message.id)
            ?? message.clientId.flatMap({ AudioCache.url(for: $0) }) {
            open(cached)
            return
        }
        guard let urlStr = message.audioUrl, let url = URL(string: urlStr), let meta = message.enc else { return }
        loadingId = message.id
        defer { loadingId = "" }
        guard let (cipher, _) = try? await MediaSession.shared.data(from: url),
              let data = await Crypto.shared.decryptBytes(cid, cipher: cipher, meta: meta) else { return }
        // Persist the decrypted note so it never downloads twice.
        open(AudioCache.store(data, for: message.id))
    }

    private func open(_ url: URL) {
        guard !VoiceAudio.callActive else { return }
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)
        player = try? AVAudioPlayer(contentsOf: url)
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
        // Playing it counts as heard.
        if !isMine {
            let id = messageId, c = cid, at = createdAt
            withAnimation(.easeOut(duration: 0.25)) {
                PlayedVoice.shared.markPlayed(cid: c, messageId: id, createdAt: at)
            }
        }
        // Resume where it was left, including a position chosen by scrubbing before the first play.
        if let saved = pausedProgress[messageId], saved > 0, saved < 0.98, p.currentTime == 0 {
            p.currentTime = saved * p.duration
            progress = saved
        }
        p.enableRate = true
        p.rate = rateByCid[cid] ?? 1
        p.play()
        playing = true
        SleepBlocker.shared.add("voice-play")
        UIDevice.current.isProximityMonitoringEnabled = true
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
            // Hands the chain on: the chat finds the NEXT voice note and asks it to play.
            NotificationCenter.default.post(name: .voiceNoteFinished, object: finished)
        }
    }

    func pause() {
        guard player != nil else { return }
        player?.pause()
        playing = false
        timer?.invalidate(); timer = nil
        pausedProgress[messageId] = progress
        release()
    }

    /// Stop and forget, for the bar's close button.
    func dismiss() {
        pause()
        player = nil
        messageId = ""
        progress = 0
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
}
