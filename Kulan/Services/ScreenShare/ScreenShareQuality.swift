import Foundation

/// The sharer's quality ladder for a 1:1 screen share, with nothing else attached: which encoder
/// tier to run, decided from one stats sample every 2s. Pure (no clock, no WebRTC, no side effects),
/// like WeakLinkPolicy, so the decision can be checked without a call.
///
/// Owner, 2026-10-08: the shared screen must stay clearly visible and stable on a bad network. A
/// screen is mostly text, so the ladder gives up FRAME RATE first and resolution last (the encoder
/// runs maintainResolution throughout); only the bottom tier scales the picture down, and only
/// because by then the alternative is a frozen picture.
///
/// Replaces audit M-107's single 2 Mbps / 600 kbps switch, keeping its intent: a share on a weak
/// link must leave room for the voice, and must find its way back up once the link recovers.
struct ScreenShareQuality {
    struct Tier: Equatable {
        let maxBitrate: Int
        let maxFramerate: Int
        /// 1 = full size. Only the last tier shrinks the picture.
        let scaleDown: Double
    }

    /// Best first. One step at a time in either direction.
    static let tiers: [Tier] = [
        Tier(maxBitrate: 2_500_000, maxFramerate: 20, scaleDown: 1),     // T0
        Tier(maxBitrate: 1_200_000, maxFramerate: 15, scaleDown: 1),     // T1
        Tier(maxBitrate: 600_000, maxFramerate: 10, scaleDown: 1),       // T2
        Tier(maxBitrate: 300_000, maxFramerate: 6, scaleDown: 1.5)       // T3
    ]

    /// One stats read. Any field can be missing (the pair is still forming, the far side has not
    /// sent a receiver report yet); missing means "no evidence", never "bad".
    struct Sample {
        /// candidate-pair availableOutgoingBitrate, bits per second.
        var availableBitrate: Double?
        /// What the video sender actually sent since the last sample, bits per second.
        var sendBitrate: Double?
        /// remote-inbound-rtp fractionLost, 0...1.
        var fractionLost: Double?
        /// remote-inbound-rtp roundTripTime, seconds.
        var roundTripTime: Double?
        /// outbound-rtp qualityLimitationReason == "bandwidth": WebRTC's own verdict.
        var bandwidthLimited = false
    }

    /// Two bad samples in a row (4s) step down; five good ones (10s) step up. Slow up, quick down:
    /// a picture that keeps changing quality is worse to watch than one that stays a notch lower.
    static let stepDownAfter = 2
    static let stepUpAfterBase = 5
    /// A step up that is undone within this many samples was premature: the next one waits twice as
    /// long (up to `stepUpAfterMax`), so a link that cannot hold the higher tier does not see-saw.
    static let failedStepUpWithin = 10
    static let stepUpAfterMax = 30
    /// A tier held this long after a step up proves the link; the wait drops back to the base.
    static let provenAfter = 15

    private(set) var index = 0
    private var badRun = 0
    private var goodRun = 0
    private var stepUpAfter = Self.stepUpAfterBase
    /// Samples since the last step up, nil when the last change was a step down (or none yet).
    private var sinceStepUp: Int?

    var tier: Tier { Self.tiers[index] }

    /// Each share starts at the top.
    mutating func reset() {
        index = 0; badRun = 0; goodRun = 0
        stepUpAfter = Self.stepUpAfterBase; sinceStepUp = nil
    }

    /// Feeds one sample; true when the tier changed (the caller then applies `tier`).
    mutating func evaluate(_ s: Sample) -> Bool {
        if let n = sinceStepUp {
            sinceStepUp = n + 1
            if n + 1 >= Self.provenAfter { stepUpAfter = Self.stepUpAfterBase; sinceStepUp = nil }
        }
        guard let bad = isBad(s) else { return false }   // no evidence either way: windows unchanged
        if bad {
            goodRun = 0
            badRun += 1
            guard badRun >= Self.stepDownAfter, index < Self.tiers.count - 1 else { return false }
            if let n = sinceStepUp, n < Self.failedStepUpWithin {
                stepUpAfter = min(stepUpAfter * 2, Self.stepUpAfterMax)
            }
            index += 1; badRun = 0; sinceStepUp = nil
            return true
        }
        badRun = 0
        goodRun += 1
        guard goodRun >= stepUpAfter, index > 0 else { return false }
        index -= 1; goodRun = 0; sinceStepUp = 0
        return true
    }

    /// Nil = nothing to judge by.
    private func isBad(_ s: Sample) -> Bool? {
        if s.bandwidthLimited { return true }
        if let loss = s.fractionLost, loss > 0.05 { return true }
        if let rtt = s.roundTripTime, rtt > 0.6 { return true }
        if let available = s.availableBitrate, available > 0 {
            // ⚠️ THE ESTIMATE FOLLOWS WHAT IS SENT. A still screen sends a frame a second, and the
            // estimate sinks to match; read on its own, a perfectly healthy link would look "weak"
            // and walk the share down to the bottom tier. The bitrate rule only counts while the
            // sender is actually using most of what the link offers (the link, not the screen, is
            // the limit). That is the trap audit M-107 round 2 fell into from the other side.
            let linkIsTheLimit = (s.sendBitrate ?? 0) >= available * 0.6
            if linkIsTheLimit, available < Double(tier.maxBitrate) * 1.2 { return true }
            return false
        }
        if s.fractionLost != nil || s.roundTripTime != nil { return false }
        return nil
    }
}
