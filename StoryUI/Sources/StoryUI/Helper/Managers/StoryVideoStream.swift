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
//  ⚠️ IT IS ON AS OF 2026-08-12 AND IT SHIPS ALONE. It was written switched off, in the same branch
//  as a complete replacement of the story playback engine, because a resource loader that misbehaves
//  does not throw — it simply never hands the player any bytes, which on screen is a story that
//  never starts, and that is not a thing to discover together with an architecture change.
//
//  Re-read end to end before the switch was flipped. FOUR THINGS CAME OUT OF THAT READ, all of them
//  silent failures rather than errors, which is this file's whole risk profile:
//
//    * a range the server does not honour was written at the offset we ASKED for. A 200 instead of a
//      206 filed a whole object as though it started where we wanted it to, and a 403 body — an
//      expired Storage token, which is a normal thing for a story url — was filed as video. Both
//      produced a corrupt cache file that every later open finds and trusts. Now the status decides:
//      206 as asked, 200 re-filed from zero, anything else fails its waiters.
//    * the concurrency ceiling could refuse a fetch that nothing else would ever satisfy — a
//      backward seek with three transfers already ahead of it. Now the furthest-ahead one gives way.
//    * the range map was re-read, merged and rewritten on EVERY chunk, on the same serial queue the
//      player is served from. See `StoryPartialFile.write`.
//    * a clip whose reader failed rebuilt the same reader instead of falling back to the plain url,
//      because on this path `localFile` IS the remote url. See `StoryItemVideoView`.
//

import Foundation
import AVFoundation

/// Serves an `AVURLAsset` from a partial file, fetching what it does not have.
///
/// One instance per clip, owned by the `AVURLAsset` it serves (AVFoundation holds the delegate
/// weakly, so `StoryVideoStream.retain` keeps it alive for the asset's life).
final class StoryVideoStream: NSObject, AVAssetResourceLoaderDelegate {

    /// ⚠️ THE SWITCH, AND IT IS ON AS OF 2026-08-12, ON HIS ORDER, AFTER THE ENGINE IT WAS HELD BACK
    /// FOR SHIPPED (build 548 onwards).
    ///
    /// False still means every caller falls straight through to the full-download path that shipped
    /// before this file, byte for byte — one line, and the way back if a device says so.
    static let enabled = true

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

    /// Throw away everything on disk for this clip, for a reader whose fetch has failed.
    ///
    /// Unlinking a file another instance still has open is safe — an open handle keeps reading the
    /// bytes it was opened on, and the next open finds nothing and starts clean. That is exactly the
    /// behaviour wanted: whatever is there was reached through a transfer that has just failed.
    static func discardPartial(for remote: URL) {
        StoryPartialFile(remote: remote).discard()
    }

