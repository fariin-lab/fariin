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
    //   • PITCH. The earpiece is weak below ~1 kHz, where the classic 440/480 Hz pair sits. A quieter
    //     copy one octave up (880/960 Hz) is added (`tone`): heard as the same ring, but the
    //     earpiece can carry it. Every ring fades in and out over 20-40 ms so the louder level
    //     does not click.
    // Volume still follows iOS's call volume (the player runs in the call's audio session).
    private static let level = 23000.0
    /// The two notes of a tone plus their softer octave, peak at most 1.
    private static func tone(_ t: Double, _ a: Double, _ b: Double) -> Double {
        let base = (sin(2 * .pi * a * t) + sin(2 * .pi * b * t)) / 2
        let octave = (sin(2 * .pi * 2 * a * t) + sin(2 * .pi * 2 * b * t)) / 2
        return 0.75 * base + 0.25 * octave
    }
    /// 0...1 fade at both ends of a sound `length` seconds long, `t` seconds in.
    private static func fade(_ t: Double, _ length: Double, _ edge: Double = 0.02) -> Double {
        max(0, min(1, t / edge, (length - t) / edge))
    }

    // Ringback (440+480 Hz), reference-style cadence, user-tuned 2026-07-22: 1.8s ring / 3.4s quiet
    // (5.2s cycle). The old 1.2s gap rang again too soon and sounded like one constant noise
    // instead of a phone ringing. Looped forever by the player.
    static func wavData(sampleRate: Int = 8000) -> Data {
        let cycle = 5.2
        let total = Int(Double(sampleRate) * cycle)   // one cadence cycle, looped by the player
        var samples = [Int16](repeating: 0, count: total)
        for i in 0..<total {
            let t = Double(i) / Double(sampleRate)
            let phase = t.truncatingRemainder(dividingBy: cycle)
            if phase < 1.8 {   // 1.8s on, 3.4s off
                samples[i] = Int16(max(-1, min(1, tone(t, 440, 480))) * level * fade(phase, 1.8))
            }
        }
        return wav(samples, sampleRate: sampleRate)
    }

    // Kasim 2026-10-21, timed on the other big app: the caller's FIRST ring is always the ordinary
    // short one, and every ring after it is a LONGER beep with a short pause ("a long beep with a
    // long stop would be weird"). So when "Calling..." already played the short ring, ringing starts
    // long (`shortFirst: false`); when it rings at once, its first ring is the short one. Same
    // 440+480 Hz as the calling sound above. One file holds 90s of rings, past any ring timeout,
    // because a looped file would start again with the short ring.
    static let longRingSeconds = 6.0
    static func ringingData(shortFirst: Bool, sampleRate: Int = 8000) -> Data {
        let gap = 2.2   // Kasim 2026-10-22 timed the other big app at ~11s ring, ~4s quiet (73% sound); same share, shorter ring
        var rings: [(start: Double, length: Double)] = shortFirst ? [(0, 1.8)] : []   // the short first ring
        var t0 = shortFirst ? 1.8 + gap : 0
        while t0 < 90 { rings.append((t0, longRingSeconds)); t0 += longRingSeconds + gap }
        let total = Int(Double(sampleRate) * t0)
        var samples = [Int16](repeating: 0, count: total)
        for r in rings {
            let from = Int(r.start * Double(sampleRate)), count = Int(r.length * Double(sampleRate))
            for i in 0..<count where from + i < total {
                let t = Double(i) / Double(sampleRate)
                // 40 ms fades at both ends, so a ring does not click on or off.
                samples[from + i] = Int16(max(-1, min(1, tone(t, 440, 480))) * level * fade(t, r.length, 0.04))
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
