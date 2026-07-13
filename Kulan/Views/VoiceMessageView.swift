import SwiftUI
import AVFoundation
import UIKit

// Voice-note chain events (auto-advance): when a note finishes naturally, the chat looks up
// the NEXT voice message and asks its bubble to play — voicemail-style hands-free listening.
extension Notification.Name {
    static let voiceNoteFinished = Notification.Name("voiceNoteFinished")   // object = finished message id
    static let voiceNotePlay = Notification.Name("voiceNotePlay")           // object = message id to start
    static let voiceNoteStopOthers = Notification.Name("voiceNoteStopOthers") // object = the id NOW playing → others pause
}

// Playback ownership (a single shared audio player, minimal form): exactly one voice note owns
// the audio session at a time. Only the OWNER may deactivate the session / touch proximity on teardown —
// this is what stopped every off-screen bubble's onDisappear from nuking the shared session (and the
// auto-advance chain from cutting its own playback). `pendingPlayId` hands auto-advance to a bubble
// that isn't on screen yet (its cell claims the play in onAppear).
// A voice-note waveform scrub is in progress. The conversation's single swipe-to-reply pan reads this
// and yields, so dragging the waveform to seek never also drags the bubble into a reply. (The waveform's
// scrub is a horizontal SwiftUI gesture inside the hosted cell; this flag is how the UIKit pan defers to it.)
enum VoiceScrubState { static var active = false }   // set/read on the main thread only (gesture + UI)

enum VoiceAudio {
    static var activeId: String?
    static var pendingPlayId: String?
    // Never touch the audio session while a CALL owns it (1:1 or group) — a scrolled voice bubble must
    // not reroute/deactivate call audio.
    @MainActor static var callActive: Bool {
        CallService.shared.state != .idle || GroupCallService.shared.isActive
    }
}

// Playback bubble for a voice note: downloads the encrypted bytes, decrypts them
// (Crypto.decryptBytes), and plays via AVAudioPlayer. Play/pause + progress.
struct VoiceMessageView: View {
    let message: Message
    let cid: String
    let isMe: Bool
    let dark: Bool
    // Set when the player is rendered OUTSIDE a chat bubble (e.g. the "See All Media" Audio list) — on a
    // plain page background rather than a colored accent bubble. My own notes normally tint with
    // `onAccent` (white in light mode), which is invisible on the white gallery page; on a plain
    // background we use the page-neutral tint instead so my sent notes are visible.
    var plainBackground: Bool = false
    var onScrub: (Bool) -> Void = { _ in }   // forwarded to the bubble so it blocks reply-swipe while scrubbing

    @State private var player: AVAudioPlayer?
    @State private var playing = false
    @State private var loading = false
    @State private var progress: Double = 0
    @State private var timer: Timer?
    @State private var scrubbing = false   // a live drag owns the scrubber — the 20Hz timer must not fight it
    @State private var rate: Float = 1.0   // playback speed (1× / 1.5× / 2×), standard messenger style

    // Playback caches: the chosen speed sticks for the WHOLE conversation, and a paused
    // note's position survives its cell scrolling off-screen and back (cell reuse resets @State).
    private static var rateByCid: [String: Float] = [:]
    private static var pausedProgress: [String: Double] = [:]

    private var rateLabel: String { rate == 1 ? "1×" : (rate == 1.5 ? "1.5×" : "2×") }
    private func cycleRate() {
        rate = rate == 1 ? 1.5 : (rate == 1.5 ? 2 : 1)
        Self.rateByCid[cid] = rate
        if playing { player?.rate = rate }
    }

    private var tint: Color {
        if plainBackground { return dark ? .white : .black }   // on the plain gallery page, never the white onAccent
        return isMe ? Theme.onAccent(dark) : (dark ? .white : .black)
    }
    private var durationText: String {
        let d = Int(message.duration ?? 0)
        return String(format: "%d:%02d", d / 60, d % 60)
    }

