import XCTest
@testable import Kulan

// The temp-file guarantee behind ChatService.uploadEncrypted.
//
// The upload itself needs Firebase and a network, so these do not test that. They test the part that
// can actually go wrong quietly: the staged file is a sealed copy of a private message, and leaving
// one behind on a failed send would be invisible in normal use and would accumulate.
final class UploadStagingTests: XCTestCase {

    private let payload = Data("sealed message bytes".utf8)

    private struct Boom: Error {}

    func testFileExistsAndHoldsThePayloadDuringTheBody() async throws {
        var seen: URL?
        try await ChatService.withStagedFile(payload) { url in
            seen = url
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
            XCTAssertEqual(try Data(contentsOf: url), self.payload,
                           "the upload must send exactly the bytes it was handed")
        }
        XCTAssertNotNil(seen)
    }

    func testFileIsRemovedAfterSuccess() async throws {
        var seen: URL?
        try await ChatService.withStagedFile(payload) { url in seen = url }
        let url = try XCTUnwrap(seen)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testFileIsRemovedAfterTheBodyThrows() async {
        var seen: URL?
        do {
            try await ChatService.withStagedFile(payload) { url in
                seen = url
                throw Boom()
            }
            XCTFail("the error must propagate to the caller, not be swallowed by the cleanup")
        } catch is Boom {
            // expected
        } catch {
            XCTFail("wrong error surfaced: \(error)")
        }
        guard let url = seen else { return XCTFail("body never ran") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                       "a failed upload must not leave a sealed payload in tmp")
    }

    func testFileIsRemovedAfterCancellation() async {
        var seen: URL?
        let task = Task {
            try await ChatService.withStagedFile(payload) { url in
                seen = url
                try await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
        // Let the body reach its sleep, then cancel: this is a user backing out of a slow send.
        try? await Task.sleep(nanoseconds: 200_000_000)
        task.cancel()
        _ = await task.result
        let url = try? XCTUnwrap(seen)
        if let url { XCTAssertFalse(FileManager.default.fileExists(atPath: url.path)) }
    }

    func testEachCallGetsItsOwnFile() async throws {
        // Two sends in flight at once, an album, must not stage over each other.
        var a: URL?
        var b: URL?
        try await ChatService.withStagedFile(payload) { first in
            a = first
            try await ChatService.withStagedFile(self.payload) { second in
                b = second
                XCTAssertNotEqual(first, second)
                XCTAssertTrue(FileManager.default.fileExists(atPath: first.path),
                              "the outer file must survive the inner one being cleaned up")
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(b).path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(a).path))
    }

    func testReturnValuePassesThrough() async throws {
        let out = try await ChatService.withStagedFile(payload) { _ in "https://example/x.enc" }
        XCTAssertEqual(out, "https://example/x.enc")
    }
}
