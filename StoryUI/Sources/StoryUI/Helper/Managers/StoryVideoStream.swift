//
//  StoryVideoStream.swift
//  StoryUI
//
//  PLAY A STORY CLIP WHILE IT IS STILL ARRIVING, AND KEEP THE BYTES.
//
//  ⚠️ THE GAP THIS CLOSES. `CacheManager.loadVideo` downloads the WHOLE object to a file and only
//  then hands it to a player, so nothing can start until the last byte lands. The reference app does
//  the opposite: it plays over a partial-range fetch and preloads only a server-sized PREFIX of each
//  neighbour. Two consequences follow from ours, and both were in the code before this file existed:
//
//    * a clip you tap onto costs its whole download before the first frame, which on mobile data is
//      the wait the loading spinner exists to apologise for;
//    * the lookahead has to pull three WHOLE clips (up to 23MB each) because half a file was no use
//      to anybody — the single largest thing this app spends unasked-for data on, and its own code
//      comments already admitted it ("15 to 25MB").
//
//  Our exports already carry `shouldOptimizeForNetworkUse`, so the moov atom is at the FRONT of
//  every file we post and a prefix is genuinely playable. The only thing missing was a reader.
//
//  ⚠️ IT IS OFF BY DEFAULT. See `StoryVideoStream.enabled`. This landed in the same branch as a
//  complete replacement of the story playback engine, on a machine with no Swift compiler and no
//  device, and a resource loader that misbehaves does not throw — it simply never hands the player
//  any bytes, which on screen is a story that never starts. That is not a thing to discover together
//  with an architecture change. Turn it on when the engine has a device verdict, and it ships alone.
//

import Foundation
import AVFoundation

/// Serves an `AVURLAsset` from a partial file, fetching what it does not have.
///
/// One instance per clip, owned by the `AVURLAsset` it serves (AVFoundation holds the delegate
/// weakly, so `StoryVideoStream.retain` keeps it alive for the asset's life).
final class StoryVideoStream: NSObject, AVAssetResourceLoaderDelegate {

    /// ⚠️ THE SWITCH. False means every caller falls straight through to the full-download path that
    /// shipped before this file, byte for byte. See the header.
    static let enabled = false

    /// Our own scheme, so `AVAssetResourceLoader` asks US rather than going to the network itself.
    /// `https` would be served by AVFoundation directly and this delegate would never be called.
    private static let scheme = "fariin-story"

    /// How much of a neighbour is worth having before it is watched. The reference app takes this
    /// per file from the server (`preload_prefix_size`); ours is written onto the story document at
    /// post time (`preloadPrefix`), and this is the floor for anything posted before that existed.
    static let defaultPrefix: Int64 = 512 * 1024

    private let remote: URL
    private let partial: StoryPartialFile
    /// Everything here happens on one queue. A resource loader is called from AVFoundation's own
    /// threads and a URLSession answers on another; two locks around one state machine is how a
    /// story ends up never starting.
    private let queue = DispatchQueue(label: "story.video.stream")
    private var pending: [ObjectIdentifier: Fetch] = [:]
    private var live: [AVAssetResourceLoadingRequest] = []

    private final class Fetch {
        let task: URLSessionDataTask
        var offset: Int64
        init(task: URLSessionDataTask, offset: Int64) { self.task = task; self.offset = offset }
    }

    private lazy var session: URLSession = {
        URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    }()

    private init(remote: URL) {
        self.remote = remote
        self.partial = StoryPartialFile(remote: remote)
        super.init()
    }

    // MARK: - Building an asset

    /// Kept alive for the life of the asset it serves — AVFoundation's delegate reference is weak.
    private static var retain: [ObjectIdentifier: StoryVideoStream] = [:]

    /// An asset that plays `remote` through this reader, or nil when streaming is off or the url
    /// cannot carry our scheme. Nil is a normal answer: the caller uses the download path.
    @MainActor
    static func asset(for remote: URL) -> AVURLAsset? {
        guard enabled,
              var comps = URLComponents(url: remote, resolvingAgainstBaseURL: false) else { return nil }
        comps.scheme = scheme
        guard let masked = comps.url else { return nil }
        let stream = StoryVideoStream(remote: remote)
        let asset = AVURLAsset(url: masked)
        asset.resourceLoader.setDelegate(stream, queue: stream.queue)
        retain[ObjectIdentifier(asset)] = stream
        return asset
    }

