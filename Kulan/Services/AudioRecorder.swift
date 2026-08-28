import Foundation
import AVFoundation
import Observation

// Records a voice note to a temp .m4a and hands back the raw bytes + duration +
// a tiny amplitude waveform (captured live via metering — no file re-decode).
// The bytes go through the SAME E2EE pipeline as photos (Crypto.encryptBytes).
@Observable
final class AudioRecorder {
    private var recorder: AVAudioRecorder?
    private var fileURL: URL?
    private var timer: Timer?
    private var interruptionObserver: NSObjectProtocol?
    // Fired when a phone call / Siri / alarm interrupts recording — the view resets its hold UI.
    var onInterrupt: (() -> Void)?

    /// ⛔ A RECORDING WITH NO END. There was no cap of any kind: a take could run until the battery
    /// died, and paired with a locked recording that survives leaving the chat, a pocket could
    /// produce a half-hour file nobody knew was being made.
    ///
    /// It does NOT throw the take away — `onReachedLimit` lands it on the review bar with everything
    /// said so far, so the ceiling is a full stop rather than a loss.
    ///
    /// ⛔ ONE NUMBER, AND IT LIVES IN `Limits`. This was a local `600` while `Limits.voiceNoteSeconds`
    /// said 30 minutes and was referenced by nothing at all — the file that calls itself the single
    /// source of truth and a mirror of the server rules was being ignored by the only code that
    /// enforces this cap. Owner's decision, 2026-08-28: thirty minutes, and the two must be the same
    /// value rather than two values that agree by luck.
    static var maxDuration: TimeInterval { Limits.voiceNoteSeconds }
    /// Fired once when the cap is hit. The view stops the take and shows the review bar.
    var onReachedLimit: (() -> Void)?
    private var limitFired = false
    var isRecording = false
    /// ⛔ IS THE MIC ACTUALLY CAPTURING RIGHT NOW — which is a different question from `isRecording`.
    ///
    /// `isRecording` means "a recording session exists and has not been sent or cancelled", and the
    /// interruption handler's `.ended` branch depends on that reading to know whether to resume. This
    /// one means "bytes are being captured this instant", and it is what anything OUTWARD-FACING must
    /// follow: the presence broadcast that tells the other person we are recording, and the sleep
    /// blocker that keeps the screen awake for it. During a phone call both of those must stop, and
    /// the session must survive.
    var isCapturing = false
    var elapsed: TimeInterval = 0
    var currentTime: TimeInterval { recorder?.currentTime ?? 0 }   // live (not the 0.05s-throttled `elapsed`)
    var levels: [Float] = []          // recent normalized levels (0…1), 30Hz — feeds the mic halo
    /// One bar of the live strip. ⚠️ The PERMANENT id is the point (his "wave stops moving for 2-3
    /// seconds" on 531): identified by array position, a full window's removeFirst+append made
    /// SwiftUI keep every bar where it stood and morph its HEIGHT to its neighbour's value — steady
    /// speech is all similar heights, so the strip read as frozen until something distinct (a
    /// silence) happened to pass. With a per-sample id the bars are the same views sliding one slot
    /// left each tick: true travel, whatever the loudness.
    struct LiveBar: Equatable, Identifiable { let id: Int; let level: Float }
    /// The live strip's scrolling window, sampled at 10Hz (every 3rd meter tick): bars enter on
    /// the right at a pace a person can follow and travel left — the reference's live view. 30Hz
    /// made the flow frantic; the whole-note compressed strip (tried 2026-08-11) re-bucketed on
    /// every tick and read as lag. This is the middle that looks alive.
    var liveWindow: [LiveBar] = []
    /// WHEN the newest bar landed, and how far apart two of them are.
    ///
    /// The strip used to get its whole motion from the array growing: one bar arrives, everything
    /// jumps 4.5pt left, ten times a second. That reads as travel only while the wave still has a
    /// FRONT crossing empty space — once it reaches the far edge (about five seconds in, at 45pt a
    /// second) the picture is full, and a packed band of same-height bars stepping in place looks
    /// stopped until a loud or quiet patch happens to pass through. That is the owner's 2026-08-13
    /// report, and it is the same complaint as the 531 one above with a different cause.
    ///
    /// With a stamp the strip can interpolate BETWEEN samples and travel at one constant speed, so
    /// there is nothing left to stall — see LiveWaveform.
    var liveStamp = Date.distantPast
    static let liveInterval: TimeInterval = 0.1   // 10Hz — must match the `liveTick % 3` gate below
    private var liveTick = 0
    private var liveSeq = 0
    private var allLevels: [Float] = []

