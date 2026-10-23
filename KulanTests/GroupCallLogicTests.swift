import XCTest
@testable import Kulan

// Group call logic that has no network, no singletons and no UI: the per-person history line,
// the call screen's status words, the link-call nudge push parser, and the GC# log line's privacy.
// Group call audit 2026-10-23, controls plan section T. The first automated tests for group calls.

// MARK: - GroupCallOutcome.mine (Calls tab line, as I saw the call)

final class GroupCallOutcomeTests: XCTestCase {

    private let me = "me"
    private let other = "bob"

    private func mine(_ stored: String?, caller: String?, joined: [String]?, rung: [String]?,
                      me: String? = nil) -> String? {
        GroupCallOutcome.mine(stored: stored, callerUid: caller, joined: joined, rung: rung,
                              me: me ?? self.me)
    }

    // A record without joinedUids (any 1:1 call, an older server, a call still going) is untouched.
    func testNoJoinedListKeepsStoredOutcome() {
        XCTAssertEqual(mine("missed", caller: other, joined: nil, rung: [me]), "missed")
        XCTAssertEqual(mine("answered", caller: other, joined: nil, rung: nil), "answered")
        XCTAssertEqual(mine("declined", caller: me, joined: nil, rung: nil), "declined")
        XCTAssertNil(mine(nil, caller: other, joined: nil, rung: nil))
    }

    func testEmptyMeKeepsStoredOutcome() {
        XCTAssertEqual(mine("missed", caller: other, joined: ["x"], rung: [""], me: ""), "missed")
    }

    func testOngoingAndRingingPassThrough() {
        XCTAssertEqual(mine("ongoing", caller: other, joined: [], rung: [me]), "ongoing")
        XCTAssertEqual(mine("ringing", caller: me, joined: [me, other], rung: nil), "ringing")
    }

    // I started it: answered iff anybody else came.
    func testStarterAloneIsUnanswered() {
        XCTAssertEqual(mine("answered", caller: me, joined: [], rung: [other]), "missed")
        XCTAssertEqual(mine("answered", caller: me, joined: [me], rung: [other]), "missed")
    }

    func testStarterWithAnyoneElseIsAnswered() {
        XCTAssertEqual(mine("missed", caller: me, joined: [me, other], rung: [other]), "answered")
        // The starter's own uid missing from the list (left before the server read it) still counts.
        XCTAssertEqual(mine("missed", caller: me, joined: [other], rung: nil), "answered")
    }

    // Joined on any device beats missed and declined, whatever the stored outcome says.
    func testJoinedOnAnyDeviceIsAnswered() {
        XCTAssertEqual(mine("missed", caller: other, joined: [other, me], rung: [me]), "answered")
        XCTAssertEqual(mine("declined", caller: other, joined: [me], rung: [me]), "answered")
        XCTAssertEqual(mine(nil, caller: other, joined: [me], rung: nil), "answered")
    }

    // Rung and never in it: missed, even if somebody else answered.
    func testRungAndNeverJoinedIsMissed() {
        XCTAssertEqual(mine("answered", caller: other, joined: [other, "carol"], rung: [me, "carol"]), "missed")
        XCTAssertEqual(mine(nil, caller: other, joined: [other], rung: [me]), "missed")
    }

    // No rung list on the record: not known, so treated as rung.
    func testUnknownRungListAndNeverJoinedIsMissed() {
        XCTAssertEqual(mine("answered", caller: other, joined: [other], rung: nil), "missed")
    }

    // Never rung (muted group, too big to ring) and never in it: never missed, a plain notJoined line.
    func testNeverRungIsNotMissed() {
        let r = mine("missed", caller: other, joined: [other], rung: ["carol"])
        XCTAssertEqual(r, GroupCallOutcome.notJoined)
        XCTAssertNotEqual(r, "missed")
        XCTAssertEqual(mine("answered", caller: other, joined: [other], rung: []), GroupCallOutcome.notJoined)
    }

    // The server keeps at most listCap uids per list. A full joined list makes no claim.
    func testFullJoinedListWithoutMeKeepsStored() {
        let full = (0..<GroupCallOutcome.listCap).map { "u\($0)" }
        XCTAssertEqual(mine("answered", caller: other, joined: full, rung: [me]), "answered")
        XCTAssertEqual(mine("missed", caller: other, joined: full, rung: []), "missed")
    }

    // A full rung list may have cut me off: counted as rung, so missed.
    func testFullRungListWithoutMeCountsAsRung() {
        let full = (0..<GroupCallOutcome.listCap).map { "u\($0)" }
        XCTAssertEqual(mine("answered", caller: other, joined: [other], rung: full), "missed")
        let underCap = Array(full.dropLast())
        XCTAssertEqual(mine("answered", caller: other, joined: [other], rung: underCap),
                       GroupCallOutcome.notJoined)
    }