    /// Let go of the reader when its asset does. Called from the item view's teardown.
    ///
    /// ⚠️ DROPPING THE REFERENCE IS NOT ENOUGH, AND THIS IS A LEAK THAT KEEPS SPENDING DATA.
    /// `URLSession(configuration:delegate:delegateQueue:)` RETAINS its delegate until the session is
    /// invalidated. This class is its own delegate, so a stream that is merely forgotten keeps
    /// itself alive through its session, and its transfers keep running — for a story nobody is
    /// watching any more, which is precisely the waste this file exists to end. One per clip
    /// watched, for the life of the process.
    @MainActor
    static func release(_ asset: AVAsset?) {
        guard let asset, let stream = retain.removeValue(forKey: ObjectIdentifier(asset)) else { return }
        stream.teardown()
    }

    private func teardown() {
        queue.async { [self] in
            pending.values.forEach { $0.task.cancel() }
            pending.removeAll()
            let stranded = live
            live.removeAll()
            stranded.forEach { $0.finishLoading(with: URLError(.cancelled)) }
            // ⚠️ PROMOTION HAPPENS HERE AND NOWHERE EARLIER. It MOVES the partial onto the plain
            // cache path, and doing that while requests are still being served pulls the file out
            // from under the reader: the open handle would be closed, the next read would re-open a
            // path that no longer exists — creating an empty file — and the range map would have
            // been cleared, so the reader would decide it holds nothing and fetch the whole clip
            // again. A story that has just finished downloading is the worst possible moment to
            // start downloading it.
            //
            // Waiting costs nothing. The clip stays a `.part` for as long as it is being watched,
            // and the next OPEN finds the promoted file through `cachedFileIfUsable` and never
            // builds a reader at all.
            partial.promoteIfComplete()
            // Breaks the delegate retain, cancels anything still in flight, and is the only thing
            // that lets this object deallocate.
            session.invalidateAndCancel()
        }
    }

    /// FETCH ONLY THE FIRST `bytes` OF A CLIP, for the lookahead. Nothing plays from this directly;
    /// it fills the same partial file the reader serves from, so arriving at the story finds the
    /// opening already here and starts on it while the rest streams in behind.
    static func warmPrefix(_ remote: URL, bytes: Int64, allowsCellular: Bool,
                           onTask: ((URLSessionTask) -> Void)? = nil) {
        guard enabled, bytes > 0 else { return }
        let partial = StoryPartialFile(remote: remote)
        // Already here, or the whole clip already is — nothing to do either way.
        if partial.holds(0 ..< bytes) { return }
        if CacheManager.cachedFileIfUsable(for: remote) != nil { return }
        var request = URLRequest(url: remote)
        request.setValue("bytes=0-\(bytes - 1)", forHTTPHeaderField: "Range")
        request.allowsConstrainedNetworkAccess = false
        request.allowsExpensiveNetworkAccess = allowsCellular
        request.networkServiceType = .background
        let task = URLSession.shared.dataTask(with: request) { data, response, _ in
            guard let data, !data.isEmpty,
                  let http = response as? HTTPURLResponse,
                  http.statusCode == 200 || http.statusCode == 206 else { return }
            if let total = Self.totalLength(from: http) {
                partial.note(total: total, contentType: http.mimeType)
            }
            partial.write(offset: 0, data: data)
            partial.promoteIfComplete()
        }
        onTask?(task)
        task.resume()
    }