    // ── Metering DSP state ──────────────────────────────────────────────────────────────────
    private var smoothed: Float = 0             // envelope-followed level (VU-meter ballistics output)
    private let meterHz: Double = 30            // 30 Hz sampling → smooth bars, low CPU
    private let tauAttack: Float = 0.050        // 50 ms rise  — fast attack (PPM-like), catches transients
    private let tauDecay:  Float = 0.300        // 300 ms fall — slow decay, the natural VU "settle"
    // −42, NOT −50 — his fresh-note test on build 530: silence still drew visible bars. At −50
    // ordinary room tone (−45…−38dB) landed at 10–25% and cleared every draw-time gate; with the
    // floor at −42 the quiet parts of a NEW recording store near zero and draw as the reference's
    // dots, while speech (−30dB and up) keeps the whole range above. Old notes keep their old data.
    private let noiseFloorDB: Float = -42       // below this = silence (0)
    private let waveWindow = 80                 // recent-levels window. The strip draws the WHOLE
                                                // note via liveBars() now; this window's remaining
                                                // customer is the mic halo (levels.last).
    private let maxWaveSamples = 900            // bounded streaming buffer (halved by RMS when exceeded)

    // Voice-tuned AAC: 24 kHz mono comfortably covers speech (≤ ~8 kHz voiced energy, Nyquist 12 kHz)
    // and ~40 kbps keeps the E2EE payload small (faster seal + upload) with no audible loss on speech.
    private let settings: [String: Any] = [
        AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
        AVSampleRateKey: 24_000,
        AVNumberOfChannelsKey: 1,
        AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        AVEncoderBitRateKey: 40_000,
    ]

    // Set when a call/Siri/alarm interrupted an in-flight recording: the partial note is PRESERVED
    // (paused, file kept) instead of discarded — the user can still send or cancel it (standard messengers keep an
    // interrupted draft; the old behavior deleted a long recording with no recovery).
    var wasInterrupted = false

    /// Does the user still want to be recording — the gesture's intent, as opposed to whether the
    /// mic has actually started. Set when a take is asked for, cleared by every path that ends one.
    /// It exists for the permission round trip, which is the one place where the answer can arrive
    /// long after the question stopped being relevant.
    private var wantsRecording = false

