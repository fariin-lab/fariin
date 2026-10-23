import XCTest
@testable import Kulan

// When a voice note downloads by itself: network x chat type x size x one-time, plus the window of
// rows around the visible ones. Pure logic, no network or disk (`VoiceAutoDownload`).
final class VoiceAutoDownloadTests: XCTestCase {

    private typealias V = VoiceAutoDownload
    private let mb: Int64 = 1024 * 1024

    private func note(_ seconds: Double = 20, viewOnce: Bool = false, deleted: Bool = false,
                      hasRemote: Bool = true, cached: Bool = false, sealed: Bool = false) -> V.Note {
        V.Note(viewOnce: viewOnce, deleted: deleted, hasRemote: hasRemote, cached: cached,
               sealedWithoutMe: sealed, duration: seconds)
    }

    // MARK: Ceilings (the reference's max(2 MB, file limit))

    func testSizeLimits() {
        XCTAssertEqual(V.sizeLimit(.cellular), 2 * mb)   // max(2, 1)
        XCTAssertEqual(V.sizeLimit(.wifi), 3 * mb)       // max(2, 3)
    }

    // MARK: Network x chat type with the default policy

    func testDefaultPolicyDownloadsEverywhere() {
        for net in [V.Network.wifi, .cellular] {
            for chat in [V.ChatKind.oneToOne, .group] {
                XCTAssertEqual(V.decide(note(), network: net, policy: .always, chat: chat),
                               .download(limit: V.sizeLimit(net)), "\(net) \(chat)")
            }
        }
    }

    func testWifiOnlyPolicy() {
        for chat in [V.ChatKind.oneToOne, .group] {
            XCTAssertEqual(V.decide(note(), network: .wifi, policy: .wifi, chat: chat), .download(limit: 3 * mb))
            XCTAssertEqual(V.decide(note(), network: .cellular, policy: .wifi, chat: chat), .skip(.policy))
        }
    }

    func testNeverPolicy() {
        for net in [V.Network.wifi, .cellular] {
            XCTAssertEqual(V.decide(note(), network: net, policy: .never, chat: .group), .skip(.policy))
        }
    }

    // MARK: Low Data Mode and no connection count as cellular

    func testNetworkMapping() {
        XCTAssertEqual(V.network(isWifi: true, isConstrained: false), .wifi)
        XCTAssertEqual(V.network(isWifi: true, isConstrained: true), .cellular)
        XCTAssertEqual(V.network(isWifi: false, isConstrained: false), .cellular)
        XCTAssertEqual(V.network(isWifi: false, isConstrained: true), .cellular)
    }

    func testLowDataModeOnWifiHoldsWifiOnlyPolicy() {
        let net = V.network(isWifi: true, isConstrained: true)
        XCTAssertEqual(V.decide(note(), network: net, policy: .wifi, chat: .oneToOne), .skip(.policy))
        XCTAssertEqual(V.decide(note(), network: net, policy: .always, chat: .oneToOne), .download(limit: 2 * mb))
    }

    // MARK: Size (estimated from the length at 40 kbit/s)

    func testEstimate() {
        XCTAssertNil(V.estimatedBytes(duration: nil))
        XCTAssertNil(V.estimatedBytes(duration: 0))
        XCTAssertNil(V.estimatedBytes(duration: .nan))
        XCTAssertEqual(V.estimatedBytes(duration: 60), Int64(60 * 5_000 * 1.1) + 4_096)
    }

    func testFiveMinuteNoteFitsBothNetworks() {
        // 300 s ~ 1.65 MB
        XCTAssertEqual(V.decide(note(300), network: .cellular, policy: .always, chat: .group), .download(limit: 2 * mb))
        XCTAssertEqual(V.decide(note(300), network: .wifi, policy: .always, chat: .group), .download(limit: 3 * mb))
    }

    func testSevenMinuteNoteWaitsOnCellularOnly() {
        // 420 s ~ 2.31 MB: over 2 MB, under 3 MB
        XCTAssertEqual(V.decide(note(420), network: .cellular, policy: .always, chat: .oneToOne), .skip(.tooLarge))
        XCTAssertEqual(V.decide(note(420), network: .wifi, policy: .always, chat: .oneToOne), .download(limit: 3 * mb))
    }

