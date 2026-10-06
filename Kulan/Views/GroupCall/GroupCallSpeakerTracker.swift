import Foundation

/// Decides who the ONE "active speaker" is, so the highlight does not flicker (owner spec §8: who
/// is speaking must be obvious; §12: no jumps). LiveKit's raw `isSpeaking` flips on every breath, so
/// the stage feeds it through this state machine.
///
/// Pure value type, no timers (the caller feeds it on every room update AND on a 0.25s tick, so
/// the time rules below get re-evaluated even when the room is quiet).
///
/// Rules:
/// 1. QUALIFY: someone becomes a candidate only after being in the speaking set continuously for
///    `qualifyDelay` (0.3s). A cough or a single noisy frame never moves the highlight (§8).
///    Dropping out of the set even once resets that person's clock.
/// 2. HOLD: the current speaker stays highlighted while silent, for `GroupCallMetrics.speakerHold`
///    (1.5s) after they were last heard. Pauses between words do not blank the ring (§8/§12).
///    After that, with nobody qualified, `activeSpeakerId` becomes nil.
/// 3. TAKEOVER: while the current speaker is still talking they keep the highlight, even if a second
///    person qualifies (otherwise two people talking over each other would swap it back and forth).
///    Once the current speaker is silent, a qualified candidate takes over immediately, without
///    waiting out the hold (§8: the highlight follows the conversation).
/// 4. STABLE TIE-BREAK: when several candidates qualify at once, the one who started speaking
///    earliest wins; equal start times fall back to the smaller id so the result never depends on
///    Set ordering (§12).
struct GroupCallSpeakerTracker {
    /// Seconds of continuous speech before someone may take over (owner spec §8).
    static let qualifyDelay: TimeInterval = 0.3

    /// The held, de-flickered speaker (a participant sid), or nil when nobody has spoken lately.
    private(set) var activeSpeakerId: String?

    /// When each currently-speaking person started their unbroken run of speech.
    private var speakingSince: [String: Date] = [:]
    /// The last time the active speaker was seen in the speaking set (start of the hold window).
    private var activeLastHeard: Date?

    /// Feed the raw speaking set every update; returns true when `activeSpeakerId` changed.
    @discardableResult
    mutating func update(speaking: Set<String>, now: Date) -> Bool {
        let before = activeSpeakerId

        // Clocks: forget anyone who stopped (a gap resets the 0.3s), start the clock for new voices.
        speakingSince = speakingSince.filter { speaking.contains($0.key) }
        for id in speaking where speakingSince[id] == nil { speakingSince[id] = now }

        if let current = activeSpeakerId, speaking.contains(current) {
            // Rule 3: still talking, keeps the highlight.
            activeLastHeard = now
            return false
        }

        // Rule 1 + 4: qualified candidates, earliest start first, id as the stable tie-break.
        let candidate = speakingSince
            .filter { now.timeIntervalSince($0.value) >= Self.qualifyDelay }
            .min { a, b in a.value != b.value ? a.value < b.value : a.key < b.key }?
            .key

        if let candidate {
            activeSpeakerId = candidate
            activeLastHeard = now
        } else if activeSpeakerId != nil {
            // Rule 2: silent holder, release after the hold window.
            let heard = activeLastHeard ?? now
            if now.timeIntervalSince(heard) >= GroupCallMetrics.speakerHold {
                activeSpeakerId = nil
                activeLastHeard = nil
            }
        }
        return activeSpeakerId != before
    }
}
