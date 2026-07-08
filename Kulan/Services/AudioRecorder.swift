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
    var isRecording = false
    var elapsed: TimeInterval = 0
    var currentTime: TimeInterval { recorder?.currentTime ?? 0 }   // live (not the 0.05s-throttled `elapsed`)
    var levels: [Float] = []          // recent normalized levels (0…1) for the live waveform
    private var allLevels: [Float] = []

    private let settings: [String: Any] = [
        AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
        AVSampleRateKey: 44_100,
        AVNumberOfChannelsKey: 1,
        AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
    ]

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
            // Re-assert record category — VoiceMessageView playback leaves the session in .playback,
            // which would make record() silently fail (H1). Cheap, runs on every start.
            let s = AVAudioSession.sharedInstance()
            try? s.setCategory(.playAndRecord, mode: .default, options: [.duckOthers])
            try? s.setActive(true)
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
        isRecording = true; elapsed = 0; levels = []; allLevels = []
        timer?.invalidate()
        // .common run-loop mode so elapsed/levels keep updating during gesture/scroll tracking.
        let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self, let r = self.recorder else { return }
            self.elapsed = r.currentTime
            r.updateMeters()
            let level = self.normalize(r.averagePower(forChannel: 0))
            self.allLevels.append(level)
            self.levels.append(level)
            if self.levels.count > 48 { self.levels.removeFirst(self.levels.count - 48) }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // dBFS (−160…0) → 0…1 with a −50 dB silence floor (Signal's threshold idea).
    private func normalize(_ dB: Float) -> Float {
        let floor: Float = -50
        let clamped = max(floor, min(0, dB))
        return (clamped - floor) / -floor
    }

    // Reduce all captured levels to `count` bars, quantized to 0…100 for compact storage.
    private func waveform(_ count: Int = 40) -> [Int] {
        guard !allLevels.isEmpty else { return [] }
        let per = max(1, allLevels.count / count)
        var bars: [Int] = []
        var i = 0
        while i < allLevels.count && bars.count < count {
            let slice = allLevels[i..<min(i + per, allLevels.count)]
            let avg = slice.reduce(0, +) / Float(slice.count)
            bars.append(Int((avg * 100).rounded()))
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
