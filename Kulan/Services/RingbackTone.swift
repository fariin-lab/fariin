import Foundation

// Generates standard call-progress tones as in-memory WAV data — no bundled assets.
// Ringback: what the caller hears while waiting ("ring… ring…"). Busy: declined /
// unavailable. Ended: a short descending two-beep when a connected call hangs up.
// These mirror the call-state sounds big messaging apps play.
enum RingbackTone {
    // Ringback (440+480 Hz), Signal-style cadence, user-tuned 2026-07-22: 1.8s ring / 3.4s quiet
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
                let v = (sin(2 * .pi * 440 * t) + sin(2 * .pi * 480 * t)) / 2
                samples[i] = Int16(max(-1, min(1, v)) * 11000)
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
            if t.truncatingRemainder(dividingBy: 1.0) < 0.5 {   // 0.5 on, 0.5 off
                let v = (sin(2 * .pi * 480 * t) + sin(2 * .pi * 620 * t)) / 2
                samples[i] = Int16(max(-1, min(1, v)) * 10000)
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
