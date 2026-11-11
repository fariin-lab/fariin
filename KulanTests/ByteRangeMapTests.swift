import XCTest
@testable import Kulan

// The range map behind a streaming chat video's partial file (`ByteRangeMap`). Pure logic.
final class ByteRangeMapTests: XCTestCase {

    func testInsertMergesOverlapAndTouch() {
        var m = ByteRangeMap()
        m.insert(10 ..< 20)
        m.insert(30 ..< 40)
        XCTAssertEqual(m.ranges, [10 ..< 20, 30 ..< 40])
        m.insert(20 ..< 30)   // touches both sides
        XCTAssertEqual(m.ranges, [10 ..< 40])
        m.insert(0 ..< 5)
        m.insert(35 ..< 50)
        XCTAssertEqual(m.ranges, [0 ..< 5, 10 ..< 50])
        XCTAssertEqual(m.count, 45)
    }

    func testEmptyAndBackwardsAreIgnored() {
        var m = ByteRangeMap()
        m.insert(5 ..< 5)
        XCTAssertTrue(m.isEmpty)
        let restored = ByteRangeMap([3 ..< 3, 0 ..< 2, 1 ..< 4])
        XCTAssertEqual(restored.ranges, [0 ..< 4])
    }

    func testContainsAndContiguous() {
        let m = ByteRangeMap([0 ..< 100, 200 ..< 300])
        XCTAssertTrue(m.contains(10 ..< 90))
        XCTAssertFalse(m.contains(90 ..< 210))
        XCTAssertEqual(m.contiguous(from: 50), 50)
        XCTAssertEqual(m.contiguous(from: 50, limit: 10), 10)
        XCTAssertEqual(m.contiguous(from: 100), 0)
        XCTAssertEqual(m.contiguous(from: 250), 50)
    }

    func testFirstMissing() {
        let m = ByteRangeMap([0 ..< 100, 200 ..< 300])
        XCTAssertEqual(m.firstMissing(in: 0 ..< 300), 100 ..< 200)
        XCTAssertEqual(m.firstMissing(in: 150 ..< 250), 150 ..< 200)
        XCTAssertNil(m.firstMissing(in: 210 ..< 290))
        XCTAssertEqual(m.firstMissing(in: 250 ..< 400), 300 ..< 400)
        XCTAssertEqual(ByteRangeMap().firstMissing(in: 5 ..< 9), 5 ..< 9)
    }

    func testComplete() {
        XCTAssertTrue(ByteRangeMap([0 ..< 50, 50 ..< 80]).isComplete(total: 80))
        XCTAssertFalse(ByteRangeMap([0 ..< 79]).isComplete(total: 80))
        XCTAssertFalse(ByteRangeMap().isComplete(total: 0))
    }
}
