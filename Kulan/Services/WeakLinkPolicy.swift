import Foundation

// The pause/resume DECISION for the 1:1 weak-signal video fallback, with nothing else attached.
//
// Pulled out of CallService so it can be tested at all. In place it was reachable only through a
// live RTCPeerConnection, a running timer, and a Firestore write, so the one part worth checking
// (does it wait the full window, and does it refuse to flap) could not be checked without a call.
//
// Pure by design: it owns no clock and performs no side effects. `now` is passed in, which is what
// lets a test drive fifteen seconds of call in an instant instead of sleeping through them.
struct WeakLinkPolicy {
    enum Decision: Equatable { case none, pause, resume }

    /// Below this the link cannot carry even the lowest useful video, and the frames pushed into it
    /// come straight out of the audio the call actually needs.
    let floorBitrate: Double
    /// Slow in BOTH directions, on purpose. A bare threshold flaps: the estimate wanders across the
    /// line and video blinks on and off, which is worse to sit through than the poor video it is
    /// preventing. Recovery is slower still, so video only returns when it will hold.
    let pauseAfter: TimeInterval
    let resumeAfter: TimeInterval

    private(set) var poorSince: Date?
    private(set) var goodSince: Date?

    init(floorBitrate: Double = 50_000, pauseAfter: TimeInterval = 5, resumeAfter: TimeInterval = 10) {
        self.floorBitrate = floorBitrate
        self.pauseAfter = pauseAfter
        self.resumeAfter = resumeAfter
    }

    /// Forget both windows. Called when the user works the camera by hand, so their intent restarts
    /// the clock rather than inheriting a verdict formed before they touched it.
    mutating func reset() { poorSince = nil; goodSince = nil }

    /// `paused` is the CURRENT state, so this never asks for something already done.
    /// A nil or zero `bitrate` means no estimate yet: the candidate pair is still forming, or the
    /// peer does not report one. That decides NOTHING. Treating unknown as bad would blank a healthy
    /// call's video every time it connected.
    mutating func evaluate(bitrate: Double?, paused: Bool, now: Date) -> Decision {
        guard let bitrate, bitrate > 0 else { reset(); return .none }

        if bitrate < floorBitrate {
            goodSince = nil
            let since = poorSince ?? now
            poorSince = since
            if !paused, now.timeIntervalSince(since) >= pauseAfter { return .pause }
        } else {
            poorSince = nil
            let since = goodSince ?? now
            goodSince = since
            if paused, now.timeIntervalSince(since) >= resumeAfter { return .resume }
        }
        return .none
    }
}
