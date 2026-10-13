import XCTest
import AVFoundation
import Network
import UIKit
@testable import Kulan
@testable import StoryUI

// HOW LONG A STORY VIDEO TAKES TO MOVE AFTER IT BECOMES THE ONE ON SCREEN, on a simulator, through
// the real `StoryItemVideoView` and the real reader (`StoryVideoStream`), against a clip made by the
// real post-time encoder.
//
// Every case runs twice in the same build:
//   COLD     = the player is built when the story lands (what every build up to 9a448d14 did);
//   PREPARED = the player was built while the story sat beside the one on screen (9a448d14).
// The clock starts at `setMode(.play)` — the moment the turn lands — and stops at the first
// periodic tick that reports the player moving past zero. Ticks are 50ms apart, so every number
// is good to about ±50ms. A simulator decodes on the Mac's hardware: absolute times are not a
// phone's, the COLD/PREPARED difference is the thing measured.
//
// Uncached clips stream from a loopback server that honours Range and can be slowed down
// (`bytesPerSecond`, first-byte `latency`), so "slow network" is a real slow network to the reader.
// Results go to /tmp/repost-shots/playback-start.txt (the workflow's artifact).
final class StoryPlaybackStartTests: XCTestCase {

    private static var log: [String] = []
    override class func tearDown() {
        let dir = URL(fileURLWithPath: "/tmp/repost-shots", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? log.joined(separator: "\n").write(to: dir.appendingPathComponent("playback-start.txt"),
                                               atomically: true, encoding: .utf8)
    }
    @MainActor
    private func note(_ s: String) { Self.log.append(s); print("PLAYBACK " + s) }

    private static var clipData: Data?

    /// A 6-second 30fps portrait clip with sound, put through `VideoTranscoder.prepare` exactly as a
    /// story post is, so the file has the posted layout (fast-start, our bitrate).
    @MainActor
    private func clip() async throws -> Data {
        if let d = Self.clipData { return d }
        let src = try await StoryVideoEncoderTests.makeClip(size: CGSize(width: 1080, height: 1920), fps: 30,
                                                            seconds: 6, colour: .systemTeal, audio: true)
        let prepared = await VideoTranscoder.prepare(src, maxSeconds: 90, storyBackdrop: true)
        let p = try XCTUnwrap(prepared)
        Self.clipData = p.data
        note("clip: \(p.data.count) bytes, \(String(format: "%.1f", p.duration))s")
        return p.data
    }

    @MainActor
    private func host() -> UIView {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        if let w = scene?.windows.first(where: \.isKeyWindow) ?? scene?.windows.first { return w }
        let w = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        w.makeKeyAndVisible()
        return w
    }

    enum Source {
        case cached
        case stream(bytesPerSecond: Double, latency: Double, warm: Bool)
    }

    /// One landing. Returns seconds from `play` to the first moving frame, or nil on a 15s timeout.
    @MainActor
    private func land(source: Source, prepared: Bool, lead: Double) async throws -> Double? {
        let data = try await clip()
        let id = UUID().uuidString
        var server: LoopbackVideoServer?
        let url: URL
        switch source {
        case .cached:
            url = URL(string: "https://cache.test/\(id).mp4")!
            let dest = StoryPartialFile.completedURL(for: url)
            try? FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: dest)
        case .stream(let rate, let latency, let warm):
            let s = LoopbackVideoServer(data: data, bytesPerSecond: rate, latency: latency)
            try await s.start()
            server = s
            url = URL(string: "http://127.0.0.1:\(s.port)/\(id).mp4")!
            // What the lookahead does for the very next story (`StoryPrefetcher.warmVideo`).
            if warm {
                StoryVideoStream.warmPrefix(url, bytes: StoryVideoStream.defaultPrefix,
                                            allowsCellular: true, urgent: true)
            }
        }

        // The page beside the one on screen: told whether to prepare, paused, mounted.
        let session = StoryVideoSession()
        session.setPrepared(prepared)
        let v = StoryItemVideoView(storyId: id, storyURL: url, poster: nil, blurThumb: "")
        let h = host()
        v.frame = h.bounds
        h.addSubview(v)
        v.attach(to: session)

        // The time the neighbour has before the turn lands (a swipe plus the 0.4s settle).
        if lead > 0 { try await Task.sleep(for: .milliseconds(Int(lead * 1000))) }

        let t0 = CACurrentMediaTime()
        session.setMode(.play)
        var result: Double?
        while CACurrentMediaTime() - t0 < 15 {
            if session.isPlaying, session.timestamp > 0.001 { result = CACurrentMediaTime() - t0; break }
            try await Task.sleep(for: .milliseconds(5))
        }
        v.teardown()
        server?.stop()
        StoryVideoStream.discardPartial(for: url)
        try? FileManager.default.removeItem(at: StoryPartialFile.completedURL(for: url))
        return result
    }

