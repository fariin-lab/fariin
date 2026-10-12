import XCTest
import AVFoundation
@testable import Kulan

/// Owner 2026-10-12: during another app's call, video stories stopped playing after the story camera
/// was opened and closed. The camera left the app's audio session in `.playAndRecord`, which cannot
/// activate while another app's call holds the microphone. These pin the hand-back.
final class CameraAudioTests: XCTestCase {

    private let session = AVAudioSession.sharedInstance()

    override func setUp() {
        super.setUp()
        try? session.setCategory(.ambient, mode: .default, options: [])
    }

    override func tearDown() {
        try? session.setCategory(.soloAmbient, mode: .default, options: [])
        super.tearDown()
    }

    func testTakeSwitchesToTheCameraShape() {
        CameraAudio.take()
        XCTAssertEqual(session.category, .playAndRecord)
        XCTAssertEqual(session.mode, .videoRecording)
        CameraAudio.giveBack()
    }

    func testGiveBackRestoresWhatWasThereBefore() {
        CameraAudio.take()
        CameraAudio.giveBack()
        XCTAssertEqual(session.category, .ambient, "the camera left its recording session behind")
        XCTAssertEqual(session.mode, .default)
    }

    func testRepeatedOpenCloseCyclesLeaveNothingBehind() {
        for _ in 0..<5 {
            CameraAudio.take()
            CameraAudio.take()      // a restart with the mic still attached takes again
            CameraAudio.giveBack()
        }
        XCTAssertEqual(session.category, .ambient)
    }

    func testGiveBackLeavesASessionSomethingElseTookOver() {
        CameraAudio.take()
        // A call (or a voice note) claims the session while the camera is up.
        try? session.setCategory(.playAndRecord, mode: .voiceChat, options: [])
        CameraAudio.giveBack()
        XCTAssertEqual(session.mode, .voiceChat, "the hand-back must not undo somebody else's session")
    }

    func testALeftoverSnapshotGoesBackToTheSystemDefault() {
        // What an older build (or the automatic setting) left behind.
        try? session.setCategory(.playAndRecord, mode: .videoRecording, options: [])
        CameraAudio.take()
        CameraAudio.giveBack()
        XCTAssertEqual(session.category, .soloAmbient)
        XCTAssertEqual(session.mode, .default)
    }

    func testGiveBackWithoutTakeDoesNothing() {
        CameraAudio.giveBack()
        XCTAssertEqual(session.category, .ambient)
    }
}
