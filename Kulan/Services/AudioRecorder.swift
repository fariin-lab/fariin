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
    var isRecording = false
    var elapsed: TimeInterval = 0
    var currentTime: TimeInterval { recorder?.currentTime ?? 0 }   // live (not the 0.05s-throttled `elapsed`)
    var levels: [Float] = []          // recent normalized levels (0…1) for the live waveform
    private var allLevels: [Float] = []

    // ── Metering DSP state ──────────────────────────────────────────────────────────────────
    private var smoothed: Float = 0             // envelope-followed level (VU-meter ballistics output)
    private let meterHz: Double = 30            // 30 Hz sampling → smooth bars, low CPU
    private let tauAttack: Float = 0.050        // 50 ms rise  — fast attack (PPM-like), catches transients
    private let tauDecay:  Float = 0.300        // 300 ms fall — slow decay, the natural VU "settle"
    private let noiseFloorDB: Float = -50       // below this = silence (0)
    private let waveWindow = 48                 // live scrolling bar count
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
    // (paused, file kept) instead of discarded — the user can still send or cancel it (Signal keeps an
    // interrupted draft; the old behavior deleted a long recording with no recovery).
    var wasInterrupted = false

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
                self.wasInterrupted = true      // the view flips to the locked bar (send/cancel the draft)
                self.onInterrupt?()
            case .ended:
                // Resume only if iOS says we should and the user hasn't finished/cancelled meanwhile.
                let opts = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt).map(AVAudioSession.InterruptionOptions.init)
                if self.wasInterrupted, self.isRecording, opts?.contains(.shouldResume) == true {
                    try? AVAudioSession.sharedInstance().setActive(true)
                    self.recorder?.record()
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
        if let r = recorder {
            let s = AVAudioSession.sharedInstance()
            // ONLY reconfigure if the session isn't already recording-ready (e.g. voice playback left
            // it in .playback). `setActive(true)` synchronously negotiates with the audio hardware and
            // blocks the UI ~100–300ms — that was the hold-to-record lag. When the session is already
            // .playAndRecord (pre-warmed in prepare(), kept warm across records), skip it and record()
            // instantly, like Signal. (First record right after playing a voice note still reconfigures.)
            if s.category != .playAndRecord {
                try? s.setCategory(.playAndRecord, mode: .default, options: [.duckOthers])
                try? s.setActive(true)
            }
            r.record(); beginMetering()   // already warmed → instant
            return
        }
        // Not warmed yet (permission just granted / first launch): set up then start.
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
                r.record()
                DispatchQueue.main.async { self.recorder = r; self.fileURL = url; self.beginMetering() }
            }
        }
    }

    private func beginMetering() {
        isRecording = true; elapsed = 0; levels = []; allLevels = []; smoothed = 0
        Task { @MainActor in SleepBlocker.shared.add("voice-record") }   // no auto-lock mid-recording (Signal's sleep block)
        timer?.invalidate()
        // Pre-compute the envelope smoothing coefficients from the fixed tick dt: a one-pole
        // low-pass, alpha = 1 − e^(−dt/τ). Fast attack τ + slow decay τ = real meter ballistics.
        let dt = Float(1.0 / meterHz)
        let aAttack = 1 - exp(-dt / tauAttack)
        let aDecay  = 1 - exp(-dt / tauDecay)
        // .common run-loop mode so elapsed/levels keep updating during gesture/scroll tracking.
        let t = Timer(timeInterval: 1.0 / meterHz, repeats: true) { [weak self] _ in
            guard let self, let r = self.recorder else { return }
            self.elapsed = r.currentTime
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

    /// Stop and return (data, duration, waveform). nil if too short or failed.
    func finish() -> (Data, Double, [Int])? {
        timer?.invalidate(); timer = nil
        guard let recorder, let url = fileURL else { reset(); return nil }
        let duration = recorder.currentTime
        recorder.stop()
        let wf = waveform()
        reset()
        guard duration >= 0.5, let data = try? Data(contentsOf: url) else {
            try? FileManager.default.removeItem(at: url)   // don't leak temp files for tap-too-short clips
            return nil
        }
        return (data, duration, wf)
    }

    func cancel() {
        timer?.invalidate(); timer = nil
        recorder?.stop()
        if let u = fileURL { try? FileManager.default.removeItem(at: u) }
        reset()
    }

    private func reset() {
        isRecording = false
        Task { @MainActor in SleepBlocker.shared.remove("voice-record") }
        recorder = nil
        levels = []
        allLevels = []
        // Do NOT setActive(false) here: prepare() below immediately setActive(true)s again, so the
        // deactivate→reactivate churn only made the next hold-to-record re-activate the session from
        // cold (the "long sluggish delay before recording starts"). Keeping the session warm lets
        // requestAndStart's record() fire instantly on touch-down.
        prepare()   // re-warm the recorder so the NEXT hold-to-record is instant too
    }
}