    // MARK: - AVAssetResourceLoaderDelegate

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest) -> Bool {
        live.append(request)
        serve(request)
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        didCancel request: AVAssetResourceLoadingRequest) {
        live.removeAll { $0 === request }
        // ⚠️ THE TRANSFER ONLY STOPS WHEN NOBODY IS WAITING ON IT. A player cancels and re-issues
        // requests constantly as it moves through a clip, so cancelling the fetch per cancelled
        // request would tear down and rebuild the connection every few kilobytes. It is dropped only
        // when the last waiter has gone, which is the clip genuinely being left — and paying for
        // bytes after that is the waste this file exists to end.
        guard live.isEmpty else { return }
        pending.values.forEach { $0.task.cancel() }
        pending.removeAll()
    }

    // MARK: - Serving

    private func serve(_ request: AVAssetResourceLoadingRequest) {
        // ⚠️ THE CONTENT INFORMATION COMES FIRST AND THE PLAYER WILL NOT MOVE WITHOUT IT. It needs a
        // length, a UTI and an explicit promise that ranges are supported; answer any of the three
        // wrongly and AVFoundation gives up without a word.
        if let info = request.contentInformationRequest {
            if let total = partial.total {
                fill(info, total: total)
                finishIfPossible(request)
                return
            }
            probe { [weak self] total, type in
                // Back on the one queue: `probe` answers on URLSession's, and everything below
                // touches state this class serialises.
                guard let self else { return }
                guard let total else {
                    self.live.removeAll { $0 === request }
                    request.finishLoading(with: URLError(.badServerResponse))
                    return
                }
                self.partial.note(total: total, contentType: type)
                self.fill(info, total: total)
                self.finishIfPossible(request)
            }
            return
        }
        finishIfPossible(request)
    }

    private func fill(_ info: AVAssetResourceLoadingContentInformationRequest, total: Int64) {
        info.contentLength = total
        info.isByteRangeAccessSupported = true
        // ⚠️ A UTI, NOT THE MIME TYPE. AVFoundation matches this against uniform type identifiers,
        // and handing it `video/mp4` — which is exactly what the server reports and what looks
        // right — makes it decide it cannot play the asset. Every story object we upload is mp4
        // (`StoriesService.postVideoSegment` sets that content type on the put), so this is not a
        // guess about the file, it is the same fact spelled the way this API reads it.
        info.contentType = "public.mpeg-4"
    }

    /// Hand over whatever of this request we hold, and go and get the rest.
    private func finishIfPossible(_ request: AVAssetResourceLoadingRequest) {
        guard let data = request.dataRequest else {
            request.finishLoading()
            live.removeAll { $0 === request }
            return
        }
        let start = data.currentOffset
        let wanted: Int64
        if data.requestsAllDataToEndOfResource {
            // ⚠️ WITHOUT A LENGTH THIS IS NOT AN EMPTY REQUEST, IT IS AN UNANSWERABLE ONE. The old
            // shape read `(partial.total ?? start) - start`, which is zero when the length is not
            // known yet — and zero fell through to `finishLoading()`, telling the player the request
            // was satisfied when nothing had been handed over. Go and get the length instead.
            guard let total = partial.total else { fetch(from: start); return }
            wanted = total - start
        } else {
            // `currentOffset` advances as we respond, so this is what is LEFT of the request.
            wanted = Int64(data.requestedLength) - (start - data.requestedOffset)
        }
        guard wanted > 0 else {
            request.finishLoading()
            live.removeAll { $0 === request }
            return
        }
        let held = partial.contiguousLength(from: start, limit: wanted)
        if held > 0, let bytes = partial.read(offset: start, length: held) {
            data.respond(with: bytes)
            if held >= wanted {
                request.finishLoading()
                live.removeAll { $0 === request }
                return
            }
        }
        fetch(from: start + held)
    }

    /// ⚠️ NOT "ONE FETCH AT A TIME", AND THE DIFFERENCE IS A HANG.
    ///
    /// This used to open with `guard pending.isEmpty`, which is correct only if a player reads a
    /// file front to back. It does not. AVPlayer reads the header, then goes looking for the moov
    /// atom, then streams media data — several ranges, live at once, and not in order. With a single
    /// global fetch the second request would find one already running, start nothing, and wait for
    /// bytes at an offset the running transfer was never going to reach. Nothing times out and
    /// nothing errors: the story simply never starts, which is the exact failure this whole file has
    /// to avoid, because it is indistinguishable from a bug in the player above it.
    ///
    /// So a fetch is refused only when an existing one is ALREADY GOING TO ARRIVE THERE — it is
    /// open-ended from a lower offset, so it will pass through. Anything else gets its own, up to a
    /// small ceiling that keeps a seeking player from opening a connection per window.
    ///
    /// Open-ended rather than range-sized on purpose: a player asks in small windows and re-asks
    /// constantly, and a request per window is a connection setup per few kilobytes.
    private func fetch(from offset: Int64) {
        if pending.values.contains(where: { $0.offset <= offset }) { return }
        guard pending.count < Self.maxConcurrentFetches else { return }
        var request = URLRequest(url: remote)
        request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
        let task = session.dataTask(with: request)
        pending[ObjectIdentifier(task)] = Fetch(task: task, offset: offset)
        task.resume()
    }

    /// Enough for the header, the moov lookup and the media stream to be in flight together, and few
    /// enough that a scrubbing player cannot open a connection per window.
    private static let maxConcurrentFetches = 3

    /// A tiny ranged GET whose only job is the length and the type. HEAD would be cheaper and is not
    /// reliable against every CDN; a one-byte range is.
    private func probe(_ done: @escaping (Int64?, String?) -> Void) {
        var request = URLRequest(url: remote)
        request.setValue("bytes=0-1", forHTTPHeaderField: "Range")
        // ⚠️ A SEPARATE SESSION FROM THE STREAMING ONE. `session` carries this class as its delegate,
        // and a task on a delegate session ignores its completion handler — the bytes would go to
        // `didReceive data:`, be filed against a fetch that does not exist, and this closure would
        // never run. That is a story stuck on its cover with no error anywhere.
        URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
            guard let self else { done(nil, nil); return }
            // Everything the caller does with this touches serialised state, so hand it back on the
            // one queue rather than on URLSession's.
            self.queue.async {
                guard let http = response as? HTTPURLResponse else { done(nil, nil); return }
                let total = Self.totalLength(from: http)
                if let data, !data.isEmpty, total != nil { self.partial.write(offset: 0, data: data) }
                done(total, http.mimeType)
            }
        }.resume()
    }

    /// The object's full size, from `Content-Range` on a 206 or `Content-Length` on a 200.
    private static func totalLength(from http: HTTPURLResponse) -> Int64? {
        if let range = http.value(forHTTPHeaderField: "Content-Range"),
           let slash = range.range(of: "/") {
            let tail = range[slash.upperBound...]
            if tail != "*", let n = Int64(tail) { return n }
        }
        if http.statusCode == 200, http.expectedContentLength > 0 { return http.expectedContentLength }
        return nil
    }
}

