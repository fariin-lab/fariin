import Foundation

// Generates standard call-progress tones as in-memory WAV data — no bundled assets.
// Ringback: what the caller hears while waiting ("ring… ring…"). Busy: declined /
// unavailable. Ended: a short descending two-beep when a connected call hangs up.
// These mirror the call-state sounds big messaging apps play.
enum RingbackTone {
    // ⛔ HEARD AT ARM'S LENGTH — Kasim 2026-10-22: the big apps' ring is heard without the speaker
    // on, ours was not. Two causes, both fixed here for the calling, ringing and busy sounds:
    //   • LEVEL. The rings peaked near 11000 of 32767 (~-9.5 dBFS); `level` is ~70% of full
    //     (~-3 dBFS), about 6.5 dB louder, which reads as roughly 1.5x as loud.
    //   • Every ring fades in and out over 20-40 ms so the louder level does not click.
    // ⛔ NO OCTAVE ON TOP — Kasim 2026-10-22 on build 1008: a softer copy one octave up (880/960 Hz)
    // was added for the earpiece, and it changed the CHARACTER of the ring away from the one people
    // know. The plain two-note tone is back; only the level stays raised.
    // Volume still follows iOS's call volume (the player runs in the call's audio session).
    private static let level = 23000.0
    /// The two notes of a tone, peak at most 1.
    private static func tone(_ t: Double, _ a: Double, _ b: Double) -> Double {
        (sin(2 * .pi * a * t) + sin(2 * .pi * b * t)) / 2
    }
    /// 0...1 fade at both ends of a sound `length` seconds long, `t` seconds in.
    private static func fade(_ t: Double, _ length: Double, _ edge: Double = 0.02) -> Double {
        max(0, min(1, t / edge, (length - t) / edge))
    }

    // Ringback (440+480 Hz) at the standard cadence for these two notes: 2s ring / 4s quiet (6s
    // cycle). Owner 2026-10-26 timed the big messenger at ~1.9s / ~3.9s by hand, which is this
    // cadence; the earlier 1.8 / 3.4 came back a little too soon. Looped forever by the player.
    static func wavData(sampleRate: Int = 8000) -> Data {
        let cycle = 6.0
        let total = Int(Double(sampleRate) * cycle)   // one cadence cycle, looped by the player
        var samples = [Int16](repeating: 0, count: total)
        for i in 0..<total {
            let t = Double(i) / Double(sampleRate)
            let phase = t.truncatingRemainder(dividingBy: cycle)
            if phase < 2.0 {   // 2s on, 4s off
                samples[i] = Int16(max(-1, min(1, tone(t, 440, 480))) * level * fade(phase, 2.0))
            }
        }
        return wav(samples, sampleRate: sampleRate)
    }

    // US-style busy / "declined" tone (480+620 Hz, 0.5s on / 0.5s off), one cycle —
    // the player loops it a few times. Tells the caller the other side rejected /
    // couldn't be reached.
    static func busyData(sampleRate: Int = 8000) -> Data {
        let total = sampleRate                      // 1s = one on/off cycle
        var samples = [Int16](repeating: 0, count: total)
        for i in 0..<total {
            let t = Double(i) / Double(sampleRate)
            let phase = t.truncatingRemainder(dividingBy: 1.0)
            if phase < 0.5 {   // 0.5 on, 0.5 off
                samples[i] = Int16(max(-1, min(1, tone(t, 480, 620))) * level * fade(phase, 0.5))
            }
        }
        return wav(samples, sampleRate: sampleRate)
    }

    // Short descending two-beep played once when a connected call ends — so both
    // sides actually hear that it's over (no PSTN standard; matches app convention).
    static func endedData(sampleRate: Int = 8000) -> Data {
        let beep = 0.16, gap = 0.05
        let total = Int(Double(sampleRate) * (beep * 2 + gap))
        var samples = [Int16](repeating: 0, count: total)
        for i in 0..<total {
            let t = Double(i) / Double(sampleRate)
            var v = 0.0
            if t < beep { v = sin(2 * .pi * 520 * t) }                       // first beep
            else if t > beep + gap { v = sin(2 * .pi * 410 * t) }            // lower beep
            // gentle fade so the tone doesn't click
            let env = 1.0 - min(1.0, abs((t.truncatingRemainder(dividingBy: beep + gap)) - beep / 2) / (beep))
            samples[i] = Int16(max(-1, min(1, v)) * 9000 * max(0.2, env))
        }
        return wav(samples, sampleRate: sampleRate)
    }

    // Owner, 2026-10-10: a short, soft RISING two-note chime when the other person turns their
    // camera on mid-call (voice becoming video). Quieter than the end tone, about a third of a
    // second, each note faded in and out so nothing clicks over their voice.
    static func videoOnData(sampleRate: Int = 16000) -> Data {
        let note = 0.12, gap = 0.04
        let total = Int(Double(sampleRate) * (note * 2 + gap))
        var samples = [Int16](repeating: 0, count: total)
        for i in 0..<total {
            let t = Double(i) / Double(sampleRate)
            var v = 0.0, local = 0.0
            if t < note { v = sin(2 * .pi * 660 * t); local = t }
            else if t > note + gap { v = sin(2 * .pi * 880 * t); local = t - note - gap }
            let env = sin(.pi * min(1, max(0, local / note)))   // smooth in and out
            samples[i] = Int16(v * 5200 * env)
        }
        return wav(samples, sampleRate: sampleRate)
    }

    private static func wav(_ samples: [Int16], sampleRate: Int) -> Data {
        var d = Data()
        let dataBytes = samples.count * 2
        func str(_ s: String) { d.append(contentsOf: Array(s.utf8)) }
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        str("RIFF"); u32(UInt32(36 + dataBytes)); str("WAVE")
        str("fmt "); u32(16); u16(1); u16(1)
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        str("data"); u32(UInt32(dataBytes))
        for s in samples { var x = s.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        return d
    }
}
