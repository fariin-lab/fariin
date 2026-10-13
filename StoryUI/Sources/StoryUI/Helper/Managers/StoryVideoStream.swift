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
    /// ⛔ 1.5MB, NOT 512KB — owner 2026-10-12, "video stories take time". Our clips run ~3.4 Mbps
    /// (720p, `StoryVideoEncoder.videoBitrate`), so 512KB was about one second: the player met the
    /// network almost at once. 1.5MB is ~3.5s, enough for the live fetch to get ahead. It is also the
    /// FLOOR over a story's own recorded prefix (stories posted before this recorded 512KB).
    static let defaultPrefix: Int64 = 1536 * 1024

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

    /// Content-information requests held for a warm that has not learnt the clip's length yet.
    private var awaitingInfo: [AVAssetResourceLoadingRequest] = []
    private var warmToken: NSObjectProtocol?
    /// Set once this reader has started relying on somebody else's warm — see `fetchOrAwait`.
    private var warmDeadlineSet = false

    private init(remote: URL) {
        self.remote = remote
        self.partial = StoryPartialFile(remote: remote)
        super.init()
        let key = remote.absoluteString
        warmToken = NotificationCenter.default.addObserver(
            forName: Self.warmMovedNote, object: nil, queue: nil) { [weak self] note in
            guard let self, note.userInfo?["url"] as? String == key else { return }
            self.queue.async { self.warmMoved() }
        }
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
            if let warmToken { NotificationCenter.default.removeObserver(warmToken) }
            warmToken = nil
            awaitingInfo.removeAll()
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

    /// Whether a clip's opening (512KB, or the whole clip if shorter) is already in its partial file.
    /// Reads the small range map only. See `StoryItemVideoView.initializeVideoIfReady`.
    static func holdsOpening(_ remote: URL) -> Bool {
        guard enabled else { return false }
        let partial = StoryPartialFile(remote: remote)
        let want = min(512 * 1024, partial.total ?? 512 * 1024)
        return want > 0 && partial.holds(0 ..< want)
    }

    /// FETCH ONLY THE FIRST `bytes` OF A CLIP, for the lookahead. Nothing plays from this directly;
    /// it fills the same partial file the reader serves from, so arriving at the story finds the
    /// opening already here and starts on it while the rest streams in behind.
    static func warmPrefix(_ remote: URL, bytes: Int64, allowsCellular: Bool, urgent: Bool = false,
                           onTask: ((URLSessionTask) -> Void)? = nil,
                           onFinish: (() -> Void)? = nil) {
        guard enabled, bytes > 0 else { onFinish?(); return }
        let partial = StoryPartialFile(remote: remote)
        // Already here, or the whole clip already is — nothing to do either way. `onFinish` still
        // runs: the caller books the url in as running before this is called, and an early return
        // that skipped it would leave that entry behind for the life of the process.
        if partial.holds(0 ..< bytes) { onFinish?(); return }
        if CacheManager.cachedFileIfUsable(for: remote) != nil { onFinish?(); return }
        // From the end of what is already here: a warm cancelled part way keeps what it got.
        let from = partial.contiguousLength(from: 0, limit: bytes)
        var request = URLRequest(url: remote)
        request.setValue("bytes=\(from)-\(bytes - 1)", forHTTPHeaderField: "Range")
        request.allowsConstrainedNetworkAccess = false
        request.allowsExpensiveNetworkAccess = allowsCellular
        // ⛔ NOT BACKGROUND FOR THE VERY NEXT ITEM (owner 2026-10-12: Next onto a video froze for
        // seconds). The one about to be watched goes at normal priority, and first in line.
        request.networkServiceType = urgent ? .default : .background
        // ⛔ WRITTEN AS IT ARRIVES, NOT WHEN IT ENDS — owner 2026-10-13, "still a small late". This
        // warm used to hold every byte in memory until the last one, so a Next tapped while it was
        // still running (the usual case from a photo story: a few seconds is not enough on a phone
        // connection) found NOTHING on disk. The reader then fetched the same opening again from
        // byte zero, on a cold connection, competing with this one, and AVFoundation waited on it.
        // The reference app's preload goes into the same store its player reads from, as it
        // arrives, and its player reads whatever is there and waits for the rest. Now so does ours:
        // chunks land in the partial file and the map goes down every `warmAnnounceEvery`, and a
        // reader for this clip is told each time (see `warmMoved`).
        let task = warmSession.dataTask(with: request)
        task.priority = urgent ? URLSessionTask.highPriority : URLSessionTask.lowPriority
        let warm = Warm(key: remote.absoluteString, partial: partial, cursor: from, end: bytes,
                        urgent: urgent, task: task, onFinish: onFinish)
        warmLock.lock()
        warmsByTask[task.taskIdentifier] = warm
        warmsByURL[warm.key] = warm
        warmLock.unlock()
        // ⚠️ STILL NO PROMOTION FROM A WARM, EVEN THOUGH IT IS NOW SAFE FROM THE READER.
            //
            // `promoteIfComplete` is safe for the instance that OWNS the file: its own descriptor
            // survives the rename. It is not safe across instances, and this is the one place where
            // two exist for the same clip — the lookahead warms a neighbour while the viewer may
            // open a reader for it a moment later. That reader can be between its `cachedFileIfUsable`
            // check and its first read when this renames the file out from under it, and then
            // `openHandle` creates an EMPTY `.part`, the map says bytes are held, and the reader
            // answers the player with zeros. A truncated response is worse than a lost promotion,
            // which costs one more pass through the reader on the next open and nothing else.
        onTask?(task)
        task.resume()
    }

    /// The very next story's opening is ALREADY being fetched by an earlier, background warm (the
    /// chat list's arrival download): move it to the front rather than start a second one.
    static func expedite(_ remote: URL) {
        warmLock.lock(); defer { warmLock.unlock() }
        guard let w = warmsByURL[remote.absoluteString] else { return }
        w.urgent = true
        w.task.priority = URLSessionTask.highPriority
    }

    // MARK: - Warms a reader can see

    /// One prefix warm in flight. `cursor`, `unannounced` and `partial` are touched only on the
    /// warm session's serial delegate queue; `urgent` only under `warmLock`.
    fileprivate final class Warm {
        let key: String
        let partial: StoryPartialFile
        var cursor: Int64
        let end: Int64
        var urgent: Bool
        let task: URLSessionDataTask
        let onFinish: (() -> Void)?
        var unannounced: Int64 = 0
        init(key: String, partial: StoryPartialFile, cursor: Int64, end: Int64, urgent: Bool,
             task: URLSessionDataTask, onFinish: (() -> Void)?) {
            self.key = key; self.partial = partial; self.cursor = cursor; self.end = end
            self.urgent = urgent; self.task = task; self.onFinish = onFinish
        }
    }

    fileprivate static let warmLock = NSLock()
    fileprivate static var warmsByTask: [Int: Warm] = [:]
    fileprivate static var warmsByURL: [String: Warm] = [:]
    /// Posted with the clip's url string whenever a warm has put more of it on disk, learnt its
    /// length, or ended. A reader for that clip takes it in (see `warmMoved`).
    fileprivate static let warmMovedNote = Notification.Name("StoryVideoStream.warmMoved")
    /// 128KB: the first frames of a 720p clip, so a reader waiting on the opening is fed within a
    /// chunk or two of it arriving — and the map is written ~12 times per prefix, not per packet.
    fileprivate static let warmAnnounceEvery: Int64 = 128 * 1024

    /// ONE session for every warm, so the warms share their connections instead of each paying for
    /// a handshake. Serial delegate queue: a warm's state is only touched there.
    fileprivate static let warmSession: URLSession = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        return URLSession(configuration: .default, delegate: WarmRouter(), delegateQueue: q)
    }()

    fileprivate static func announce(_ key: String) {
        NotificationCenter.default.post(name: warmMovedNote, object: nil, userInfo: ["url": key])
    }

    /// The warm still fetching bytes at or after `offset` for this clip, if any.
    fileprivate static func warmAhead(of remote: URL, at offset: Int64) -> (task: URLSessionTask, urgent: Bool)? {
        warmLock.lock(); defer { warmLock.unlock() }
        guard let w = warmsByURL[remote.absoluteString], offset < w.end else { return nil }
        return (w.task, w.urgent)
    }

    fileprivate final class WarmRouter: NSObject, URLSessionDataDelegate {
        private func warm(for task: URLSessionTask) -> Warm? {
            StoryVideoStream.warmLock.lock(); defer { StoryVideoStream.warmLock.unlock() }
            return StoryVideoStream.warmsByTask[task.taskIdentifier]
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                        didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            guard let w = warm(for: dataTask), let http = response as? HTTPURLResponse else {
                completionHandler(.cancel); return
            }
            switch http.statusCode {
            case 206: break
            case 200: w.cursor = 0   // the server ignored the range: this is the file from byte 0
            default:
                // An error body is not video (see the streaming session's same rule).
                completionHandler(.cancel); return
            }
            if let total = StoryVideoStream.totalLength(from: http) {
                w.partial.note(total: total, contentType: http.mimeType)
                // The length is what a reader's content-information request is waiting on.
                StoryVideoStream.announce(w.key)
            }
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            guard let w = warm(for: dataTask), w.cursor < w.end else { dataTask.cancel(); return }
            // A whole-file answer is trimmed to the prefix; a ranged one already is.
            let keep = data.prefix(Int(min(Int64(data.count), w.end - w.cursor)))
            w.partial.write(offset: w.cursor, data: Data(keep))
            w.cursor += Int64(keep.count)
            w.unannounced += Int64(keep.count)
            if w.unannounced >= StoryVideoStream.warmAnnounceEvery {
                w.unannounced = 0
                w.partial.flush()
                StoryVideoStream.announce(w.key)
            }
            if w.cursor >= w.end { dataTask.cancel() }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            StoryVideoStream.warmLock.lock()
            let w = StoryVideoStream.warmsByTask.removeValue(forKey: task.taskIdentifier)
            if let w, StoryVideoStream.warmsByURL[w.key] === w {
                StoryVideoStream.warmsByURL.removeValue(forKey: w.key)
            }
            StoryVideoStream.warmLock.unlock()
            guard let w else { return }
            // Ended, finished or cancelled alike: everything that arrived is on disk, so the map
            // goes down and the reader is told, and whatever is missing it now fetches itself.
            w.partial.flush()
            StoryVideoStream.announce(w.key)
            w.onFinish?()
        }
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
            // A warm for this clip is already on the wire and will learn the length from its first
            // response; a probe would be a second round trip racing it. `warmMoved` answers this.
            if let w = Self.warmAhead(of: remote, at: 0) {
                awaitingInfo.append(request)
                lean(on: w)
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
        // A request whose length is still being learnt is not answerable yet; finishing it now
        // would tell the player the clip has no length.
        if let info = request.contentInformationRequest, info.contentLength == 0 { return }
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
            guard let total = partial.total else { fetchOrAwait(from: start); return }
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
        fetchOrAwait(from: start + held)
    }

    /// ⛔ ONE DOWNLOAD PER BYTE, NOT TWO — owner 2026-10-13. When the lookahead is still fetching
    /// this clip's opening, those bytes are already on the wire to the same file: starting a second
    /// transfer for them meant a cold connection racing a warm one for the same bandwidth, and the
    /// player waiting on the slower. So:
    /// - an URGENT warm (the very next story's, already first in line) is waited on; `warmMoved`
    ///   hands its bytes over as they land;
    /// - a BACKGROUND one (the chat list's arrival download, queued behind dozens) is stopped. What
    ///   it got is on disk, and its end is announced, after which this fetches the rest itself.
    /// Waiting is capped: if the warm is still running after `warmPatience`, it is stopped the same
    /// way, so a stuck connection cannot hold a story longer than a fresh one would.
    private func fetchOrAwait(from offset: Int64) {
        if pending.values.contains(where: { $0.offset <= offset }) { return }
        if let w = Self.warmAhead(of: remote, at: offset) {
            lean(on: w)
            return
        }
        fetch(from: offset)
    }

    private func lean(on w: (task: URLSessionTask, urgent: Bool)) {
        if !w.urgent {
            w.task.cancel()
        } else if !warmDeadlineSet {
            warmDeadlineSet = true
            let task = w.task
            queue.asyncAfter(deadline: .now() + Self.warmPatience) { task.cancel() }
        }
    }

    /// How long a reader leans on somebody else's warm before taking over. Long enough for a
    /// 1.5MB opening on an ordinary phone connection; a warm that has not finished by then is on a
    /// connection a fresh one is unlikely to beat by much, and nothing it got is lost.
    private static let warmPatience: TimeInterval = 2.5

    /// A warm for this clip moved on: more bytes, its length, or its end. Take in its map and give
    /// every waiting request another go.
    private func warmMoved() {
        guard warmToken != nil else { return }   // torn down
        partial.absorbDisk()
        let waiting = awaitingInfo
        awaitingInfo.removeAll()
        for r in waiting where live.contains(where: { $0 === r }) { serve(r) }
        for r in live where !waiting.contains(where: { $0 === r }) { finishIfPossible(r) }
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
