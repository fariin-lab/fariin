import XCTest
@testable import Kulan

/// Owner 2026-10-18: views of Fariin's stories. An unnamed view's document id is a hash of the uid,
/// and the server works out who is counted twice with the same hash. These pin the phone's half to
/// the server's (functions-admin test/ostories.test.js pins the same vector).
final class OfficialStoryViewsTests: XCTestCase {

    func testHashMatchesServer() {
        XCTAssertEqual(OfficialStoryViews.hashedId(uid: "abcDEF123"),
                       "a9fcd6fb64b4296a57d0fbef7b87a940c94728d7701e9c5e5a401d9543b642e5")
    }

    func testRawId() {
        XCTAssertEqual(OfficialStoryViews.rawId("official-abc123"), "abc123")
        XCTAssertNil(OfficialStoryViews.rawId("official-"))
        XCTAssertNil(OfficialStoryViews.rawId("abc123"))
    }
}