    func testConstants() {
        XCTAssertEqual(GroupCallOutcome.listCap, 64)
        XCTAssertEqual(GroupCallOutcome.notJoined, "notJoined")
    }
}

// MARK: - GroupCallWords (header and minimized card share these)

final class GroupCallWordsTests: XCTestCase {

    func testReconnectingOutranksEveryState() {
        for s in [GroupJoinState.notJoined, .joining, .pending, .joined] {
            XCTAssertEqual(GroupCallWords.status(joinState: s, connecting: false, reconnecting: true),
                           "Reconnecting…", "\(s)")
            XCTAssertEqual(GroupCallWords.status(joinState: s, connecting: true, reconnecting: true),
                           "Reconnecting…", "\(s)")
        }
    }

    func testEachJoinState() {
        XCTAssertEqual(GroupCallWords.status(joinState: .pending, connecting: false, reconnecting: false),
                       "Waiting to be let in")
        XCTAssertEqual(GroupCallWords.status(joinState: .joining, connecting: false, reconnecting: false),
                       "Connecting…")
        XCTAssertNil(GroupCallWords.status(joinState: .joined, connecting: false, reconnecting: false))
        XCTAssertNil(GroupCallWords.status(joinState: .joined, connecting: true, reconnecting: false))
    }

    func testNotJoinedSaysConnectingOnlyWhileConnecting() {
        XCTAssertEqual(GroupCallWords.status(joinState: .notJoined, connecting: true, reconnecting: false),
                       "Connecting…")
        XCTAssertNil(GroupCallWords.status(joinState: .notJoined, connecting: false, reconnecting: false))
    }

    func testAloneLines() {
        XCTAssertEqual(GroupCallWords.alone(ringing: []), "No one else is here")
        XCTAssertEqual(GroupCallWords.alone(ringing: ["Alice"]), "Ringing Alice…")
        XCTAssertEqual(GroupCallWords.alone(ringing: ["Alice", "Bob"]), "Ringing Alice and Bob…")
        XCTAssertEqual(GroupCallWords.alone(ringing: ["Alice", "Bob", "Cy"]), "Ringing Alice, Bob and 1 other…")
        XCTAssertEqual(GroupCallWords.alone(ringing: ["Alice", "Bob", "Cy", "Di"]),
                       "Ringing Alice, Bob and 2 others…")
        XCTAssertEqual(GroupCallWords.alone(ringing: ["A", "B", "C", "D", "E"]), "Ringing A, B and 3 others…")
    }
}

// MARK: - LinkNudge (the linknudge alert push)

final class LinkNudgeTests: XCTestCase {

    // 32 letters from the key alphabet, no 4-letter group of one letter repeated.
    private let goodKey = "bcdf-ghkm-npqr-stxz-bcdf-ghkm-npqr-stxz"

    private func push(_ change: [String: Any] = [:], drop: [String] = []) -> [AnyHashable: Any] {
        var d: [String: Any] = [
            "type": "linknudge", "roomId": "room1", "key": goodKey, "callerUid": "u1",
            "callerName": "Alice", "title": "Team", "video": "true", "startedAt": "1700000000000",
        ]
        for (k, v) in change { d[k] = v }
        for k in drop { d.removeValue(forKey: k) }
        var out: [AnyHashable: Any] = [:]
        for (k, v) in d { out[k] = v }
        return out
    }

    func testFullPushParses() throws {
        let n = try XCTUnwrap(LinkNudge(push()))
        XCTAssertEqual(n.roomId, "room1")
        XCTAssertEqual(n.key, goodKey)
        XCTAssertEqual(n.callerUid, "u1")
        XCTAssertEqual(n.callerName, "Alice")
        XCTAssertEqual(n.title, "Team")
        XCTAssertTrue(n.video)
        XCTAssertEqual(n.startedAtMs, 1_700_000_000_000)
        XCTAssertNil(n.photoUrl)
    }

    func testWrongOrMissingTypeIsRefused() {
        XCTAssertNil(LinkNudge(push(["type": "groupring"])))
        XCTAssertNil(LinkNudge(push(drop: ["type"])))
    }

    func testBadRoomIdIsRefused() {
        XCTAssertNil(LinkNudge(push(["roomId": ""])))
        XCTAssertNil(LinkNudge(push(["roomId": "a/b"])))
        XCTAssertNil(LinkNudge(push(drop: ["roomId"])))
    }

    func testBadKeyIsRefused() {
        XCTAssertNil(LinkNudge(push(drop: ["key"])))
        XCTAssertNil(LinkNudge(push(["key": ""])))
        XCTAssertNil(LinkNudge(push(["key": "bcdf-ghkm"])))                             // too short
        XCTAssertNil(LinkNudge(push(["key": "abcd-ghkm-npqr-stxz-bcdf-ghkm-npqr-stxz"]))) // vowel
        XCTAssertNil(LinkNudge(push(["key": "bbbb-ghkm-npqr-stxz-bcdf-ghkm-npqr-stxz"]))) // filler group
    }

