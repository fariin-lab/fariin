import Foundation
import AVFoundation

/// PLAY A PLAIN CHAT VIDEO WHILE IT IS STILL ARRIVING (2026-11-11, owner approved).
///
/// Until now a chat video was all or nothing: `MediaDownloads` fetched the whole object, the
/// finisher stored it in `VideoCache`, and only then could `VideoPlayerScreen` build a player. For a
/// clip stored in the clear (`EncMeta.plain`: every channel, and every group created since
/// 2026-10-19) nothing forces that wait, because the bytes on the server ARE the mp4, with its index
/// at the front. This class is the same idea as the story reader (`StoryVideoStream` in StoryUI),
/// built for chat video:
///
///   * ONE PARTIAL FILE PER CLIP, keyed by its item id (`<id>.part` in Caches/chat-video-stream),
///     with bytes at their real offsets, and a `ByteRangeMap` saying which ranges are there
///     (`<id>.partmeta`). The player, the preload of a row on screen and the fill that runs while
///     the clip is watched all write into that one file.
///   * THE PLAYER READS THROUGH A RESOURCE LOADER. The asset's url carries our own scheme, so
///     AVFoundation asks us for bytes; held bytes are answered from disk at once, missing ones are
///     fetched in 512 KB pieces with HTTP Range (up to 4 in flight). A piece the player is waiting
///     on goes first, and takes the place of the furthest-ahead fill piece when all slots are busy.
///     A seek is only a new offset.
///   * WHEN THE LAST BYTE LANDS, the file moves into `VideoCache` under the message id. Every later
///     open, Save, Share and Forward finds a normal cached clip, and `MediaDownloads` tells the
///     bubble behind the player that the clip is here.
///
/// Encrypted clips never come here: a 1:1 or old group clip is sealed as one piece, and nothing of
/// it can be checked before the last byte (see `canStream`).
///
/// Everything runs on one serial queue: the resource loader's callbacks, the URLSession's (its
/// delegate queue sits on top of the same queue) and the public calls. One lock-free state machine,
/// so a request can never wait on a lock held by the fetch that would answer it.
final class ChatVideoStream: NSObject {
    static let shared = ChatVideoStream()

    // MARK: - Switch

    /// Remote kill switch: `config/features.videoStream` (admin panel). Missing = on. Off sends every
    /// clip back to the full download, exactly as before this file. Read from the launch snapshot.
    static var enabled: Bool { RemoteFeatures.value("videoStream", default: true) }

    /// A clip that may stream: switch on, stored in the clear, in a group or channel (a 1:1 file is
    /// always sealed, and a "plain" one there is refused everywhere), on an https url.
    static func canStream(enc: EncMeta?, cid: String, url: String?) -> Bool {
        guard enabled, let enc, enc.isPlain, Crypto.isGroupCid(cid),
              let url, !url.isEmpty, let u = URL(string: url), u.scheme == "https" else { return false }
        return true
    }

    // MARK: - Tuning

    private static let scheme = "fariin-chatvideo"
    /// The fetch unit. 512 KB is about 2 s of our 2 Mbps clips: big enough that a request's round
    /// trip is small beside it, small enough that a seek wastes little.
    static let pieceSize: Int64 = 512 * 1024
    /// Transfers per clip at once (the player's, the read-ahead and the fill together).
    private static let maxFetches = 4
    /// How far past the offset the player is waiting on counts as urgent.
    private static let readAheadPieces = 4
    /// What a row on screen fetches before the tap: the index plus the first seconds.
    static let preloadBytes: Int64 = 1536 * 1024
    private static let maxPreloads = 2
    private static let maxQueuedPreloads = 6
    private static let metaSaveEvery: Int64 = 512 * 1024
    /// Network errors in a row (not cancels) before the waiting player is failed, which makes the
    /// viewer fall back to the full download.
    private static let maxNetworkErrors = 3
    private static let serveChunk: Int64 = 1 << 20
    /// Bytes handed to one request in one pass; the rest goes on the next turn of the queue, so a
    /// player asking for "everything to the end" of a clip that is mostly here does not hold the
    /// queue for tens of megabytes.
    private static let servePerPass: Int64 = 8 << 20