    /// Three landings each way; the medians, the raw runs, and the pair logged side by side.
    @discardableResult @MainActor
    private func compare(_ label: String, source: Source, lead: Double = 0.6) async throws -> (cold: Double, prepared: Double) {
        func ms(_ v: Double?) -> String { v.map { String(format: "%.0fms", $0 * 1000) } ?? "TIMEOUT" }
        func median(_ xs: [Double?]) -> Double {
            let s = xs.map { $0 ?? 15 }.sorted(); return s[s.count / 2]
        }
        var cold: [Double?] = [], prep: [Double?] = []
        for _ in 0..<3 {
            cold.append(try await land(source: source, prepared: false, lead: lead))
            prep.append(try await land(source: source, prepared: true, lead: lead))
        }
        let c = median(cold), p = median(prep)
        note("\(label): COLD median \(ms(c)) [\(cold.map(ms).joined(separator: ", "))]"
             + "  PREPARED median \(ms(p)) [\(prep.map(ms).joined(separator: ", "))]")
        return (c, p)
    }

    // MARK: - Cases

    @MainActor
    func testCachedClip() async throws {
        let r = try await compare("cached (watched before, whole file on disk)", source: .cached)
        XCTAssertLessThan(r.prepared, 1.0)
    }

    @MainActor
    func testStreamedWarmedGoodNetwork() async throws {
        let r = try await compare("uncached, opening pre-downloaded, 8 Mbps / 50ms",
                                  source: .stream(bytesPerSecond: 1_000_000, latency: 0.05, warm: true))
        XCTAssertLessThan(r.prepared, 1.0)
    }

    @MainActor
    func testStreamedNotWarmedGoodNetwork() async throws {
        try await compare("uncached, nothing pre-downloaded, 8 Mbps / 50ms",
                          source: .stream(bytesPerSecond: 1_000_000, latency: 0.05, warm: false))
    }

    @MainActor
    func testStreamedWarmedSlowNetwork() async throws {
        try await compare("uncached, opening pre-downloaded, 1.5 Mbps / 200ms",
                          source: .stream(bytesPerSecond: 190_000, latency: 0.2, warm: true))
    }

    /// A fast swipe: the neighbour had almost no time before it landed.
    @MainActor
    func testRapidSwipe() async throws {
        try await compare("rapid swipe (0.1s lead), opening pre-downloaded, 8 Mbps",
                          source: .stream(bytesPerSecond: 1_000_000, latency: 0.05, warm: true), lead: 0.1)
    }
}

/// A one-file HTTP server on 127.0.0.1 that honours `Range`, waits `latency` before the first byte
/// and then sends at `bytesPerSecond`. One request per connection.
final class LoopbackVideoServer {
    private let data: Data
    private let bytesPerSecond: Double
    private let latency: TimeInterval
    private let queue = DispatchQueue(label: "loopback-video")
    private var listener: NWListener?
    private(set) var port: UInt16 = 0

    init(data: Data, bytesPerSecond: Double, latency: TimeInterval) {
        self.data = data; self.bytesPerSecond = bytesPerSecond; self.latency = latency
    }

    func start() async throws {
        let l = try NWListener(using: .tcp, on: .any)
        listener = l
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            var resumed = false
            l.stateUpdateHandler = { state in
                switch state {
                case .ready, .failed, .cancelled:
                    if !resumed { resumed = true; cont.resume() }
                default: break
                }
            }
            l.start(queue: queue)
        }
        port = l.port?.rawValue ?? 0
    }

    func stop() { listener?.cancel() }

    private func accept(_ c: NWConnection) {
        c.start(queue: queue)
        readHead(c, Data())
    }

    private func readHead(_ c: NWConnection, _ buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] d, _, done, err in
            guard let self else { return }
            var buf = buffer
            if let d { buf.append(d) }
            if let end = buf.range(of: Data("\r\n\r\n".utf8)) {
                self.respond(c, head: String(decoding: buf[..<end.lowerBound], as: UTF8.self))
            } else if err == nil, !done {
                self.readHead(c, buf)
            } else {
                c.cancel()
            }
        }
    }

    private func respond(_ c: NWConnection, head: String) {
        let total = data.count
        var lo = 0, hi = total - 1
        if let line = head.components(separatedBy: "\r\n").first(where: { $0.lowercased().hasPrefix("range:") }),
           let eq = line.firstIndex(of: "=") {
            let parts = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                .split(separator: "-", omittingEmptySubsequences: false)
            if let a = Int(parts[0]) { lo = a }
            if parts.count > 1, let b = Int(parts[1]) { hi = min(b, total - 1) }
        }
        guard lo <= hi else {
            let h = "HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */\(total)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            c.send(content: Data(h.utf8), isComplete: true, completion: .contentProcessed { _ in c.cancel() })
            return
        }
        let head = "HTTP/1.1 206 Partial Content\r\nContent-Type: video/mp4\r\nAccept-Ranges: bytes\r\n"
            + "Content-Range: bytes \(lo)-\(hi)/\(total)\r\nContent-Length: \(hi - lo + 1)\r\nConnection: close\r\n\r\n"
        queue.asyncAfter(deadline: .now() + latency) { [weak self] in
            c.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
            self?.pump(c, from: lo, to: hi + 1)
        }
    }

    private func pump(_ c: NWConnection, from: Int, to: Int) {
        guard from < to else {
            c.send(content: nil, isComplete: true, completion: .contentProcessed { _ in c.cancel() })
            return
        }
        let n = min(16 * 1024, to - from)
        c.send(content: data.subdata(in: from ..< from + n), completion: .contentProcessed { [weak self] err in
            guard let self, err == nil else { c.cancel(); return }
            self.queue.asyncAfter(deadline: .now() + Double(n) / self.bytesPerSecond) {
                self.pump(c, from: from + n, to: to)
            }
        })
    }
}