// MARK: - Bytes arriving

extension StoryVideoStream: URLSessionDataDelegate {

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        queue.async { [weak self] in
            if let http = response as? HTTPURLResponse, let total = Self.totalLength(from: http) {
                self?.partial.note(total: total, contentType: http.mimeType)
            }
            completionHandler(.allow)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        queue.async { [weak self] in
            guard let self, let fetch = self.pending[ObjectIdentifier(dataTask)] else { return }
            self.partial.write(offset: fetch.offset, data: data)
            fetch.offset += Int64(data.count)
            // Every waiting request gets another go at every arrival: a player asks for a window and
            // waits, and this is the only thing that ever answers it.
            for request in self.live { self.finishIfPossible(request) }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        queue.async { [weak self] in
            guard let self else { return }
            self.pending.removeValue(forKey: ObjectIdentifier(task))
            // (No promotion here — see `teardown`. Moving the file while it is still being read is
            // how a clip that had just finished downloading started downloading again.)
            guard error != nil else {
                for request in self.live { self.finishIfPossible(request) }
                return
            }
            // The transfer died with requests still open. Fail them rather than leave the player
            // waiting on bytes that are not coming — a silent hang is the one failure mode this
            // whole file has to avoid, because it looks exactly like a story that will not start.
            let stranded = self.live
            self.live.removeAll()
            stranded.forEach { $0.finishLoading(with: error) }
        }
    }
}