    /// Diag lines only where the diag file is kept at all (test builds; see `DiagUpload`).
    private static let logs = DiagUpload.allowed
    static func diag(_ line: @autoclosure () -> String) {
        guard logs else { return }
        DiagLog.add("VSTREAM# " + line())
    }

    // MARK: - State (queue only)

    private let queue = DispatchQueue(label: "chat.video.stream", qos: .userInitiated)
    private let dir: URL
    private var entries: [String: Entry] = [:]
    private var fetches: [Int: Fetch] = [:]
    private var loaders: [ObjectIdentifier: Loader] = [:]
    /// Item ids waiting for a preload slot, newest first.
    private var preloadQueue: [String] = []
    private var runningPreloads = 0

    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.default
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.timeoutIntervalForRequest = 20
        c.httpMaximumConnectionsPerHost = 6
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        q.underlyingQueue = queue
        return URLSession(configuration: c, delegate: self, delegateQueue: q)
    }()

    private final class Entry {
        let id: String
        let urlString: String
        let remote: URL
        var dataURL: URL
        let metaURL: URL
        var handle: FileHandle?
        var map = ByteRangeMap()
        var total: Int64?
        var unsaved: Int64 = 0
        var requests: [(r: AVAssetResourceLoadingRequest, owner: ObjectIdentifier)] = []
        /// Assets (open players) reading this clip.
        var watchers = 0
        /// Where the player last asked: the fill runs on from here.
        var playhead: Int64 = 0
        var errors = 0
        var failed = false
        var promoted = false
        /// A preload wants the clip up to here.
        var preloadEnd: Int64?
        var preloadCellular = false
        var holdsPreloadSlot = false
        init(id: String, urlString: String, remote: URL, dataURL: URL, metaURL: URL) {
            self.id = id; self.urlString = urlString; self.remote = remote
            self.dataURL = dataURL; self.metaURL = metaURL
        }
    }

    private final class Fetch {
        let entryId: String
        let start: Int64
        var cursor: Int64
        var end: Int64
        let task: URLSessionDataTask
        let isPreload: Bool
        init(entryId: String, range: Range<Int64>, task: URLSessionDataTask, isPreload: Bool) {
            self.entryId = entryId; self.start = range.lowerBound; self.cursor = range.lowerBound
            self.end = range.upperBound; self.task = task; self.isPreload = isPreload
        }
        func covers(_ x: Int64) -> Bool { cursor <= x && x < end }
    }

    /// The resource loader's delegate for one asset. AVFoundation holds it weakly; `loaders` keeps it.
    private final class Loader: NSObject, AVAssetResourceLoaderDelegate {
        unowned let owner: ChatVideoStream
        let id: String
        var key: ObjectIdentifier?
        init(owner: ChatVideoStream, id: String) { self.owner = owner; self.id = id }

        func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                            shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest) -> Bool {
            guard let key else { return false }
            owner.begin(request, id: id, key: key)
            return true
        }

        func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                            didCancel request: AVAssetResourceLoadingRequest) {
            owner.dropRequest(request, id: id)
        }
    }

    private override init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        dir = base.appendingPathComponent("chat-video-stream", isDirectory: true)
        super.init()
        let d = dir
        queue.async {
            let fm = FileManager.default
            try? fm.createDirectory(at: d, withIntermediateDirectories: true)
            // Partials nobody came back for in three days are dropped (Caches can also be purged by
            // iOS; `loadMeta` copes with a map whose file has gone).
            let cutoff = Date().addingTimeInterval(-3 * 24 * 3600)
            let items = (try? fm.contentsOfDirectory(at: d, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for f in items where ((try? f.resourceValues(forKeys: [.contentModificationDateKey]))?
                                    .contentModificationDate ?? .distantPast) < cutoff {
                try? fm.removeItem(at: f)
            }
        }
    }

    // MARK: - Public API

    /// An asset that plays `url` through the partial file of `itemId`, and the bytes already held
    /// (for the diag line). Nil: play it the old way. Call `release` with the asset when done.
    static func asset(itemId: String, url: String) -> (asset: AVURLAsset, held: Int64)? {
        shared.makeAsset(itemId, url)
    }

    /// The player is gone: stop its transfers, keep what arrived.
    static func release(_ asset: AVAsset?) {
        guard let asset else { return }
        let key = ObjectIdentifier(asset)
        shared.queue.async { shared.detach(key) }
    }

    /// Fetch the opening of a clip whose row came on screen. No-op when it is here already.
    static func preload(itemId: String, url: String, allowCellular: Bool) {
        shared.queue.async { shared.enqueuePreload(itemId, url, cellular: allowCellular) }
    }

    /// The row left the screen: drop its preload, unless a player is now reading the clip.
    static func cancelPreload(itemId: String) {
        shared.queue.async { shared.stopPreload(itemId) }
    }

    /// Sign-out and Clear Cache: every partial goes. Never call from the stream's own queue.
    static func removeAll() {
        shared.queue.sync { shared.wipe() }
    }

    // MARK: - Assets

    private func makeAsset(_ id: String, _ url: String) -> (asset: AVURLAsset, held: Int64)? {
        guard var comps = URLComponents(string: url) else { return nil }
        comps.scheme = Self.scheme
        guard let masked = comps.url else { return nil }
        let asset = AVURLAsset(url: masked)
        let loader = Loader(owner: self, id: id)
        let key = ObjectIdentifier(asset)
        loader.key = key
        let held: Int64? = queue.sync {
            guard let e = entry(id, url) else { return nil }
            e.watchers += 1
            e.failed = false
            e.errors = 0
            loaders[key] = loader
            // A preload still waiting for a slot is not needed any more: the player fetches now.
            if !e.holdsPreloadSlot {
                e.preloadEnd = nil
                preloadQueue.removeAll { $0 == id }
            }
            // A preload already on the wire for this clip is now the player's: first in line.
            for f in fetches.values where f.entryId == id { f.task.priority = URLSessionTask.highPriority }
            return e.map.count
        }
        guard let held else { return nil }
        asset.resourceLoader.setDelegate(loader, queue: queue)
        return (asset, held)
    }

    private func detach(_ key: ObjectIdentifier) {
        guard let loader = loaders.removeValue(forKey: key), let e = entries[loader.id] else { return }
        e.watchers = max(0, e.watchers - 1)
        let mine = e.requests.filter { $0.owner == key }
        e.requests.removeAll { $0.owner == key }
        mine.forEach { if !$0.r.isFinished && !$0.r.isCancelled { $0.r.finishLoading(with: URLError(.cancelled)) } }
        if e.watchers == 0 {
            for f in fetches.values where f.entryId == e.id && !f.isPreload { f.task.cancel() }
            flushMeta(e)
            promoteIfComplete(e)
        }
        settle(e)
    }

    // MARK: - Resource loader

    fileprivate func begin(_ request: AVAssetResourceLoadingRequest, id: String, key: ObjectIdentifier) {
        guard let e = entries[id], loaders[key] != nil else {
            request.finishLoading(with: URLError(.cancelled)); return
        }
        if e.failed { request.finishLoading(with: URLError(.badServerResponse)); return }
        if let d = request.dataRequest { e.playhead = d.requestedOffset }
        e.requests.append((r: request, owner: key))
        if serve(request, e) { e.requests.removeAll { $0.r === request } }
        pump(e)
    }

    fileprivate func dropRequest(_ request: AVAssetResourceLoadingRequest, id: String) {
        guard let e = entries[id] else { return }
        e.requests.removeAll { $0.r === request }
        // The fill keeps going while a player holds the asset: the player cancels and re-asks all
        // the time, and the rest of the clip is wanted anyway (Save, Forward, the next open).
    }

    /// Answer whatever of `request` is on disk. True when it is finished.
    private func serve(_ request: AVAssetResourceLoadingRequest, _ e: Entry) -> Bool {
        if request.isCancelled || request.isFinished { return true }
        // The player will not move without the length, a type and the promise that ranges work.
        if let info = request.contentInformationRequest, info.contentLength <= 0 {
            guard let total = e.total else { return false }
            // A UTI, not the MIME type: AVFoundation refuses "video/mp4" here.
            info.contentType = "public.mpeg-4"
            info.contentLength = total
            info.isByteRangeAccessSupported = true
        }
        guard let total = e.total else { return false }
        guard let d = request.dataRequest else { request.finishLoading(); return true }
        let end = d.requestsAllDataToEndOfResource
            ? total : min(total, d.requestedOffset + Int64(d.requestedLength))
        var at = d.currentOffset
        var budget = Self.servePerPass
        while at < end, budget > 0 {
            let run = e.map.contiguous(from: at, limit: min(end - at, Self.serveChunk, budget))
            guard run > 0, let bytes = read(e, at, run), !bytes.isEmpty else { break }
            d.respond(with: bytes)
            at += Int64(bytes.count)
            budget -= Int64(bytes.count)
        }
        if at >= end { request.finishLoading(); return true }
        if budget <= 0 {
            queue.async { [weak self, weak e] in
                guard let self, let e, self.entries[e.id] === e else { return }
                self.serveAll(e)
            }
        }
        return false
    }

    private func serveAll(_ e: Entry) {
        guard !e.requests.isEmpty else { return }
        let done = e.requests.filter { serve($0.r, e) }.map { ObjectIdentifier($0.r) }
        if !done.isEmpty { e.requests.removeAll { done.contains(ObjectIdentifier($0.r)) } }
    }

    // MARK: - Scheduling

    /// Start whatever transfers this clip needs now.
    private func pump(_ e: Entry) {
        guard !e.failed else { return }
        if e.watchers == 0 {
            if e.preloadEnd != nil, e.holdsPreloadSlot, !fetches.values.contains(where: { $0.entryId == e.id }) {
                startPreloadFetch(e)
            }
            return
        }
        let mine = fetches.values.filter { $0.entryId == e.id }
        guard let total = e.total else {
            // The first response tells us the length; until it does, one piece from the start.
            if mine.isEmpty {
                let from = e.map.contiguous(from: 0)
                startFetch(e, from ..< from + Self.pieceSize, urgent: true, isPreload: false)
            }
            return
        }
        var free = Self.maxFetches - mine.count
        let waits = e.requests.compactMap { $0.r.dataRequest?.currentOffset }.filter { $0 < total }.sorted()
        var wanted: [(range: Range<Int64>, urgent: Bool)] = []
        for w in waits {
            let horizon = min(total, w + Self.pieceSize * Int64(Self.readAheadPieces))
            for (i, r) in missingPieces(e, from: w, upTo: horizon, max: Self.readAheadPieces).enumerated() {
                wanted.append((r, i == 0 && r.lowerBound == w))
            }
        }
        // The fill: the rest of the clip from where the player is, then what lies before it.
        let ph = min(e.playhead, total)
        wanted += missingPieces(e, from: ph, upTo: total, max: Self.maxFetches).map { ($0, false) }
        wanted += missingPieces(e, from: 0, upTo: ph, max: Self.maxFetches).map { ($0, false) }

        for want in wanted {
            let live = fetches.values.filter { $0.entryId == e.id }
            if live.contains(where: { $0.covers(want.range.lowerBound) }) { continue }
            if free <= 0 {
                guard want.urgent else { break }
                // Every slot is busy and none of them will reach the byte the player is waiting
                // on: the furthest-ahead transfer nobody waits on gives way.
                let victim = live
                    .filter { f in !waits.contains(where: { f.covers($0) }) }
                    .max { $0.cursor < $1.cursor }
                guard let victim else { break }
                fetches.removeValue(forKey: victim.task.taskIdentifier)
                victim.task.cancel()
                if victim.isPreload { endPreload(e, fetched: victim.cursor - victim.start) }
                free += 1
            }
            // Stop where a running transfer picks up, so two never fetch the same bytes.
            var r = want.range
            if let next = live.map(\.cursor).filter({ $0 > r.lowerBound && $0 < r.upperBound }).min() {
                r = r.lowerBound ..< next
            }
            startFetch(e, r, urgent: want.urgent, isPreload: false)
            free -= 1
        }
    }

    /// The missing stretch of each piece from `from` up to `upTo`, at most `max` of them.
    private func missingPieces(_ e: Entry, from: Int64, upTo: Int64, max n: Int) -> [Range<Int64>] {
        guard from < upTo, n > 0 else { return [] }
        var out: [Range<Int64>] = []
        var i = from / Self.pieceSize
        while out.count < n {
            let lo = Swift.max(i * Self.pieceSize, from)
            guard lo < upTo else { break }
            let hi = Swift.min((i + 1) * Self.pieceSize, upTo)
            if let m = e.map.firstMissing(in: lo ..< hi) { out.append(m) }
            i += 1
        }
        return out
    }

    private func startFetch(_ e: Entry, _ r: Range<Int64>, urgent: Bool, isPreload: Bool) {
        guard !r.isEmpty else { return }
        var req = URLRequest(url: e.remote)
        req.setValue("bytes=\(r.lowerBound)-\(r.upperBound - 1)", forHTTPHeaderField: "Range")
        if isPreload {
            // Mobile data only when the videos setting allows it there; Low Data Mode counts as mobile.
            req.allowsExpensiveNetworkAccess = e.preloadCellular
            req.allowsConstrainedNetworkAccess = e.preloadCellular
        }
        let task = session.dataTask(with: req)
        task.priority = urgent ? URLSessionTask.highPriority
            : (isPreload ? URLSessionTask.lowPriority : URLSessionTask.defaultPriority)
        fetches[task.taskIdentifier] = Fetch(entryId: e.id, range: r, task: task, isPreload: isPreload)
        task.resume()
    }

    // MARK: - Preload

    private func enqueuePreload(_ id: String, _ url: String, cellular: Bool) {
        if VideoCache.url(for: id) != nil { return }
        guard let e = entry(id, url) else { return }
        let want = min(Self.preloadBytes, e.total ?? Self.preloadBytes)
        if e.promoted || e.map.contains(0 ..< want) || e.watchers > 0 { settle(e); return }
        if e.preloadEnd != nil { return }   // running or queued already
        e.preloadEnd = Self.preloadBytes
        e.preloadCellular = cellular
        if runningPreloads < Self.maxPreloads {
            runningPreloads += 1
            e.holdsPreloadSlot = true
            startPreloadFetch(e)
        } else {
            preloadQueue.insert(id, at: 0)
            while preloadQueue.count > Self.maxQueuedPreloads, let dropped = preloadQueue.popLast() {
                if let d = entries[dropped] { d.preloadEnd = nil; settle(d) }
            }
        }
    }

    private func startPreloadFetch(_ e: Entry) {
        guard let end = e.preloadEnd else { return }
        let target = min(end, e.total ?? end)
        let from = e.map.contiguous(from: 0)
        guard from < target else { endPreload(e, fetched: 0); return }
        startFetch(e, from ..< target, urgent: false, isPreload: true)
    }

    private func stopPreload(_ id: String) {
        preloadQueue.removeAll { $0 == id }
        guard let e = entries[id] else { return }
        guard e.watchers == 0 else { return }   // a player reads it now; its transfers are its own
        let running = fetches.values.filter { $0.entryId == id && $0.isPreload }
        if running.isEmpty {
            if !e.holdsPreloadSlot { e.preloadEnd = nil }
            settle(e)
            return
        }
        running.forEach { $0.task.cancel() }   // `didCompleteWithError` ends it and logs the bytes
    }

    /// A preload ended, finished or not. Its slot goes to the newest row waiting.
    private func endPreload(_ e: Entry, fetched: Int64) {
        if e.holdsPreloadSlot {
            e.holdsPreloadSlot = false
            runningPreloads = max(0, runningPreloads - 1)
            Self.diag("preload id=\(e.id) bytes=\(fetched) held=\(e.map.count) total=\(e.total ?? -1)")
        }
        e.preloadEnd = nil
        flushMeta(e)
        while runningPreloads < Self.maxPreloads, !preloadQueue.isEmpty {
            let id = preloadQueue.removeFirst()
            guard let next = entries[id], next.preloadEnd != nil else { continue }
            if next.watchers > 0 { next.preloadEnd = nil; continue }
            runningPreloads += 1
            next.holdsPreloadSlot = true
            startPreloadFetch(next)
        }
    }

    // MARK: - Entries and files

    private func entry(_ id: String, _ url: String) -> Entry? {
        if let e = entries[id] { return e }
        guard let remote = URL(string: url) else { return nil }
        let name = Self.fileName(id)
        let e = Entry(id: id, urlString: url, remote: remote,
                      dataURL: dir.appendingPathComponent(name + ".part"),
                      metaURL: dir.appendingPathComponent(name + ".partmeta"))
        loadMeta(e)
        entries[id] = e
        return e
    }

    /// Nothing reads it and nothing fetches for it: put the map down and forget it.
    private func settle(_ e: Entry) {
        guard entries[e.id] === e, e.watchers == 0, e.preloadEnd == nil,
              !fetches.values.contains(where: { $0.entryId == e.id }) else { return }
        flushMeta(e)
        promoteIfComplete(e)
        try? e.handle?.close()
        e.handle = nil
        entries[e.id] = nil
    }

    private static func fileName(_ id: String) -> String {
        String(id.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" })
    }

    private struct Meta: Codable {
        var total: Int64?
        var ranges: [[Int64]]
    }

    private func loadMeta(_ e: Entry) {
        let fm = FileManager.default
        guard let data = try? Data(contentsOf: e.metaURL),
              let m = try? JSONDecoder().decode(Meta.self, from: data) else { return }
        let map = ByteRangeMap(m.ranges.compactMap { $0.count == 2 && $0[0] < $0[1] ? $0[0] ..< $0[1] : nil })
        // A map whose file has gone, or is shorter than the map claims, would answer the player
        // with bytes that are not there. Both are dropped and the clip starts clean.
        let size = ((try? fm.attributesOfItem(atPath: e.dataURL.path))?[.size] as? NSNumber)?.int64Value
        guard let size, size >= (map.ranges.last?.upperBound ?? 0) else {
            try? fm.removeItem(at: e.metaURL)
            try? fm.removeItem(at: e.dataURL)
            return
        }
        e.map = map
        e.total = m.total
    }

    private func saveMeta(_ e: Entry) {
        guard !e.promoted else { return }
        let m = Meta(total: e.total, ranges: e.map.ranges.map { [$0.lowerBound, $0.upperBound] })
        if let data = try? JSONEncoder().encode(m) { try? data.write(to: e.metaURL, options: .atomic) }
        e.unsaved = 0
    }

    private func flushMeta(_ e: Entry) {
        if e.unsaved > 0 { saveMeta(e) }
    }

    private func openHandle(_ e: Entry) -> FileHandle? {
        if let h = e.handle { return h }
        let fm = FileManager.default
        if !fm.fileExists(atPath: e.dataURL.path) {
            // The file went (iOS purged Caches, or a wipe) while a map still named ranges in it.
            // Nothing is held, so the map says so; answering from a hole would play garbage.
            e.map = ByteRangeMap()
            e.unsaved = 0
            fm.createFile(atPath: e.dataURL.path, contents: nil,
                          attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        }
        e.handle = try? FileHandle(forUpdating: e.dataURL)
        return e.handle
    }

    private func read(_ e: Entry, _ offset: Int64, _ length: Int64) -> Data? {
        guard length > 0, let h = openHandle(e) else { return nil }
        do {
            try h.seek(toOffset: UInt64(offset))
            return try h.read(upToCount: Int(length))
        } catch {
            return nil
        }
    }

    private func write(_ e: Entry, _ offset: Int64, _ data: Data) {
        guard !data.isEmpty, !e.promoted, let h = openHandle(e) else { return }
        do {
            try h.seek(toOffset: UInt64(offset))
            try h.write(contentsOf: data)
            // Recorded only once it is really on disk: a range the map claims but the file lacks
            // is a clip that decodes garbage, and is found again by every later open.
            e.map.insert(offset ..< offset + Int64(data.count))
            e.unsaved += Int64(data.count)
            if e.unsaved >= Self.metaSaveEvery { saveMeta(e) }
        } catch {
            // Not recorded, so it is simply fetched again.
        }
    }

    /// Every byte is here: the file becomes the clip's normal cached copy.
    private func promoteIfComplete(_ e: Entry) {
        guard !e.promoted, let total = e.total, e.map.isComplete(total: total) else { return }
        try? e.handle?.synchronize()
        guard let dest = VideoCache.adopt(e.dataURL, for: e.id) else { return }
        // The open handle keeps reading the same file under its new name.
        e.dataURL = dest
        e.promoted = true
        e.unsaved = 0
        try? FileManager.default.removeItem(at: e.metaURL)
        Self.diag("complete id=\(e.id) bytes=\(total)")
        let url = e.urlString
        Task { @MainActor in MediaDownloads.shared.noteStoredElsewhere(url) }
    }

    private func fail(_ e: Entry, _ why: String) {
        guard !e.failed else { return }
        e.failed = true
        Self.diag("fail id=\(e.id) \(why) held=\(e.map.count)")
        for f in fetches.values where f.entryId == e.id {
            fetches.removeValue(forKey: f.task.taskIdentifier)
            f.task.cancel()
            if f.isPreload { endPreload(e, fetched: f.cursor - f.start) }
        }
        let stranded = e.requests
        e.requests.removeAll()
        stranded.forEach { $0.r.finishLoading(with: URLError(.badServerResponse)) }
        flushMeta(e)
    }

    private func learnTotal(_ e: Entry, _ total: Int64) {
        guard total > 0, e.total != total else { return }
        if e.total != nil {
            // The object changed size under us: what we hold belongs to another file.
            e.map = ByteRangeMap()
            try? e.handle?.truncate(atOffset: 0)
        }
        e.total = total
        saveMeta(e)
    }

    private static func totalLength(_ http: HTTPURLResponse) -> Int64? {
        if let range = http.value(forHTTPHeaderField: "Content-Range"), let slash = range.range(of: "/") {
            let tail = range[slash.upperBound...]
            if tail != "*", let n = Int64(tail) { return n }
        }
        if http.statusCode == 200, http.expectedContentLength > 0 { return http.expectedContentLength }
        return nil
    }

    private func wipe() {
        for f in fetches.values { f.task.cancel() }
        fetches.removeAll()
        for e in entries.values {
            e.requests.forEach { $0.r.finishLoading(with: URLError(.cancelled)) }
            e.requests.removeAll()
            try? e.handle?.close()
        }
        entries.removeAll()
        preloadQueue.removeAll()
        runningPreloads = 0
        let fm = FileManager.default
        for f in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] {
            try? fm.removeItem(at: f)
        }
    }
}

// MARK: - Bytes arriving (on the same queue)

extension ChatVideoStream: URLSessionDataDelegate {

    /// The status decides where the bytes go, before a single one is written: 206 at the offset we
    /// asked for; 200 (a server that ignored the range) from byte zero; anything else (an expired
    /// token's 403, a 404) is not video and fails the clip, so the viewer falls back.
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let f = fetches[dataTask.taskIdentifier], let e = entries[f.entryId],
              let http = response as? HTTPURLResponse else { completionHandler(.cancel); return }
        switch http.statusCode {
        case 206:
            if let t = Self.totalLength(http) {
                learnTotal(e, t)
                f.end = min(f.end, t)
            }
        case 200:
            f.cursor = 0
            if let t = Self.totalLength(http) {
                learnTotal(e, t)
                f.end = f.isPreload ? min(t, e.preloadEnd ?? Self.preloadBytes) : t
            }
        default:
            fetches.removeValue(forKey: dataTask.taskIdentifier)
            completionHandler(.cancel)
            if f.isPreload { endPreload(e, fetched: 0) }
            if e.watchers > 0 { fail(e, "status=\(http.statusCode)") } else { settle(e) }
            return
        }
        completionHandler(.allow)
        serveAll(e)
        pump(e)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let f = fetches[dataTask.taskIdentifier], let e = entries[f.entryId] else {
            dataTask.cancel(); return
        }
        let room = f.end - f.cursor
        guard room > 0 else { dataTask.cancel(); return }
        let keep = Int64(data.count) > room ? data.prefix(Int(room)) : data
        write(e, f.cursor, Data(keep))
        f.cursor += Int64(keep.count)
        if f.cursor >= f.end, keep.count < data.count { dataTask.cancel() }
        serveAll(e)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // Gone already when we cancelled it ourselves to make room, or failed the clip.
        guard let f = fetches.removeValue(forKey: task.taskIdentifier), let e = entries[f.entryId] else { return }
        let cancelled = (error as? URLError)?.code == .cancelled
        if f.isPreload { endPreload(e, fetched: f.cursor - f.start) }
        if let error, !cancelled, !f.isPreload, e.watchers > 0 {
            e.errors += 1
            Self.diag("neterr id=\(e.id) n=\(e.errors) \((error as? URLError)?.code.rawValue ?? -1)")
            if e.errors >= Self.maxNetworkErrors { fail(e, "network"); return }
            // A short pause, so a dead connection is not hammered.
            queue.asyncAfter(deadline: .now() + 0.5 * Double(e.errors)) { [weak self, weak e] in
                guard let self, let e, self.entries[e.id] === e else { return }
                self.pump(e)
            }
            return
        }
        if error == nil { e.errors = 0 }
        flushMeta(e)
        promoteIfComplete(e)
        serveAll(e)
        pump(e)
        settle(e)
    }
}
