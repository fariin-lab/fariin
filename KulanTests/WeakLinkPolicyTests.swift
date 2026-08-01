import XCTest
@testable import Kulan

// The 1:1 weak-signal video fallback's decision logic.
//
// Every test drives `now` by hand, so a fifteen second stretch of call is exercised instantly and
// the same way every run. Sleeping through the real windows would make this suite slow AND flaky,
// which is how timing tests end up disabled.
final class WeakLinkPolicyTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    private let poor: Double = 20_000     // under the 50k floor
    private let good: Double = 400_000    // comfortably over it

    // MARK: Pausing

    func testPoorLinkDoesNotPauseBeforeFiveSeconds() {
        var p = WeakLinkPolicy()
        XCTAssertEqual(p.evaluate(bitrate: poor, paused: false, now: at(0)), .none)
        XCTAssertEqual(p.evaluate(bitrate: poor, paused: false, now: at(2)), .none)
        // 4.9s in, still inside the window. This is the assertion that actually protects the user
        // from a blink: without the window, sample one would already have killed their video.
        XCTAssertEqual(p.evaluate(bitrate: poor, paused: false, now: at(4.9)), .none)
    }

    func testPoorLinkPausesAtFiveSeconds() {
        var p = WeakLinkPolicy()
        _ = p.evaluate(bitrate: poor, paused: false, now: at(0))
        XCTAssertEqual(p.evaluate(bitrate: poor, paused: false, now: at(5)), .pause)
    }

    func testOneGoodSampleRestartsThePauseWindow() {
        var p = WeakLinkPolicy()
        _ = p.evaluate(bitrate: poor, paused: false, now: at(0))
        _ = p.evaluate(bitrate: poor, paused: false, now: at(4))
        // A single healthy sample four seconds in must throw the whole window away, not let the
        // earlier poor run count toward a pause.
        _ = p.evaluate(bitrate: good, paused: false, now: at(4.5))
        // The new run starts at the next POOR sample, 6s, not at the good one that cleared it. So the
        // pause is due at 11s. The old 9.5s here was my own arithmetic, and the suite caught it.
        XCTAssertEqual(p.evaluate(bitrate: poor, paused: false, now: at(6)), .none,
                       "this sample restarts the run, so nothing is due yet")
        XCTAssertEqual(p.evaluate(bitrate: poor, paused: false, now: at(10.9)), .none,
                       "10.9s is 4.9s into a run that began at 6s")
        XCTAssertEqual(p.evaluate(bitrate: poor, paused: false, now: at(11)), .pause)
    }

    func testAlreadyPausedNeverPausesAgain() {
        var p = WeakLinkPolicy()
        _ = p.evaluate(bitrate: poor, paused: true, now: at(0))
        XCTAssertEqual(p.evaluate(bitrate: poor, paused: true, now: at(60)), .none)
    }

    // MARK: Resuming

    func testGoodLinkDoesNotResumeBeforeTenSeconds() {
        var p = WeakLinkPolicy()
        _ = p.evaluate(bitrate: good, paused: true, now: at(0))
        XCTAssertEqual(p.evaluate(bitrate: good, paused: true, now: at(5)), .none)
        XCTAssertEqual(p.evaluate(bitrate: good, paused: true, now: at(9.9)), .none)
    }

    func testGoodLinkResumesAtTenSeconds() {
        var p = WeakLinkPolicy()
        _ = p.evaluate(bitrate: good, paused: true, now: at(0))
        XCTAssertEqual(p.evaluate(bitrate: good, paused: true, now: at(10)), .resume)
    }

    func testResumeIsSlowerThanPause() {
        // The asymmetry is the whole anti-flap design, so it is worth asserting outright rather than
        // leaving it as an accident of two constants someone could later "tidy" into one.
        let p = WeakLinkPolicy()
        XCTAssertGreaterThan(p.resumeAfter, p.pauseAfter)
    }

    func testOneBadSampleRestartsTheResumeWindow() {
        var p = WeakLinkPolicy()
        _ = p.evaluate(bitrate: good, paused: true, now: at(0))
        _ = p.evaluate(bitrate: good, paused: true, now: at(8))
        _ = p.evaluate(bitrate: poor, paused: true, now: at(9))   // one dip resets it
        // Same rule as the pause side: the run restarts at the next GOOD sample, 15s, so the resume
        // is due at 25s. Eight seconds of health before the dip count for nothing, which is the
        // point. Video comes back only after a full clean ten.
        XCTAssertEqual(p.evaluate(bitrate: good, paused: true, now: at(15)), .none,
                       "this sample restarts the run, so nothing is due yet")
        XCTAssertEqual(p.evaluate(bitrate: good, paused: true, now: at(24.9)), .none,
                       "24.9s is 9.9s into a run that began at 15s")
        XCTAssertEqual(p.evaluate(bitrate: good, paused: true, now: at(25)), .resume)
    }

    func testNotPausedNeverResumes() {
        var p = WeakLinkPolicy()
        _ = p.evaluate(bitrate: good, paused: false, now: at(0))
        XCTAssertEqual(p.evaluate(bitrate: good, paused: false, now: at(60)), .none)
    }

    // MARK: Unknown estimate

    func testUnknownBitrateDecidesNothingAndClearsWindows() {
        var p = WeakLinkPolicy()
        _ = p.evaluate(bitrate: poor, paused: false, now: at(0))
        // A candidate pair that is still forming reports nothing. Treating that as "bad" would blank
        // video on every healthy call at connect time.
        XCTAssertEqual(p.evaluate(bitrate: nil, paused: false, now: at(1)), .none)
        XCTAssertEqual(p.evaluate(bitrate: 0, paused: false, now: at(2)), .none)
        // ...and it must not have left the earlier poor run standing.
        XCTAssertEqual(p.evaluate(bitrate: poor, paused: false, now: at(6)), .none,
                       "the poor run restarted at 6s, so nothing is due yet")
        XCTAssertEqual(p.evaluate(bitrate: poor, paused: false, now: at(11)), .pause)
    }

    // MARK: Manual override

    func testResetClearsBothWindows() {
        var p = WeakLinkPolicy()
        _ = p.evaluate(bitrate: poor, paused: false, now: at(0))
        // Standing in for the user turning their own camera off and on: their intent restarts the
        // clock, so a verdict formed before they touched it can never fire afterwards.
        p.reset()
        XCTAssertNil(p.poorSince)
        XCTAssertNil(p.goodSince)
        XCTAssertEqual(p.evaluate(bitrate: poor, paused: false, now: at(5)), .none)
    }

    // MARK: The floor itself

    func testExactlyAtTheFloorCountsAsHealthy() {
        var p = WeakLinkPolicy()
        _ = p.evaluate(bitrate: 50_000, paused: true, now: at(0))
        XCTAssertEqual(p.evaluate(bitrate: 50_000, paused: true, now: at(10)), .resume)
    }
}
