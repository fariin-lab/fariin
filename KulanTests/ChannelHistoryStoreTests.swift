import XCTest
@testable import Kulan

// The channel history store (CHANNEL-SYNC-SPEC.md 5-9): holes filled to N visible, deletions
// removed from storage, changes applied by the change counter, the "too long" path, and the store
// coming back from disk. Pure values and a temp folder: no Firebase, no network, no clock.
final class ChannelHistoryStoreTests: XCTestCase {

    private struct P: ChannelHistoryPost {
        let id: String
        var createdAt: Date
        var deleted: Bool = false
        var text: String = ""
    }
    private typealias H = ChannelHistory<P>

    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }
    private func doc(_ id: String, _ s: Double, chg: Int?, deleted: Bool = false, text: String = "") -> ChannelDoc<P> {
        ChannelDoc(post: P(id: id, createdAt: at(s), deleted: deleted, text: text), chg: chg)
    }
    private let now = Date(timeIntervalSince1970: 2_000_000)
    private let visible: (P) -> Bool = { !$0.deleted }

    /// The server's side of a hole read: docs at or below `upper`, newest first, `limit` of them.
    private func serverPage(_ server: [ChannelDoc<P>], upper: Date, limit: Int = 60) -> [ChannelDoc<P>] {
        Array(server.filter { $0.post.createdAt <= upper }
            .sorted { $0.post.createdAt > $1.post.createdAt }
            .prefix(limit))
    }

    /// What the repository does: read the top hole while fewer than `want` are visible.
    @discardableResult
    private func fill(_ h: inout H, _ server: [ChannelDoc<P>], want: Int = 40, maxPages: Int = 30) -> Int {
        var pages = 0
        while h.needsFill(want: want, visible), pages < maxPages, let hole = h.topHole {
            let page = serverPage(server, upper: hole.upper)
            h.applyPage(page, upper: hole.upper, full: page.count >= 60, fromServer: true, now: now)
            pages += 1
        }
        return pages
    }

    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("chstore-test-\(UUID().uuidString)", isDirectory: true)
    }

    // MARK: Fill

    /// The VE3 shape: the 95 newest docs are deleted posts, the one live post sits under them.
    func testFillReadsPastDeletedPostsToTheLivePost() {
        var server = [doc("live", 0, chg: 1, text: "Hello Guys")]
        for i in 1...95 { server.append(doc("d\(i)", Double(i), chg: i + 1, deleted: true)) }
        var h = H()
        let pages = fill(&h, server)
        XCTAssertEqual(pages, 2, "60 tombstones, then the 35 left with the live post (a short page)")
        XCTAssertEqual(h.posts.count, 1, "tombstones are not rows")
        XCTAssertEqual(h.posts["live"]?.text, "Hello Guys")
        XCTAssertEqual(h.visibleCount(visible), 1)
        XCTAssertEqual(h.tombs.count, 95)
        XCTAssertTrue(h.reachedStart, "the short page proved nothing older exists")
        XCTAssertNil(h.topHole)
    }

    func testFillStopsAtTheWantedCount() {
        var server: [ChannelDoc<P>] = []
        for i in 0..<500 { server.append(doc("p\(i)", Double(i), chg: i + 1)) }
        var h = H()
        fill(&h, server, want: 40)
        XCTAssertEqual(h.posts.count, 60, "one page of 60 already shows 40")
        XCTAssertNotNil(h.topHole)
        XCTAssertFalse(h.reachedStart)
    }

    // MARK: Deletion

    func testDeletingTheNewestRemovesItAndAnOlderReadCannotBringItBack() {
        var h = H()
        let server = [doc("a", 1, chg: 1), doc("b", 2, chg: 2), doc("c", 3, chg: 3)]
        h.applyPage(serverPage(server, upper: .distantFuture), upper: .distantFuture, full: false, fromServer: true, now: now)
        h.lastChg = 3
        XCTAssertEqual(h.sortedPosts.last?.id, "c")

        XCTAssertEqual(h.applyChange(doc("c", 3, chg: 4, deleted: true), now: now), .removed)
        XCTAssertNil(h.posts["c"])
        XCTAssertEqual(h.sortedPosts.last?.id, "b")

        // A page read before the delete lands after it, with the live copy.
        h.applyPage([doc("c", 3, chg: 3), doc("b", 2, chg: 2)], upper: at(3), full: false, fromServer: true, now: now)
        XCTAssertNil(h.posts["c"], "an in-flight page must not resurrect a deleted post")
        // Nor a copy with no counter at all (an old cache).
        XCTAssertEqual(h.applyChange(doc("c", 3, chg: nil), now: now), .ignored)
        XCTAssertEqual(h.posts.count, 2)
    }

    func testHardDeleteFromChangesRemovesTheRow() {
        var h = H()
        h.applyPage([doc("a", 1, chg: 1), doc("b", 2, chg: 2)], upper: .distantFuture, full: false, fromServer: true, now: now)
        XCTAssertEqual(h.remove("b", chg: 5, now: now), .removed)
        XCTAssertEqual(h.remove("b", chg: 5, now: now), .unchanged, "applying the same delete twice is harmless")
        XCTAssertEqual(h.posts.keys.sorted(), ["a"])
        XCTAssertEqual(h.tombs["b"]?.chg, 5)
    }

    // MARK: Sync by the change counter

    /// Offline for a while, then a burst of changes arrives in `chg` order.
    func testOfflineBurstAppliedInChangeOrder() {
        var h = H()
        h.applyPage([doc("a", 1, chg: 1, text: "a1"), doc("b", 2, chg: 2), doc("c", 3, chg: 3)],
                    upper: .distantFuture, full: false, fromServer: true, now: now)
        h.lastChg = 3
        let burst = [
            doc("a", 1, chg: 4, text: "a2"),            // edit
            doc("b", 2, chg: 5, deleted: true),         // delete
            doc("d", 4, chg: 6, text: "d1"),            // add
            doc("d", 4, chg: 7, text: "d2"),            // edit of the new one
            doc("e", 5, chg: 8, text: "e1"),            // add
            doc("e", 5, chg: 9, deleted: true),         // and delete
        ]
        var outcomes: [H.Outcome] = []
        for d in burst { outcomes.append(h.applyChange(d, now: now)) }
        h.lastChg = burst.compactMap(\.chg).max()
        XCTAssertEqual(outcomes, [.edited, .removed, .added, .edited, .added, .removed])
        XCTAssertEqual(h.sortedPosts.map(\.id), ["a", "c", "d"])
        XCTAssertEqual(h.posts["a"]?.text, "a2")
        XCTAssertEqual(h.posts["d"]?.text, "d2")
        XCTAssertEqual(h.lastChg, 9)

        // The listener delivers the same changes again (a re-attach): nothing moves.
        for d in burst { _ = h.applyChange(d, now: now) }
        XCTAssertEqual(h.sortedPosts.map(\.id), ["a", "c", "d"])
        XCTAssertEqual(h.posts["d"]?.text, "d2")
        // An older copy arriving late never wins over a newer one.
        XCTAssertEqual(h.applyChange(doc("a", 1, chg: 2, text: "stale"), now: now), .ignored)
        XCTAssertEqual(h.posts["a"]?.text, "a2")
    }

    func testRowsAreNeverDroppedForBeingAbsentFromAnAnswer() {
        var h = H()
        h.applyPage([doc("a", 1, chg: 1), doc("b", 2, chg: 2)], upper: .distantFuture, full: false, fromServer: true, now: now)
        // A listener answer that holds only "c" says nothing about "a" and "b".
        _ = h.applyChange(doc("c", 3, chg: 3), now: now)
        XCTAssertEqual(h.sortedPosts.map(\.id), ["a", "b", "c"])
    }

    // MARK: Too long

    func testTooLongKeepsOldRowsAndMarksAHole() {
        var h = H()
        let old = (1...5).map { doc("o\($0)", Double($0), chg: $0) }
        h.applyPage(old, upper: .distantFuture, full: false, fromServer: true, now: now)
        h.lastChg = 5
        XCTAssertTrue(h.reachedStart)

        // 300 changes waited: the newest page (60 new posts) goes on top.
        let newest = (1...60).map { doc("n\($0)", 1000 + Double($0), chg: 300 + $0) }
        h.resetForTooLong()
        h.applyPage(newest, upper: .distantFuture, full: true, fromServer: true, now: now)

        XCTAssertEqual(h.posts.count, 65, "the old rows stay on screen")
        XCTAssertEqual(h.unverified, Set(old.map(\.post.id)))
        XCTAssertNotNil(h.topHole, "a hole between the new page and the old block")
        XCTAssertEqual(h.topHole?.upper, at(1001))
        XCTAssertFalse(h.reachedStart)
        XCTAssertEqual(h.visibleCount(visible), 60, "only the block above the hole counts toward N")

        // Reading the hole: o4 and o5 were hard-deleted meanwhile; the rest is proven current.
        let server = newest + Array(old.prefix(3))
        fill(&h, server, want: 100)
        XCTAssertTrue(h.reachedStart)
        XCTAssertNil(h.posts["o4"])
        XCTAssertNil(h.posts["o5"])
        XCTAssertNotNil(h.posts["o1"])
        XCTAssertTrue(h.unverified.isEmpty)
        XCTAssertEqual(h.posts.count, 63)
    }

    // MARK: Review fixes (2026-11-09)

    /// Clear Messages: `{clear: true, before}` removes every post created at or before `before`.
    func testClearRecordRemovesEverythingUpToBefore() {
        var h = H()
        h.applyPage((1...5).map { doc("p\($0)", Double($0), chg: $0) }, upper: .distantFuture, full: false, fromServer: true, now: now)
        let gone = h.clearBefore(at(3), now: now)
        XCTAssertEqual(Set(gone.map(\.id)), ["p1", "p2", "p3"])
        XCTAssertEqual(h.sortedPosts.map(\.id), ["p4", "p5"])
        // A page read before the clear cannot bring them back.
        h.applyPage([doc("p2", 2, chg: 2)], upper: at(3), full: false, fromServer: true, now: now)
        XCTAssertNil(h.posts["p2"])
    }

    /// A change for a post outside every read range is not added (no unmarked gap next to the
    /// newest block); its delete is still remembered; the hole read brings it in.
    func testChangeOutsideReadRangesWaitsForTheHoleRead() {
        var h = H()
        let newest = (100..<160).map { doc("n\($0)", Double($0), chg: $0) }
        h.applyPage(newest, upper: .distantFuture, full: true, fromServer: true, now: now)
        XCTAssertEqual(h.topHole?.upper, at(100))
        XCTAssertEqual(h.applyChange(doc("old", 10, chg: 500, text: "edited"), now: now), .ignored)
        XCTAssertNil(h.posts["old"])
        XCTAssertEqual(h.applyChange(doc("gone", 20, chg: 501, deleted: true), now: now), .unchanged)
        XCTAssertNotNil(h.tombs["gone"])
        // Inside the read range a new post is still added.
        XCTAssertEqual(h.applyChange(doc("new", 200, chg: 502), now: now), .added)
        // The hole read brings the old post in, and keeps the deleted one out.
        h.applyPage([doc("old", 10, chg: 500, text: "edited"), doc("gone", 20, chg: 400)],
                    upper: at(100), full: false, fromServer: true, now: now)
        XCTAssertEqual(h.posts["old"]?.text, "edited")
        XCTAssertNil(h.posts["gone"])
    }

    /// The probe adopts cached rows before the window: a short window (the whole channel) then
    /// drops a cached post the server hard-deleted.
    func testAdoptBeforeShortWindowDropsHardDeletedCachedPost() {
        var h = H()
        h.adoptUnverified([P(id: "cachedGone", createdAt: at(1)), P(id: "kept", createdAt: at(2))])
        h.applyPage([doc("kept", 2, chg: 2), doc("new", 3, chg: 3)], upper: .distantFuture, full: false, fromServer: true, now: now)
        XCTAssertTrue(h.reachedStart)
        XCTAssertNil(h.posts["cachedGone"])
        XCTAssertEqual(h.sortedPosts.map(\.id), ["kept", "new"])
        XCTAssertTrue(h.unverified.isEmpty)
    }

    // MARK: Ranges and bound

    func testRangesMergeWhenAHoleIsRead() {
        var h = H()
        h.markKnown(lo: at(100), hi: .distantFuture)
        h.markKnown(lo: at(10), hi: at(50))
        XCTAssertEqual(h.ranges.count, 2)
        XCTAssertEqual(h.topHole, H.Hole(upper: at(100), floor: at(50)))
        h.markKnown(lo: at(40), hi: at(100))
        XCTAssertEqual(h.ranges, [H.Range(lo: at(10), hi: .distantFuture)])
    }

    func testBoundKeepsTheNewestAndTurnsTheRestBackIntoAHole() {
        var h = H()
        let all = (0..<100).map { doc("p\($0)", Double($0), chg: $0 + 1) }
        h.applyPage(all, upper: .distantFuture, full: false, fromServer: true, now: now)
        XCTAssertTrue(h.reachedStart)
        h.bound(keepVisible: 30, visible)
        XCTAssertEqual(h.posts.count, 30)
        XCTAssertEqual(h.sortedPosts.first?.id, "p70")
        XCTAssertFalse(h.reachedStart, "what went is a hole again")
        XCTAssertEqual(h.topHole?.upper, at(69))
    }

    // MARK: Disk and reopen

    func testReopenFromDiskShowsPostsWithoutNetwork() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let reg = ChannelHistoryRegistry<P>(directory: dir)
        let box = reg.openSync(uid: "u1", cid: "chan")
        box.history.applyPage([doc("a", 1, chg: 1, text: "first"), doc("b", 2, chg: 2), doc("x", 3, chg: 3, deleted: true)],
                              upper: .distantFuture, full: false, fromServer: true, now: now)
        box.history.lastChg = 3
        box.history.lastGoneChg = 3
        box.saveNow()
        box.flush()

        // A fresh launch: nothing in memory, the file only.
        let reg2 = ChannelHistoryRegistry<P>(directory: dir)
        XCTAssertNil(reg2.memory(uid: "u1", cid: "chan"))
        XCTAssertTrue(reg2.hasFile(uid: "u1", cid: "chan"))
        let back = reg2.openSync(uid: "u1", cid: "chan")
        XCTAssertTrue(back.history.isSynced)
        XCTAssertEqual(back.history.sortedPosts.map(\.id), ["a", "b"])
        XCTAssertEqual(back.history.posts["a"]?.text, "first")
        XCTAssertEqual(back.history.lastChg, 3)
        XCTAssertEqual(back.history.tombs.keys.sorted(), ["x"])
        XCTAssertTrue(back.history.reachedStart)
        // Another account never sees it.
        XCTAssertFalse(reg2.hasFile(uid: "u2", cid: "chan"))
        XCTAssertTrue(reg2.openSync(uid: "u2", cid: "chan").history.posts.isEmpty)
    }

    func testDiskKeepsTheNewestVisiblePostsOnly() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let reg = ChannelHistoryRegistry<P>(directory: dir, diskKeep: 10)
        let box = reg.openSync(uid: "u1", cid: "big")
        box.history.applyPage((0..<50).map { doc("p\($0)", Double($0), chg: $0 + 1) },
                              upper: .distantFuture, full: false, fromServer: true, now: now)
        box.history.lastChg = 50
        box.saveNow()
        box.flush()
        XCTAssertEqual(box.history.posts.count, 50, "memory keeps everything while open")
        let back = ChannelHistoryRegistry<P>(directory: dir, diskKeep: 10).openSync(uid: "u1", cid: "big")
        XCTAssertEqual(back.history.posts.count, 10)
        XCTAssertEqual(back.history.sortedPosts.first?.id, "p40")
        XCTAssertNotNil(back.history.topHole, "the rest reads back in as a hole")
    }

    /// Leave and reopen at once, twice over: the same store, nothing lost, nothing doubled.
    func testRapidOpenCloseKeepsState() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let reg = ChannelHistoryRegistry<P>(directory: dir, memoryCap: 1)

        // Two opens in the same instant (the init seed and start()): one load, one store.
        let both = expectation(description: "both opens answered")
        both.expectedFulfillmentCount = 2
        var got: [ChannelHistoryBox<P>] = []
        reg.open(uid: "u1", cid: "A") { got.append($0); both.fulfill() }
        reg.open(uid: "u1", cid: "A") { got.append($0); both.fulfill() }
        wait(for: [both], timeout: 5)
        XCTAssertEqual(got.count, 2)
        XCTAssertTrue(got[0] === got[1])

        let a = got[0]
        a.history.applyPage([doc("a1", 1, chg: 1)], upper: .distantFuture, full: false, fromServer: true, now: now)
        a.history.lastChg = 1
        a.scheduleSave()   // closed before the debounce fires

        // Reopened at once: the memory copy, change included.
        XCTAssertTrue(reg.openSync(uid: "u1", cid: "A") === a)
        _ = a.history.applyChange(doc("a2", 2, chg: 2), now: now)
        a.history.lastChg = 2

        // Another channel pushes A out of memory (cap 1): A is written on its way out, and the next
        // open reads it back after that write.
        _ = reg.openSync(uid: "u1", cid: "B")
        XCTAssertNil(reg.memory(uid: "u1", cid: "A"))
        let again = reg.openSync(uid: "u1", cid: "A")
        XCTAssertEqual(again.history.sortedPosts.map(\.id), ["a1", "a2"])
        XCTAssertEqual(again.history.lastChg, 2)
    }

    func testSignOutWipesEveryStore() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let reg = ChannelHistoryRegistry<P>(directory: dir)
        let box = reg.openSync(uid: "u1", cid: "chan")
        box.history.applyPage([doc("a", 1, chg: 1)], upper: .distantFuture, full: false, fromServer: true, now: now)
        box.history.lastChg = 1
        box.saveNow()
        reg.removeAll()
        box.saveNow()   // a retired store never writes again
        box.flush()
        XCTAssertFalse(reg.hasFile(uid: "u1", cid: "chan"))
        XCTAssertNil(reg.memory(uid: "u1", cid: "chan"))
    }
}