    var body: some View {
        HStack(spacing: 12) {
            Button { toggle() } label: {
                Group {
                    if loading { ProgressView().tint(tint) }
                    else { Image(systemName: playing ? "pause.fill" : "play.fill").font(.system(size: 17)) }
                }
                .foregroundStyle(tint)
                .frame(width: 42, height: 42)
                .background(tint.opacity(0.18), in: Circle())   // big round play button (reference)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 4) {
                WaveformBars(bars: displayBars, progress: progress, played: tint,
                             unplayed: tint.opacity(0.3), playing: playing,
                             onSeek: { pct in seek(pct) },
                             onScrub: { s in scrubbing = s; VoiceScrubState.active = s; onScrub(s) })
                    .frame(width: 158, height: 26)
                HStack(spacing: 8) {
                    Text(durationText).font(.caption2).foregroundStyle(tint.opacity(0.8))
                    // "Not heard yet" dot (a blue mic indicator, our way) — fades once played.
                    if unheard {
                        Circle().fill(Theme.accent(dark)).frame(width: 7, height: 7)
                            .transition(.opacity)
                    }
                    // Speed toggle (1× / 1.5× / 2×) — appears once the note is loaded.
                    if player != nil {
                        Button { cycleRate() } label: {
                            Text(rateLabel).font(.system(size: 11, weight: .bold)).foregroundStyle(tint)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(tint.opacity(0.16), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .onAppear {
            rate = Self.rateByCid[cid] ?? 1                                   // per-chat speed sticks (standard)
            if !playing, let saved = Self.pausedProgress[message.id] { progress = saved }   // restore paused position
            // Auto-advance handoff for a bubble that was OFF-SCREEN when its turn came: the router parks
            // the id; the freshly-realized cell claims it here (the notification would have been dropped).
            if VoiceAudio.pendingPlayId == message.id {
                VoiceAudio.pendingPlayId = nil
                if !playing { toggle() }
            }
        }
        .onDisappear {
            stop()
            // Clean only the OPTIMISTIC just-recorded tmp file (still uploading). The DECRYPTED note now
            // lives in the persistent, file-protected AudioCache (Application Support) — it must NOT be
            // deleted here, or every scroll-away + relaunch would re-download & re-decrypt it (the bug).
            if !playing {
                let fm = FileManager.default
                fm.removeItemIfExists(at: fm.temporaryDirectory.appendingPathComponent("local-\(message.rowId).m4a"))
            }
        }
        // Single-player rule: when ANOTHER note starts, pause this one. The new owner has
        // already claimed VoiceAudio.activeId, so our teardown won't touch the shared session.
        .onReceive(NotificationCenter.default.publisher(for: .voiceNoteStopOthers)) { note in
            guard let id = note.object as? String, id != message.id, playing else { return }
            pause()
        }
        // Auto-advance: the chat posts .voiceNotePlay with the NEXT note's id when the previous
        // one finishes — if it's this bubble and it isn't already playing, start it.
        .onReceive(NotificationCenter.default.publisher(for: .voiceNotePlay)) { note in
            guard let id = note.object as? String, id == message.id, !playing else { return }
            toggle()
        }
        // Raise-to-ear: while a voice note plays, lifting the phone to your ear routes
        // playback to the earpiece; lowering it returns to the speaker. Monitoring is on ONLY during playback.
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.proximityStateDidChangeNotification)) { _ in
            guard playing else { return }
            let toEar = UIDevice.current.proximityState
            try? AVAudioSession.sharedInstance().setCategory(toEar ? .playAndRecord : .playback)
            try? AVAudioSession.sharedInstance().setActive(true)
        }
    }

    // Real captured waveform, or a neutral flat one for older messages that lack it.
    private var displayBars: [Int] {
        message.waveform.isEmpty ? Array(repeating: 35, count: 28) : message.waveform
    }

    // An incoming note this device has never played (optimistic local notes are mine).
    private var unheard: Bool {
        !isMe && message.localAudioData == nil
            && PlayedVoice.shared.isUnplayed(cid: cid, messageId: message.id, createdAt: message.createdAt)
    }

    private func seek(_ pct: Double) {
        guard let p = player else { return }   // no player yet → a tap must not move the scrubber visually
        progress = max(0, min(1, pct))
        p.currentTime = progress * p.duration
    }

    private func toggle() {
        if playing { pause(); return }
        if player != nil { play(); return }
        Task { await load() }
    }

    private func load() async {
        // Optimistic voice note (still uploading): play the just-recorded bytes directly.
        if let local = message.localAudioData {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("local-\(message.rowId).m4a")
            try? local.write(to: tmp)
            try? AVAudioSession.sharedInstance().setCategory(.playback)
            try? AVAudioSession.sharedInstance().setActive(true)
            player = try? AVAudioPlayer(contentsOf: tmp)
            play()
            return
        }
        // PERSISTENT cache hit → play from the local file instantly, no download, no decrypt (survives
        // relaunch + scroll-away). This is the fix for "voice notes re-download every launch".
        if let local = AudioCache.url(for: message.id) {
            try? AVAudioSession.sharedInstance().setCategory(.playback)
            try? AVAudioSession.sharedInstance().setActive(true)
            player = try? AVAudioPlayer(contentsOf: local)
            play()
            return
        }
        guard let urlStr = message.audioUrl, let url = URL(string: urlStr), let meta = message.enc else { return }
        loading = true
        defer { loading = false }
        guard let (cipher, _) = try? await URLSession.shared.data(from: url),
              let data = await Crypto.shared.decryptBytes(cid, cipher: cipher, meta: meta) else { return }
        // Persist the decrypted note (Application Support, file-protected) so it never re-downloads.
        let local = AudioCache.store(data, for: message.id)
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)
        player = try? AVAudioPlayer(contentsOf: local)
        play()
    }

    private func play() {
        guard player != nil else { return }
        guard !VoiceAudio.callActive else { return }   // never steal the session from an active call
        // Claim playback ownership FIRST, then pause any other playing note (its teardown sees a
        // different owner and leaves the shared session alone) — the single-player rule.
        VoiceAudio.activeId = message.id
        NotificationCenter.default.post(name: .voiceNoteStopOthers, object: message.id)
        // Playing it = heard: clears the accent mic in the chat list + the dot here.
        if !isMe { withAnimation(.easeOut(duration: 0.25)) {
            PlayedVoice.shared.markPlayed(cid: cid, messageId: message.id, createdAt: message.createdAt)
        } }
        // Resume a paused position that survived cell reuse (progress restored in onAppear).
        if let p = player, progress > 0, progress < 0.98, p.currentTime == 0 {
            p.currentTime = progress * p.duration
        }
        player?.enableRate = true
        player?.rate = rate
        player?.play()
        playing = true
        SleepBlocker.shared.add("voice-play-\(message.id)")          // don't auto-lock mid-listen
        UIDevice.current.isProximityMonitoringEnabled = true         // raise-to-ear active only while playing
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            guard let p = player else { return }
            if p.isPlaying {
                if !scrubbing {   // a live drag owns the scrubber — don't fight the finger
                    progress = p.duration > 0 ? p.currentTime / p.duration : 0
                }
            } else {
                playing = false
                progress = 0
                Self.pausedProgress.removeValue(forKey: message.id)   // finished → next play starts fresh
                timer?.invalidate(); timer = nil
                p.currentTime = 0
                playbackEnded(natural: true)
            }
        }
    }

    private func pause() {
        player?.pause(); playing = false; timer?.invalidate(); timer = nil
        Self.pausedProgress[message.id] = progress                    // survives cell reuse
        playbackEnded(natural: false)
    }
    private func stop() {
        if playing { Self.pausedProgress[message.id] = progress }     // scrolled away mid-play → resumable
        let hadPlayer = player != nil
        player?.stop(); playing = false; timer?.invalidate(); timer = nil
        if hadPlayer { playbackEnded(natural: false) }                // bubbles that never played touch NOTHING
    }

    // Teardown — OWNER-ONLY (this was the critical bug: every bubble scrolling off-screen deactivated
    // the shared session, cutting the user's music and the auto-advance chain's own playback). Only the
    // note that currently owns playback releases the session/proximity; and never during a call.
    private func playbackEnded(natural: Bool) {
        SleepBlocker.shared.remove("voice-play-\(message.id)")
        guard VoiceAudio.activeId == message.id else { return }   // another note owns audio now — hands off
        VoiceAudio.activeId = nil
        UIDevice.current.isProximityMonitoringEnabled = false
        if !VoiceAudio.callActive {
            // Leave the category on plain playback (raise-to-ear may have set .playAndRecord — the mic
            // must not stay hot), then hand the session back so music/podcasts resume.
            try? AVAudioSession.sharedInstance().setCategory(.playback)
            try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        }
        if natural { NotificationCenter.default.post(name: .voiceNoteFinished, object: message.id) }
    }
}

extension FileManager {
    // Best-effort delete (voice-note tmp plaintext cleanup) — silent no-op when the file isn't there.
    func removeItemIfExists(at url: URL) {
        guard fileExists(atPath: url.path) else { return }
        try? removeItem(at: url)
    }
}

// Premium waveform (standard style): rounded amplitude bars, the played portion
// tinted, draggable to seek. Drawn in a Canvas (one pass — cheap to redraw on progress).
struct WaveformBars: View {
    let bars: [Int]          // 0…100
    var progress: Double     // 0…1
    var played: Color
    var unplayed: Color
    var playing: Bool = false
    var onSeek: (Double) -> Void
    var onScrub: (Bool) -> Void = { _ in }   // true while dragging the waveform → parent blocks reply-swipe

    var body: some View {
        GeometryReader { geo in
            // TimelineView drives a gentle equalizer wobble while playing; paused when idle
            // so there's zero redraw cost when the note isn't playing.
            TimelineView(.animation(minimumInterval: 0.05, paused: !playing)) { tl in
                let phase = tl.date.timeIntervalSinceReferenceDate
                Canvas { ctx, size in
                    let count = max(bars.count, 1)
                    let slot = size.width / CGFloat(count)
                    let barW = max(2, slot * 0.5)
                    let playedTo = Int(Double(count) * progress)
                    for (i, v) in bars.enumerated() {
                        let norm = CGFloat(max(0, min(100, v))) / 100
                        var h = max(3, norm * size.height)
                        // Subtle live wobble on already-played bars during playback.
                        if playing && i <= playedTo {
                            let wob = sin(phase * 6 + Double(i) * 0.5)
                            h = max(3, h * CGFloat(1 + 0.14 * wob))
                        }
                        let x = CGFloat(i) * slot + (slot - barW) / 2
                        let rect = CGRect(x: x, y: (size.height - h) / 2, width: barW, height: h)
                        ctx.fill(Path(roundedRect: rect, cornerRadius: barW / 2),
                                 with: .color(i <= playedTo ? played : unplayed))
                    }
                    // White scrubber line at the current playback position (reference look).
                    let sx = max(1, size.width * CGFloat(max(0, min(1, progress))))
                    var line = Path()
                    line.move(to: CGPoint(x: sx, y: 0))
                    line.addLine(to: CGPoint(x: sx, y: size.height))
                    ctx.stroke(line, with: .color(played), lineWidth: 2)
                }
            }
            .contentShape(Rectangle())
            // simultaneousGesture GUARANTEES this fires alongside the bubble's reply-swipe (highPriority
            // didn't always co-fire inside the hosted collection-view cell, so the scrub flag wasn't set
            // in time and the reply still won). onChanged sets the flag synchronously → the reply bails.
            .simultaneousGesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    onScrub(true)
                    onSeek(Double(v.location.x / max(1, geo.size.width)))
                }
                .onEnded { _ in onScrub(false) })
        }
    }
}

// Live recording waveform: scrolling capsules from the most recent mic levels.
struct LiveWaveform: View {
    let levels: [Float]      // 0…1
    var color: Color

    var body: some View {
        GeometryReader { geo in
            HStack(alignment: .center, spacing: 2) {
                ForEach(Array(levels.enumerated()), id: \.offset) { _, lvl in
                    Capsule().fill(color)
                        .frame(width: 2.5, height: max(3, CGFloat(lvl) * geo.size.height))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            // Light interpolating spring on top of the recorder's meter ballistics: gives each bar a
            // touch of momentum as it settles, so the waveform reads fluid rather than stepped.
            .animation(.interpolatingSpring(stiffness: 260, damping: 26), value: levels)
        }
    }
}