    func testThirtyMinuteNoteNeverAutomatic() {
        for net in [V.Network.wifi, .cellular] {
            XCTAssertEqual(V.decide(note(1800), network: net, policy: .always, chat: .group), .skip(.tooLarge))
        }
    }

    func testUnknownLengthStillDownloadsUnderTheByteCeiling() {
        let n = V.Note(duration: nil)
        XCTAssertEqual(V.decide(n, network: .cellular, policy: .always, chat: .oneToOne), .download(limit: 2 * mb))
    }

    // MARK: Never automatic

    func testOneTimeNoteNeverAutomatic() {
        for net in [V.Network.wifi, .cellular] {
            for chat in [V.ChatKind.oneToOne, .group] {
                for p in [V.Policy.always, .wifi, .never] {
                    XCTAssertEqual(V.decide(note(viewOnce: true), network: net, policy: p, chat: chat), .skip(.viewOnce))
                }
            }
        }
    }

    func testOtherSkips() {
        XCTAssertEqual(V.decide(note(deleted: true), network: .wifi, policy: .always, chat: .group), .skip(.deleted))
        XCTAssertEqual(V.decide(note(hasRemote: false), network: .wifi, policy: .always, chat: .group), .skip(.noFile))
        XCTAssertEqual(V.decide(note(cached: true), network: .wifi, policy: .always, chat: .group), .skip(.cached))
        XCTAssertEqual(V.decide(note(sealed: true), network: .wifi, policy: .always, chat: .group), .skip(.unreadable))
    }

    // MARK: Window around the visible rows

    func testWindowNilReportTakesNewestThree() {
        let voice: Set<Int> = [1, 3, 5, 7, 9]
        XCTAssertEqual(V.window(count: 10, visible: nil, followsNewest: true, towardOlder: true,
                                isVoice: { voice.contains($0) }), [9, 7, 5])
    }

    func testWindowVisiblePlusThreeOlder() {
        let voice = Set(0..<100)
        let w = V.window(count: 100, visible: 50...55, followsNewest: false, towardOlder: true,
                         isVoice: { voice.contains($0) })
        XCTAssertEqual(w, [50, 51, 52, 53, 54, 55, 49, 48, 47])
    }

    func testWindowVisiblePlusThreeNewer() {
        let voice = Set(0..<100)
        let w = V.window(count: 100, visible: 50...55, followsNewest: false, towardOlder: false,
                         isVoice: { voice.contains($0) })
        XCTAssertEqual(w, [50, 51, 52, 53, 54, 55, 56, 57, 58])
    }

    func testWindowAheadCountsVoiceNotesOnly() {
        let voice: Set<Int> = [52, 30, 20, 10, 5]
        let w = V.window(count: 100, visible: 50...55, followsNewest: false, towardOlder: true,
                         isVoice: { voice.contains($0) })
        XCTAssertEqual(w, [52, 30, 20, 10])
    }

    func testWindowFollowsNewestIncludesArrivals() {
        let voice: Set<Int> = [95, 98, 99]
        // Viewport was 90...96 when the reader sat at the newest; 3 rows arrived since.
        let w = V.window(count: 100, visible: 90...96, followsNewest: true, towardOlder: true,
                         isVoice: { voice.contains($0) })
        XCTAssertEqual(Set(w), [95, 98, 99])
    }

    func testWindowDoesNotWalkTheWholeHistory() {
        let w = V.window(count: 5_000, visible: 4_990...4_999, followsNewest: true, towardOlder: true,
                         isVoice: { _ in true })
        XCTAssertEqual(w.count, 13)   // 10 visible + 3 ahead
    }

    func testWindowEmptyAndClamped() {
        XCTAssertEqual(V.window(count: 0, visible: 0...3, followsNewest: true, towardOlder: true, isVoice: { _ in true }), [])
        XCTAssertEqual(V.window(count: 3, visible: 1...10, followsNewest: false, towardOlder: true, isVoice: { _ in true }), [1, 2, 0])
    }
}