    private func teardown() {
        queue.async { [self] in
            pending.values.forEach { $0.task.cancel() }
            pending.removeAll()
            let stranded = live
            live.removeAll()
            stranded.forEach { $0.finishLoading(with: URLError(.cancelled)) }
            // The range map is only written through periodically while bytes are arriving (see
            // `StoryPartialFile.write`), so the last stretch of a clip is on disk with nothing
            // saying so until this. Losing it costs a re-fetch of everything since the last save.
            partial.flush()
            // The last chance to promote, for a clip whose transfers all finished before this. A
            // clip that completed while it was being watched has already been promoted from
            // `didCompleteWithError`; this is a no-op then, and it is the only promotion for one
            // that was completed by a prefix warm.
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
                           onTask: ((URLSessionTask) -> Void)? = nil,
                           onFinish: (() -> Void)? = nil) {
        guard enabled, bytes > 0 else { onFinish?(); return }
        let partial = StoryPartialFile(remote: remote)
        // Already here, or the whole clip already is — nothing to do either way. `onFinish` still
        // runs: the caller books the url in as running before this is called, and an early return
        // that skipped it would leave that entry behind for the life of the process.
        if partial.holds(0 ..< bytes) { onFinish?(); return }
        if CacheManager.cachedFileIfUsable(for: remote) != nil { onFinish?(); return }
        var request = URLRequest(url: remote)
        request.setValue("bytes=0-\(bytes - 1)", forHTTPHeaderField: "Range")
        request.allowsConstrainedNetworkAccess = false
        request.allowsExpensiveNetworkAccess = allowsCellular
        request.networkServiceType = .background
        let task = URLSession.shared.dataTask(with: request) { data, response, _ in
            defer { onFinish?() }
            guard let data, !data.isEmpty,
                  let http = response as? HTTPURLResponse,
                  http.statusCode == 200 || http.statusCode == 206 else { return }
            if let total = Self.totalLength(from: http) {
                partial.note(total: total, contentType: http.mimeType)
            }
            partial.write(offset: 0, data: data)
            // This instance dies with this closure, so the map goes down now or not at all — and a
            // prefix nobody recorded is a prefix that gets fetched again on arrival, which is the
            // whole saving.
            partial.flush()
            // ⚠️ STILL NO PROMOTION FROM HERE, EVEN THOUGH IT IS NOW SAFE FROM THE READER.
            //
            // `promoteIfComplete` is safe for the instance that OWNS the file: its own descriptor
            // survives the rename. It is not safe across instances, and this is the one place where
            // two exist for the same clip — the lookahead warms a neighbour while the viewer may
            // open a reader for it a moment later. That reader can be between its `cachedFileIfUsable`
            // check and its first read when this renames the file out from under it, and then
            // `openHandle` creates an EMPTY `.part`, the map says bytes are held, and the reader
            // answers the player with zeros. A truncated response is worse than a lost promotion,
            // which costs one more pass through the reader on the next open and nothing else.
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
        // ⚠️ REFUSING AT THE CEILING USED TO MEAN WAITING FOR EVER, WHICH IS THE SAME HANG THIS
        // METHOD'S NOTE IS ABOUT, ARRIVING BY A DIFFERENT DOOR.
        //
        // Getting here means every open transfer is AHEAD of the offset somebody is waiting on — the
        // line above proved it — so not one of them will ever pass through it. That is a backward
        // seek with the ceiling full: the player has moved to where it is reading now, and the three
        // transfers still running are all for somewhere it has left. Nothing errors and nothing
        // times out; the story simply stops.
        //
        // The furthest-ahead one is the most speculative, so it makes room for the one that is
        // actually being waited on. Its own cancellation is handled in `didCompleteWithError` —
        // which must not read it as a failure, or this rescue would kill the story it is rescuing.
        if pending.count >= Self.maxConcurrentFetches {
            guard let furthest = pending.max(by: { $0.value.offset < $1.value.offset }) else { return }
            furthest.value.task.cancel()
            pending.removeValue(forKey: furthest.key)
        }
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
                guard let http = response as? HTTPURLResponse,
                      // The same rule as the streaming session's: bytes are only filed when the
                      // server actually answered with bytes. An error body is not a video.
                      http.statusCode == 200 || http.statusCode == 206 else { done(nil, nil); return }
                let total = Self.totalLength(from: http)
                if let data, !data.isEmpty, total != nil {
                    self.partial.write(offset: 0, data: data)
                    self.partial.flush()
                }
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

    /// ⚠️ THE STATUS CODE IS CHECKED BEFORE A SINGLE BYTE IS FILED, AND THIS IS THE ONE THAT WOULD
    /// HAVE BITTEN ON A REAL PHONE.
    ///
    /// Every byte that arrives here is written at the offset WE asked for. That is only true if the
    /// server honoured the range. Two ways it does not, and neither of them is an error anywhere:
    ///
    ///   * **200 instead of 206.** A CDN or a redirect that ignores `Range` answers with the whole
    ///     object from byte zero. Those bytes are real, so they are kept — but filed from zero,
    ///     where they actually start, instead of at an offset they never came from.
    ///   * **Anything else.** A story url is a Storage download url with a token on it, and an
    ///     expired one answers 403 with a JSON body. Without this, that body was written into the
    ///     cache file as though it were video and the range map recorded it as held — a corrupt
    ///     clip that every later open finds and never re-fetches, which is precisely what
    ///     `discard()` exists to prevent.
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        queue.async { [weak self] in
            guard let self else { completionHandler(.cancel); return }
            guard let http = response as? HTTPURLResponse else { completionHandler(.allow); return }
            switch http.statusCode {
            case 206:
                break
            case 200:
                self.pending[ObjectIdentifier(dataTask)]?.offset = 0
            default:
                self.pending.removeValue(forKey: ObjectIdentifier(dataTask))
                completionHandler(.cancel)
                // Fail the waiters rather than let them hang. A silent wait is indistinguishable
                // from a story that will not start; a failure reaches `handleFailedItem`, which
                // throws the partial away and plays the url directly.
                let stranded = self.live
                self.live.removeAll()
                stranded.forEach { $0.finishLoading(with: URLError(.badServerResponse)) }
                return
            }
            if let total = Self.totalLength(from: http) {
                self.partial.note(total: total, contentType: http.mimeType)
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
            //
            // ⚠️ A TRANSFER WE CANCELLED OURSELVES IS NOT A FAILED ONE. `fetch(from:)` drops the
            // furthest-ahead transfer to make room for one the player is actually waiting on, and
            // that cancellation arrives here as an error. Treating it as one would fail every open
            // request — the story would die at exactly the moment it was being rescued. The waiters
            // get another go instead, which is what the no-error path does anyway.
            let cancelled = (error as? URLError)?.code == .cancelled
            guard let error, !cancelled else {
                for request in self.live { self.finishIfPossible(request) }
                // ⚠️ PROMOTION HAPPENS HERE NOW, NOT ONLY AT TEARDOWN, and `promoteIfComplete`'s own
                // note is why that became safe. It matters because nothing outside this reader can
                // see a `.part`: the carousel's card stills and the frozen cover frame are made by
                // `StoryVideoFrames`, which needs a whole file from `cachedFileIfUsable`, and
                // waiting for the story to be LEFT meant a clip you were watching had none.
                self.partial.promoteIfComplete()
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