    init() {
        // Observe audio-session interruptions (phone call, Siri, alarm, another app grabbing the mic).
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self,
                  let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            switch type {
            case .began:
                guard self.isRecording else { return }
                self.recorder?.pause()          // keep the file + captured audio — do NOT discard
                self.timer?.invalidate(); self.timer = nil
                // ⛔ THE MIC IS NO LONGER CAPTURING, AND THE APP HAS TO SAY SO. `isRecording` cannot
                // carry this: the `.ended` branch below reads it to mean "the session is still
                // alive, nobody cancelled or sent" and would never resume if it were cleared here.
                // So capture is its own flag.
                //
                // What it was costing: the presence broadcast is driven off `isRecording`, which
                // stays true through an interruption, so taking a call mid-note told the other
                // person "recording voice message…" for the WHOLE call, re-asserted every ten
                // seconds — and the screen was held awake for it too. The comment at the broadcast
                // claims `isRecording` "flips for every path… including interruption". It did not.
                self.isCapturing = false
                // Nothing is being captured, so nothing is worth keeping the screen awake for. The
                // block was taken when the take started and only released on send/cancel, so a call
                // taken mid-note held the display on for the length of the call.
                Task { @MainActor in SleepBlocker.shared.remove("voice-record") }
                self.wasInterrupted = true      // the view flips to the locked bar (send/cancel the draft)
                self.onInterrupt?()
            case .ended:
                // Resume only if iOS says we should and the user hasn't finished/cancelled meanwhile.
                let opts = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt).map(AVAudioSession.InterruptionOptions.init)
                if self.wasInterrupted, self.isRecording, opts?.contains(.shouldResume) == true {
                    try? AVAudioSession.sharedInstance().setActive(true)
                    self.recorder?.record()
                    self.isCapturing = true
                    Task { @MainActor in SleepBlocker.shared.add("voice-record") }
                    // Re-arm metering: .began invalidated the timer, so without this the elapsed
                    // clock and live waveform stayed frozen after the interruption ended.
                    self.beginMetering(resuming: true)
                    self.wasInterrupted = false
                }
            @unknown default: break
            }
        }
    }

    deinit {
        if let o = interruptionObserver { NotificationCenter.default.removeObserver(o) }
    }

    // Pre-warm: activate the session + build & prepareToRecord a recorder AHEAD of time, so the
    // first hold-to-record fires `record()` with ~no latency. Call on chat open + after each send.
    func prepare() {
        guard recorder == nil else { return }
        AVAudioApplication.requestRecordPermission { [weak self] granted in
            guard let self, granted else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                let session = AVAudioSession.sharedInstance()
                try? session.setCategory(.playAndRecord, mode: .default, options: [.duckOthers])
                try? session.setActive(true)
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("voice-\(UUID().uuidString).m4a")
                guard let r = try? AVAudioRecorder(url: url, settings: self.settings) else { return }
                r.isMeteringEnabled = true
                r.prepareToRecord()
                DispatchQueue.main.async { if self.recorder == nil { self.recorder = r; self.fileURL = url } }
            }
        }
    }

    func requestAndStart() {
        // The intent to record, held for as long as the gesture is. See the guard in the cold path
        // below for what a grant arriving without it used to do.
        wantsRecording = true
        if let r = recorder {
            let s = AVAudioSession.sharedInstance()
            // ONLY reconfigure if the session isn't already recording-ready (e.g. voice playback left
            // it in .playback). `setActive(true)` synchronously negotiates with the audio hardware and
            // blocks the UI ~100–300ms — that was the hold-to-record lag. When the session is already
            // .playAndRecord (pre-warmed in prepare(), kept warm across records), skip it and record()
            // instantly. (First record right after playing a voice note still reconfigures.)
            if s.category != .playAndRecord {
                try? s.setCategory(.playAndRecord, mode: .default, options: [.duckOthers])
                try? s.setActive(true)
            }
            r.record(); beginMetering()   // already warmed → instant
            return
        }
        // Not warmed yet (permission just granted / first launch): set up then start.
        //
        // ⛔ THE FINGER HAS TO STILL BE DOWN WHEN THE ANSWER COMES BACK. On the first-ever hold iOS
        // puts up the permission alert, and putting it up CANCELS the touch — the composer runs its
        // cancel path and is back to normal before the user has finished reading the question.
        // Tapping Allow then landed here and started recording anyway, with no recording UI anywhere
        // on screen: the mic live, the screen held awake, and "recording voice message…" broadcast
        // to the other person every ten seconds until the ten-minute cap stopped it.
        //
        // A grant that arrives after the gesture has ended now does what the alert was actually for
        // — it records the permission — and nothing else. The next hold starts instantly, because by
        // then the warm path above has what it needs.
        AVAudioApplication.requestRecordPermission { [weak self] granted in
            guard let self, granted, self.wantsRecording else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                let session = AVAudioSession.sharedInstance()
                try? session.setCategory(.playAndRecord, mode: .default, options: [.duckOthers])
                try? session.setActive(true)
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("voice-\(UUID().uuidString).m4a")
                guard let r = try? AVAudioRecorder(url: url, settings: self.settings) else { return }
                r.isMeteringEnabled = true
                r.record()
                DispatchQueue.main.async { self.recorder = r; self.fileURL = url; self.beginMetering() }
            }
        }
    }

    private func beginMetering(resuming: Bool = false) {
        // `resuming` = restarting the timer after an interruption ends: skip the state reset so the
        // pre-interruption waveform/levels are kept (a full reset would wipe the captured envelope).
        if !resuming {
            isRecording = true; isCapturing = true; elapsed = 0; completedElapsed = 0; levels = []; liveWindow = []; allLevels = []; smoothed = 0
            limitFired = false
            Task { @MainActor in SleepBlocker.shared.add("voice-record") }   // no auto-lock mid-recording (sleep block)
        }
        timer?.invalidate()
        // Pre-compute the envelope smoothing coefficients from the fixed tick dt: a one-pole
        // low-pass, alpha = 1 − e^(−dt/τ). Fast attack τ + slow decay τ = real meter ballistics.
        let dt = Float(1.0 / meterHz)
        let aAttack = 1 - exp(-dt / tauAttack)
        let aDecay  = 1 - exp(-dt / tauDecay)
        // .common run-loop mode so elapsed/levels keep updating during gesture/scroll tracking.
        let t = Timer(timeInterval: 1.0 / meterHz, repeats: true) { [weak self] _ in
            guard let self, let r = self.recorder else { return }
            // Finished stretches + the live one: the clock a person watches never restarts at zero
            // just because they paused to listen and carried on.
            self.elapsed = self.completedElapsed + r.currentTime
            // The ceiling. Fired once per take — `limitFired` resets with the recorder in start().
            if !self.limitFired, self.elapsed >= Self.maxDuration {
                self.limitFired = true
                self.onReachedLimit?()
            }
            r.updateMeters()
            let target = self.perceptualLevel(rmsDB: r.averagePower(forChannel: 0),
                                              peakDB: r.peakPower(forChannel: 0))
            // Envelope follower: rise quickly toward louder targets, fall back slowly — the
            // characteristic "spring up, ease down" of an analogue meter (rectified one-pole IIR).
            let a = target > self.smoothed ? aAttack : aDecay
            self.smoothed += (target - self.smoothed) * a
            let level = self.smoothed
            self.levels.append(level)
            if self.levels.count > self.waveWindow {
                self.levels.removeFirst(self.levels.count - self.waveWindow)
            }
            self.liveTick += 1
            if self.liveTick % 3 == 0 {   // 10Hz into the visible strip
                self.liveWindow.append(LiveBar(id: self.liveSeq, level: level))
                self.liveSeq += 1
                self.liveStamp = Date()   // the strip's clock: it slides from here to the next one
                if self.liveWindow.count > self.waveWindow {
                    self.liveWindow.removeFirst(self.liveWindow.count - self.waveWindow)
                }
            }
            self.appendWaveSample(level)
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // dBFS (−∞…0) → perceptual 0…1. Fuses RMS "body" with peak "transients" in the LINEAR domain
    // (the physically correct place to mix amplitudes), converts back to dB (log ≈ perceptual), gates
    // the noise floor, and applies a mild power-law expansion so conversational speech fills the bars
    // without the loud syllables clipping to full scale.
    private func perceptualLevel(rmsDB: Float, peakDB: Float) -> Float {
        let rms  = pow(10, rmsDB  / 20)          // dBFS → linear amplitude 0…1
        let peak = pow(10, peakDB / 20)
        let amp  = max(0, 0.72 * rms + 0.28 * peak)
        let db   = amp > 1e-6 ? 20 * log10(amp) : -160
        let norm = max(0, min(1, (db - noiseFloorDB) / -noiseFloorDB))
        return pow(norm, 0.85)
    }

    // Bounded streaming buffer: when it fills, halve it by RMS-pairing (√((a²+b²)/2)) — an energy-
    // preserving decimation (a 1-level mip) so a 10-second and a 5-minute note both keep an accurate
    // envelope in O(maxWaveSamples) memory instead of growing without bound.
    private func appendWaveSample(_ v: Float) {
        allLevels.append(v)
        guard allLevels.count >= maxWaveSamples * 2 else { return }
        var reduced: [Float] = []; reduced.reserveCapacity(allLevels.count / 2 + 1)
        var i = 0
        while i < allLevels.count {
            if i + 1 < allLevels.count {
                let a = allLevels[i], b = allLevels[i + 1]
                reduced.append(sqrt((a * a + b * b) / 2))
            } else {
                reduced.append(allLevels[i])
            }
            i += 2
        }
        allLevels = reduced
    }

    // Reduce all captured levels to `count` bars via RMS per bucket (preserves perceived energy far
    // better than a plain mean, which washes out peaks), quantized to 0…100 for compact storage.
    private func waveform(_ count: Int = 40) -> [Int] {
        guard !allLevels.isEmpty else { return [] }
        let per = max(1, Int((Double(allLevels.count) / Double(count)).rounded(.up)))
        var bars: [Int] = []
        var i = 0
        while i < allLevels.count && bars.count < count {
            let slice = allLevels[i..<min(i + per, allLevels.count)]
            let ms = slice.reduce(Float(0)) { $0 + $1 * $1 } / Float(slice.count)
            bars.append(Int((sqrt(ms) * 100).rounded()))
            i += per
        }
        return bars
    }

    // MARK: - Pause = listen back, resume = a NEW stretch (segment stitching)
    //
    // ⚠️ THE NOTE IS A LIST OF FILES NOW, AND THE FORMAT IS WHY. An m4a's header is only written by
    // `stop()`, so a paused-but-unstopped file is NOT playable — and `AVAudioRecorder` cannot append
    // after `stop()`. The reference's pause offers BOTH listening and continuing, and one file can
    // never do both. So: every pause STOPS the current file (a finished, playable stretch), listening
    // plays the stretches stitched together, resuming records the next stretch to a fresh file, and
    // send stitches all of them into the one m4a that leaves the phone. A single-stretch note (the
    // common hold-release case) skips the stitch entirely — its file IS the note, same speed as ever.
    //
    // The stitch is `AVMutableComposition` + passthrough export: every stretch is recorded with the
    // identical AAC settings, so the bytes are copied, not re-encoded. A re-encode preset is the
    // fallback if the muxer ever refuses, because a slower send beats a lost note.

    /// The finished stretches so far, in order. The live recorder (if any) is the stretch in progress.
    private var segments: [(url: URL, duration: Double)] = []
    /// Sum of the finished stretches. The metering tick adds the live recorder's own clock on top,
    /// so `elapsed` keeps counting across a pause-and-resume instead of restarting at zero.
    private var completedElapsed: Double = 0
    /// The stitched preview, set by `pauseForReview`. ⚠️ Cleared by `resume()` — one more stretch and
    /// it no longer covers the whole note, and `finish()` trusts it only when it exists.
    private(set) var reviewURL: URL?
    private var reviewDuration: Double = 0
    private var reviewWaveform: [Int] = []

    /// Close the stretch in progress and file it. `max(currentTime, ...)` and not `currentTime`
    /// alone: AVAudioRecorder's currentTime is only valid WHILE RECORDING — on a recorder paused by
    /// an interruption it reads 0, and the old code binned whole notes on exactly that (his "after
    /// pause I cannot listen, cannot send" report). `elapsed - completedElapsed` is this class's own
    /// clock for the live stretch, frozen by the tick at the moment recording stopped.
    private func closeCurrentSegment() {
        guard let r = recorder, let url = fileURL else { return }
        let d = max(r.currentTime, elapsed - completedElapsed)
        r.stop()
        recorder = nil
        fileURL = nil
        if d > 0.05 {
            segments.append((url, d))
            completedElapsed += d
        } else {
            try? FileManager.default.removeItem(at: url)   // a stretch with nothing in it
        }
    }

    /// Pause: close the stretch, stitch what exists, hand back (previewURL, totalDuration, waveform).
    /// Returns nil only when there is nothing recorded at all (then it has cleaned up after itself).
    /// ⚠️ NO 1-second floor here, on purpose: a half-second stretch may be about to grow — the person
    /// can resume. The floor belongs to `finish()`, where the note actually leaves.
    func pauseForReview() async -> (URL, Double, [Int])? {
        timer?.invalidate(); timer = nil
        closeCurrentSegment()
        isRecording = false; isCapturing = false; wantsRecording = false
        Task { @MainActor in SleepBlocker.shared.remove("voice-record") }
        guard !segments.isEmpty else { reset(); return nil }
        let wf = waveform()
        guard let url = await stitched() else { cancel(); return nil }
        reviewURL = url
        reviewDuration = completedElapsed
        reviewWaveform = wf
        elapsed = completedElapsed
        return (url, completedElapsed, wf)
    }

    /// Continue recording after a pause-review: the next stretch goes to a fresh file. The audio
    /// session is still warm, so this starts as fast as the first touch did.
    ///
    /// ⚠️ `!isRecording`, NOT `recorder == nil`: an ADOPTED draft's chat has already run
    /// prepare() on appear, so a warmed idle recorder stands ready — the nil guard read that as
    /// "busy" and the review bar's red mic silently did nothing after a draft was adopted. A
    /// standing idle recorder IS the next stretch, pre-warmed; only actual recording refuses.
    func resume() {
        guard !isRecording, !segments.isEmpty else { return }
        // The preview no longer covers the note. A multi-stretch preview is its own stitched file
        // and would leak here; a single-stretch preview IS the stretch, so it must survive.
        if let r = reviewURL, !segments.contains(where: { $0.url == r }) {
            try? FileManager.default.removeItem(at: r)
        }
        reviewURL = nil; reviewDuration = 0; reviewWaveform = []
        if let r = recorder {
            let s = AVAudioSession.sharedInstance()
            if s.category != .playAndRecord {
                try? s.setCategory(.playAndRecord, mode: .default, options: [.duckOthers])
                try? s.setActive(true)
            }
            r.record()
        } else {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("voice-\(UUID().uuidString).m4a")
            guard let r = try? AVAudioRecorder(url: url, settings: settings) else { return }
            r.isMeteringEnabled = true
            r.record()
            recorder = r; fileURL = url
        }
        isRecording = true; isCapturing = true
        Task { @MainActor in SleepBlocker.shared.add("voice-record") }
        // `resuming: true` keeps the captured envelope and `completedElapsed`, so the waveform and
        // the clock carry on from where the pause left them.
        beginMetering(resuming: true)
    }

    /// One playable file for the whole note so far. A single stretch needs no work at all.
    private func stitched() async -> URL? {
        if segments.count == 1 { return segments[0].url }
        let comp = AVMutableComposition()
        guard let track = comp.addMutableTrack(withMediaType: .audio,
                                               preferredTrackID: kCMPersistentTrackID_Invalid) else { return nil }
        var cursor = CMTime.zero
        for seg in segments {
            let asset = AVURLAsset(url: seg.url)
            guard let aTrack = try? await asset.loadTracks(withMediaType: .audio).first,
                  let dur = try? await asset.load(.duration),
                  (try? track.insertTimeRange(CMTimeRange(start: .zero, duration: dur), of: aTrack, at: cursor)) != nil
            else { return nil }
            cursor = CMTimeAdd(cursor, dur)
        }
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-stitched-\(UUID().uuidString).m4a")
        for preset in [AVAssetExportPresetPassthrough, AVAssetExportPresetAppleM4A] {
            guard let ex = AVAssetExportSession(asset: comp, presetName: preset) else { continue }
            ex.outputURL = out
            ex.outputFileType = .m4a
            await ex.export()
            if ex.status == .completed { return out }
            try? FileManager.default.removeItem(at: out)
        }
        return nil
    }

    // MARK: - Recording drafts (the note survives leaving the chat, and the app itself)
    //
    // His order, the reference's behaviour: walking out of the chat — or out of the app — while a
    // hands-free recording runs must never lose the note. The recording STOPS (a stretch closes,
    // exactly like a pause) and everything moves into a per-chat draft folder in Application
    // Support, which survives relaunch. Coming back adopts the stretches into the recorder again
    // and the chat lands on the review bar: listen, keep recording, send or bin — nothing is gone
    // until the person says so.

    // MARK: - Bytes of a note that is still being sent

    /// ⛔ A FAILED VOICE NOTE USED TO LOSE ITS AUDIO WHEN THE APP RESTARTED, and the button to fix it
    /// stayed on screen looking like it would work.
    ///
    /// The optimistic bubble carries the recording in `Message.localAudioData`, in memory. That field
    /// is NOT in `Message.CodingKeys`, so when a pending message is written to disk the audio is
    /// dropped on the floor. Kill the app with a red voice bubble sitting there and it comes back
    /// with nothing inside: `resend` looks for `localAudioData`, finds nil, matches no branch, and
    /// does nothing at all. A dead button on top of a lost recording.
    ///
    /// The bytes go to a real file now, beside the parked drafts and for the same reason —
    /// Application Support survives relaunch where `temporaryDirectory` is purged by the OS whenever
    /// it feels like it. The path rides on `localMediaURL`, which IS persisted, so the retry has
    /// something to read whatever happened in between.
    private static func inFlightDir() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VoiceInFlight", isDirectory: true)
    }

    /// Parks the bytes of a note that is being sent. Returns the path for `Message.localMediaURL`,
    /// or nil if the write failed — in which case the send still goes ahead, it just cannot be
    /// retried after a restart, which is exactly where we were before.
    static func parkInFlight(_ data: Data, clientId: String) -> String? {
        let dir = inFlightDir()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(clientId).m4a")
        do { try data.write(to: url, options: .atomic); return url.path } catch { return nil }
    }

    static func inFlightData(clientId: String) -> Data? {
        try? Data(contentsOf: inFlightDir().appendingPathComponent("\(clientId).m4a"))
    }

    /// The note landed, or the person binned it. Either way the copy has no more work to do.
    static func dropInFlight(clientId: String) {
        try? FileManager.default.removeItem(at: inFlightDir().appendingPathComponent("\(clientId).m4a"))
    }

    /// Anything still here after a week belongs to a send nobody is coming back for — a bubble
    /// dismissed, a chat cleared, an account signed out. Swept at launch so this folder cannot grow
    /// forever on a phone that has a bad month of signal.
    static func sweepInFlight() {
        let dir = inFlightDir()
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-7 * 24 * 3600)
        for url in items {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified < cutoff { try? FileManager.default.removeItem(at: url) }
        }
    }

    /// ⛔ EVERY PARKED RECORDING, FOR SIGN-OUT AND ACCOUNT DELETION.
    ///
    /// `discardDraft` takes one conversation and `sweepInFlight` only drops what is old, so neither
    /// answers "this account is leaving the phone". `SessionWipe` cleared the decrypted media caches
    /// and missed these two roots entirely — and the asymmetry is worth stating, because it is the
    /// opposite of what you would guess: those caches hold audio that was DECRYPTED from the server,
    /// while these hold audio that was never encrypted at all. Record a note, leave the chat so it
    /// parks, sign out, and the next person to use the phone had it.
    ///
    /// Whole directories rather than per-conversation, because at wipe time there is no list of
    /// conversations left to walk.
    static func wipeAllDrafts() {
        let fm = FileManager.default
        let root = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? fm.removeItem(at: root.appendingPathComponent("VoiceDrafts", isDirectory: true))
        try? fm.removeItem(at: inFlightDir())
    }

    private static func draftDir(_ cid: String) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VoiceDrafts", isDirectory: true)
            .appendingPathComponent(cid, isDirectory: true)
    }

    static func hasDraft(_ cid: String) -> Bool {
        FileManager.default.fileExists(atPath: draftDir(cid).appendingPathComponent("meta.json").path)
    }

    /// Chat-list index of parked drafts: cid → total seconds. Loaded from disk once at first read,
    /// kept true by park/discard, so the list rows (his reference screenshots: "Draft: 🎤 0:05")
    /// never touch the filesystem per render.
    static private(set) var draftIndex: [String: Double] = loadDraftIndex()
    private static func loadDraftIndex() -> [String: Double] {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VoiceDrafts", isDirectory: true)
        guard let kids = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        else { return [:] }
        var out: [String: Double] = [:]
        for k in kids where k.hasDirectoryPath {
            if let data = try? Data(contentsOf: k.appendingPathComponent("meta.json")),
               let meta = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let durations = meta["durations"] as? [Double] {
                out[k.lastPathComponent] = durations.reduce(0, +)
            }
        }
        return out
    }

    /// The draft is spent (sent or binned) — its folder goes with it.
    static func discardDraft(_ cid: String) {
        try? FileManager.default.removeItem(at: draftDir(cid))
        draftIndex.removeValue(forKey: cid)
    }

    /// Close the live stretch and move every stretch into the draft folder. The recorder resets
    /// and re-warms; the note waits on disk. Staged through a sibling folder because an ADOPTED
    /// draft's stretches already live in the destination — removing the folder first would have
    /// deleted the very files being parked.
    func parkDraft(cid: String) {
        timer?.invalidate(); timer = nil
        closeCurrentSegment()
        isRecording = false; isCapturing = false; wantsRecording = false
        Task { @MainActor in SleepBlocker.shared.remove("voice-record") }
        guard !segments.isEmpty else { reset(); return }
        let fm = FileManager.default
        let dir = Self.draftDir(cid)
        let staging = dir.deletingLastPathComponent().appendingPathComponent(cid + ".staging", isDirectory: true)
        try? fm.removeItem(at: staging)
        try? fm.createDirectory(at: staging, withIntermediateDirectories: true)
        var files: [String] = [], durations: [Double] = []
        for (i, seg) in segments.enumerated() {
            let name = "seg\(i).m4a"
            try? fm.moveItem(at: seg.url, to: staging.appendingPathComponent(name))
            files.append(name); durations.append(seg.duration)
        }
        let meta: [String: Any] = ["files": files, "durations": durations, "bars": waveform(64)]
        if let data = try? JSONSerialization.data(withJSONObject: meta) {
            try? data.write(to: staging.appendingPathComponent("meta.json"))
        }
        try? fm.removeItem(at: dir)
        try? fm.moveItem(at: staging, to: dir)
        Self.draftIndex[cid] = completedElapsed   // the chat list's "Draft: 🎤 0:05" reads this
        // A stitched preview lives in tmp and is not a stretch — it does not follow the draft.
        if let r = reviewURL { try? fm.removeItem(at: r) }
        segments = []   // the files are the draft's now; reset() must not think they are its own
        reset()
    }

    /// Coming back to a chat with a parked note: the draft's stretches become the recorder's
    /// segments again, ready for pauseForReview (listen), resume (keep recording), send or trash.
    func adoptDraft(cid: String) -> Bool {
        guard !isRecording else { return false }   // a live recording always wins over a parked one
        let dir = Self.draftDir(cid)
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("meta.json")),
              let meta = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let files = meta["files"] as? [String],
              let durations = meta["durations"] as? [Double],
              files.count == durations.count, !files.isEmpty else { return false }
        segments = zip(files, durations).map { (url: dir.appendingPathComponent($0), duration: $1) }
        completedElapsed = durations.reduce(0, +)
        elapsed = completedElapsed
        // Re-seed the level history from the stored bars, so the review (and any stretch recorded
        // after it) draws the note's real shape instead of a flat fallback.
        if let bars = meta["bars"] as? [Int] {
            allLevels = bars.map { Float(max(0, min(100, $0))) / 100 }
        }
        return true
    }

    private func cleanupSegmentFiles() {
        for s in segments { try? FileManager.default.removeItem(at: s.url) }
        if let r = reviewURL, !segments.contains(where: { $0.url == r }) {
            try? FileManager.default.removeItem(at: r)
        }
        segments = []
    }

    /// Stop and return (data, duration, waveform) for the WHOLE note, every stretch included.
    /// nil if too short or failed. Async because a multi-stretch note has to stitch first — the
    /// single-stretch case (every plain hold-release) touches no exporter and is as fast as ever.
    func finish() async -> (Data, Double, [Int])? {
        timer?.invalidate(); timer = nil
        // Send tapped straight off the recording bar: the live stretch joins the list first.
        closeCurrentSegment()
        let duration = completedElapsed
        let wf = reviewWaveform.isEmpty ? waveform() : reviewWaveform
        // The review preview IS the stitched note whenever it exists — `resume()` clears it the
        // moment one more stretch makes it stale, so trusting it here is safe, and it saves
        // stitching the same audio twice for the pause-listen-send flow.
        var url = reviewURL
        if url == nil { url = await stitched() }
        defer { cleanupSegmentFiles(); reset() }
        // Floor at 1.0s: anything shorter displays as "0:00" (Int-floored) — never send a 0:00 note.
        guard duration >= 1.0, let u = url, let data = try? Data(contentsOf: u) else { return nil }
        return (data, duration, wf)
    }

    func cancel() {
        timer?.invalidate(); timer = nil
        recorder?.stop()
        if let u = fileURL { try? FileManager.default.removeItem(at: u) }
        cleanupSegmentFiles()   // every finished stretch, and the stitched preview if one exists
        reset()
    }

    private func reset() {
        isRecording = false; isCapturing = false; wantsRecording = false
        Task { @MainActor in SleepBlocker.shared.remove("voice-record") }
        recorder = nil
        fileURL = nil
        // ⚠️ CLEARED HERE OR THE NEXT NOTE IS THE LAST ONE. `finish()` reads `reviewURL` first, so
        // leaving it set after a send or a cancel would make the following recording return the
        // PREVIOUS note's audio — and it would look like a send bug, not a state bug.
        reviewURL = nil
        reviewDuration = 0
        reviewWaveform = []
        segments = []
        completedElapsed = 0
        levels = []
        liveWindow = []
        allLevels = []
        // Do NOT setActive(false) here: prepare() below immediately setActive(true)s again, so the
        // deactivate→reactivate churn only made the next hold-to-record re-activate the session from
        // cold (the "long sluggish delay before recording starts"). Keeping the session warm lets
        // requestAndStart's record() fire instantly on touch-down.
        prepare()   // re-warm the recorder so the NEXT hold-to-record is instant too
    }
}