    func testKeyCaseAndDashesAreForgiven() {
        XCTAssertNotNil(LinkNudge(push(["key": "BCDFGHKMNPQRSTXZBCDFGHKMNPQRSTXZ"])))
    }

    func testVideoFlag() {
        XCTAssertTrue(LinkNudge(push(["video": true]))!.video)
        XCTAssertFalse(LinkNudge(push(["video": "false"]))!.video)
        XCTAssertFalse(LinkNudge(push(drop: ["video"]))!.video)
    }

    func testStartedAtSecondsBecomeMilliseconds() {
        XCTAssertEqual(LinkNudge(push(["startedAt": "1700000000"]))!.startedAtMs, 1_700_000_000_000)
        XCTAssertEqual(LinkNudge(push(["startedAt": NSNumber(value: 1_700_000_000)]))!.startedAtMs,
                       1_700_000_000_000)
        XCTAssertEqual(LinkNudge(push(["startedAt": NSNumber(value: 1_700_000_000_000.0)]))!.startedAtMs,
                       1_700_000_000_000)
    }

    func testMissingOrBadStartedAtIsNil() {
        XCTAssertNil(LinkNudge(push(drop: ["startedAt"]))!.startedAtMs)
        XCTAssertNil(LinkNudge(push(["startedAt": "0"]))!.startedAtMs)
        XCTAssertNil(LinkNudge(push(["startedAt": "soon"]))!.startedAtMs)
    }

    func testNameAndTitleFallbacks() {
        XCTAssertEqual(LinkNudge(push(["callerName": ""]))!.callerName, "Someone")
        XCTAssertEqual(LinkNudge(push(drop: ["callerName"]))!.callerName, "Someone")
        XCTAssertNil(LinkNudge(push(["title": ""]))!.title)
        XCTAssertNil(LinkNudge(push(drop: ["title"]))!.title)
        XCTAssertEqual(LinkNudge(push(drop: ["callerUid"]))!.callerUid, "")
    }
}

// MARK: - GCLog (GC# lines never carry the raw room id)

final class GCLogTests: XCTestCase {

    func testRoomHashKnownValue() {
        // printf 'kulan.gc.v1:room-test-1' | sha256sum, first 12 hex digits. Pins the salt and the
        // length, so two phones' logs keep lining up across builds.
        XCTAssertEqual(GCLog.hashRoom("room-test-1"), "d06b86a32b42")
    }

    func testRoomHashShape() {
        let a = GCLog.hashRoom("roomA")
        XCTAssertEqual(a.count, 12)
        XCTAssertTrue(a.allSatisfy { "0123456789abcdef".contains($0) })
        XCTAssertEqual(a, GCLog.hashRoom("roomA"))
        XCTAssertNotEqual(a, GCLog.hashRoom("roomB"))
        XCTAssertFalse(a.contains("room"))
    }

    private func logText() -> String {
        DiagLog.flush()
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
              let data = try? Data(contentsOf: dir.appendingPathComponent("diag.log"))
        else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    func testEventLineHashesRoomAndSortsFields() throws {
        let room = "rawroom" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        GCLog.event("tap", room: room, ["what": "mic", "to": "off"])
        let text = logText()
        XCTAssertFalse(text.contains(room), "raw room id reached the log")
        let line = try XCTUnwrap(text.split(separator: "\n").last(where: { $0.contains(GCLog.hashRoom(room)) }))
        XCTAssertTrue(line.hasSuffix("GC# tap room=\(GCLog.hashRoom(room)) to=off what=mic"), String(line))
    }

    func testEventValuesAreCleanedAndCapped() throws {
        let room = "rawroom" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        GCLog.event("a b=c", room: room, ["k": "x y=z", "long": String(repeating: "v", count: 60)])
        let text = logText()
        XCTAssertFalse(text.contains(room))
        let line = try XCTUnwrap(text.split(separator: "\n").last(where: { $0.contains(GCLog.hashRoom(room)) }))
        XCTAssertTrue(line.hasSuffix("GC# a_b_c room=\(GCLog.hashRoom(room)) k=x_y_z long=\(String(repeating: "v", count: 40))"),
                      String(line))
    }

    func testNoRoomWritesNoRoomField() throws {
        let marker = "m" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(20)
        GCLog.event("noroom", room: nil, ["id": String(marker)])
        GCLog.event("noroom", room: "", ["id": String(marker) + "e"])
        let lines = logText().split(separator: "\n").filter { $0.contains(marker) }
        XCTAssertEqual(lines.count, 2)
        XCTAssertFalse(lines.contains(where: { $0.contains("room=") }))
    }
}
