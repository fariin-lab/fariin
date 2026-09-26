import Foundation
import UIKit
import FirebaseStorage

// ===== ONE DOWNLOAD PER FILE, FOR THE WHOLE APP =====
//
// Owner, 2026-09-26: "when someone sends me a photo or video the app should handle it exactly like the
// reference apps", with the architecture, not just the look. Eight research passes over both reference
// codebases; what they agree on, and what this file is:
//
//   1. ONE job per remote file, however many screens want it. The bubble, the viewer, the prefetch
//      sweep and save-to-Photos used to each call the network on their own, so one photo could be
//      fetched three times at once. Here every caller joins the same job, and the job is torn down
//      only when it finishes — never because the first caller went away.
//   2. THE BYTES OUTLIVE THE CELL. The chat rows dropped a finished download on the floor when the
//      cell had been reused in the meantime, so scrolling past a loading photo and back started it
//      again from zero. A job's finisher (decrypt + store) runs whether or not anyone is still looking.
//   3. A REAL STATE MACHINE the UI draws from: waiting for a tap → downloading (bytes, total) →
//      done, or failed (retryable / permanent). Nothing on screen invents its own.
//   4. TRANSIENT FAILURES RETRY BY THEMSELVES, with resume data so a retry continues where the last
//      attempt stopped instead of from byte zero. 403/404 is permanent (the mailman model deletes a
//      delivered object). Everything else backs off 1, 2, 4, 8, 16s, then waits for a tap, the
//      network coming back, or the app returning to the foreground.
//   5. BACKGROUNDING: a job in flight asks for background time to finish. If the time runs out it is
//      paused WITH its resume data written to disk, and it continues from there on the next
//      foreground — even after the app was killed, which neither a plain retry nor the old code did.
//   6. PRIORITY: a tap starts at once. Automatic jobs run at most `maxAuto` at a time, newest request
//      first, so what is on screen now beats what was flung past a second ago.
//   7. TEMP FILES: the downloaded ciphertext lives in one folder, is deleted the moment it has been
//      decrypted, and the folder is emptied on every launch. Resume files older than three days go too.
//
// ⚠️ MAIN THREAD ONLY. Every property is touched on the main thread: the session's delegate queue is
// `.main`, and the public API is `@MainActor`. The decrypt/store work runs detached in the finisher.

enum MediaDownloadState: Equatable {
    /// No job and nothing known. A caller that finds the file cached never asks, so this is also
    /// what a finished file looks like to someone who did not watch it finish.
    case none
    /// Held: the auto-download policy said no, the file is over the automatic size ceiling, or the
    /// user cancelled. A tap starts (or resumes) it. `total` is known when a response said so.
    case waitingTap(total: Int64?)
    /// Bytes are moving. `total` is nil until the response carries a length.
    case downloading(received: Int64, total: Int64?)
    /// `permanent`: the server no longer has the file (403/404) — a tap cannot help.
    case failed(permanent: Bool)
    case done

    var isActive: Bool { if case .downloading = self { return true }; return false }
    /// The fraction to draw, when there is an honest one.
    var fraction: Double? {
        guard case .downloading(let r, let t) = self, let t, t > 0 else { return nil }
        return min(1, max(0, Double(r) / Double(t)))
    }
}

@MainActor
final class MediaDownloads {
    static let shared = MediaDownloads()

    enum Priority: Int { case auto = 0, user = 1 }

    /// Decrypts and stores the downloaded file. Returns whether the result is really on disk.
    /// Runs detached, off the main thread; the file is deleted after it returns.
    typealias Finisher = @Sendable (URL) async -> Bool

    /// Automatic jobs running at once. The reference apps run more (12), but they are fetching from
    /// a CDN over HTTP/2 with much smaller chat photos; four keeps a flung chat from saturating a
    /// weak mobile link while the one photo he is looking at waits its turn.
    private let maxAuto = 4
    private let maxAttempts = 5

    private final class Job {
        let url: String
        var finish: Finisher
        var priority: Priority
        /// Automatic jobs over this many bytes stop at the headers and wait for a tap.
        var autoLimit: Int64?
        var state: MediaDownloadState = .none
        var task: URLSessionDownloadTask?
        var resumeData: Data?
        var attempts = 0
        var total: Int64?
        /// Waiting because HE cancelled it or it is over the automatic ceiling — as opposed to waiting
        /// on the policy. Only a tap may start it again; a row being laid out again must not.
        var heldForTap = false
        /// When the retries ran out. Views with no tap of their own (an album tile, a reply thumb)
        /// may ask again once this is old enough, instead of staying broken until a relaunch.
        var failedAt: Date?
        /// Why the running task is being cancelled, so its completion knows it was on purpose.
        var stopReason: StopReason?
        var retryWork: DispatchWorkItem?
        var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
        init(url: String, finish: @escaping Finisher, priority: Priority, autoLimit: Int64?) {
            self.url = url; self.finish = finish; self.priority = priority; self.autoLimit = autoLimit
        }
    }
    private enum StopReason { case user, overLimit, background }

    private var jobs: [String: Job] = [:]
    /// Automatic jobs waiting for a slot, oldest first; the newest is taken first.
    private var pending: [String] = []
    private var observers: [String: [UUID: (MediaDownloadState) -> Void]] = [:]
    /// Sizes learned from a response or from storage metadata, for the "15 MB" label.
    private var knownSizes: [String: Int64] = [:]
    /// Files moved out of URLSession's hands in `didFinishDownloadingTo`, awaiting their completion.
    private var landed: [Int: (file: URL, status: Int)] = [:]
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    private let workDir: URL
    private let resumeDir: URL
    private let delegate = SessionDelegate()
    private lazy var session: URLSession = {
        // The same parking behaviour chat media always had (see MediaSession): no path → wait for
        // one instead of failing at once. Its own session because this one needs a delegate.
        let c = URLSessionConfiguration.default
        c.waitsForConnectivity = true
        c.timeoutIntervalForRequest = 60
        c.timeoutIntervalForResource = 3600
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.httpMaximumConnectionsPerHost = 6
        // Same as MediaSession: a `fariin-photo://` name, should one ever reach a chat image view,
        // still opens through the signed-in Storage SDK.
        c.protocolClasses = [ProfilePhotoURLProtocol.self] + (c.protocolClasses ?? [])
        return URLSession(configuration: c, delegate: delegate, delegateQueue: .main)
    }()

    private init() {
        let fm = FileManager.default
        workDir = fm.temporaryDirectory.appendingPathComponent("media-dl", isDirectory: true)
        resumeDir = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("media-resume", isDirectory: true)
        // Rule 7: nothing in the work folder survives a launch — anything there is a ciphertext
        // whose decrypt never ran.
        try? fm.removeItem(at: workDir)
        try? fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: resumeDir, withIntermediateDirectories: true)
        let cutoff = Date().addingTimeInterval(-3 * 24 * 3600)
        if let old = try? fm.contentsOfDirectory(at: resumeDir, includingPropertiesForKeys: [.contentModificationDateKey]) {
            for f in old where ((try? f.resourceValues(forKeys: [.contentModificationDateKey]))?
                                    .contentModificationDate ?? .distantPast) < cutoff {
                try? fm.removeItem(at: f)
            }
        }
        delegate.owner = self
        let nc = NotificationCenter.default
        nc.addObserver(forName: .networkCameBack, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { MediaDownloads.shared.retryStalled() }
        }
        nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { MediaDownloads.shared.retryStalled() }
        }
        nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { MediaDownloads.shared.updateBackgroundTime() }
        }
    }

    // MARK: - Public API

    func state(for url: String) -> MediaDownloadState { jobs[url]?.state ?? .none }

    /// The size in bytes, if a response or the storage metadata has said.
    func knownSize(for url: String) -> Int64? { knownSizes[url] }

    /// Watch one file. The handler is called at once with the current state, then on every change.
    func observe(_ url: String, _ handler: @escaping (MediaDownloadState) -> Void) -> UUID {
        let id = UUID()
        observers[url, default: [:]][id] = handler
        handler(state(for: url))
        return id
    }

    func stopObserving(_ url: String, _ id: UUID) {
        observers[url]?[id] = nil
        if observers[url]?.isEmpty == true { observers[url] = nil }
    }

    /// Start or join the job for `url`.
    ///
    /// - `autoAllowed`: false when the auto-download policy holds this file. An automatic request
    ///   then only records `.waitingTap` so the bubble can show its Download button.
    /// - `autoLimit`: bytes over which an AUTOMATIC job stops at the headers and waits for a tap.
    /// A `.user` request always runs, and upgrades a waiting or queued automatic job.
    func request(_ url: String, priority: Priority, autoAllowed: Bool = true,
                 autoLimit: Int64? = nil, finish: @escaping Finisher) {
        guard !url.isEmpty else { return }
        if let job = jobs[url] {
            if priority == .user {
                job.heldForTap = false
                if job.priority == .auto { job.priority = .user; job.autoLimit = nil }
            }
            switch job.state {
            case .downloading:
                if job.task == nil, priority == .user { start(job) }   // queued → jump the queue
            case .done:
                break
            case .failed(let permanent):
                let cooled = Date().timeIntervalSince(job.failedAt ?? .distantPast) > 30
                if !permanent, priority == .user || cooled { job.attempts = 0; enqueueOrStart(job) }
            case .waitingTap, .none:
                // A policy hold lifts by itself when the policy allows (Wi-Fi came back); a hold he
                // chose, or the size ceiling, waits for his tap.
                if priority == .user || (autoAllowed && !job.heldForTap) { enqueueOrStart(job) }
            }
            return
        }
        let job = Job(url: url, finish: finish, priority: priority, autoLimit: priority == .auto ? autoLimit : nil)
        jobs[url] = job
        if priority == .auto, !autoAllowed {
            set(job, .waitingTap(total: knownSizes[url]))
            return
        }
        enqueueOrStart(job)
    }

    /// Start or join, and wait for the outcome. True when the file was downloaded and the finisher
    /// stored it. False when it ended waiting for a tap, failed, or the calling task was cancelled
    /// (the download itself carries on: someone asked for these bytes and they will be wanted again).
    func download(_ url: String, priority: Priority, autoAllowed: Bool = true,
                  autoLimit: Int64? = nil, finish: @escaping Finisher) async -> Bool {
        request(url, priority: priority, autoAllowed: autoAllowed, autoLimit: autoLimit, finish: finish)
        guard let job = jobs[url] else { return false }
        switch job.state {
        case .done: return true
        case .failed, .waitingTap: return false
        case .none, .downloading: break
        }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                if Task.isCancelled { cont.resume(returning: false); return }
                job.waiters[id] = cont
            }
        } onCancel: {
            Task { @MainActor in
                if let c = job.waiters.removeValue(forKey: id) { c.resume(returning: false) }
            }
        }
    }

    /// The tap on a downloading item: stop it, keep what arrived, and wait for another tap —
    /// both references cancel on that tap rather than ignoring it.
    func cancel(_ url: String) {
        guard let job = jobs[url] else { return }
        pending.removeAll { $0 == url }
        job.retryWork?.cancel(); job.retryWork = nil
        if let task = job.task {
            job.stopReason = .user
            pause(task, job)
        } else if job.state.isActive {
            job.heldForTap = true
            set(job, .waitingTap(total: job.total))
            resumeWaiters(job, false)
        }
    }

    /// The size of a remote file without downloading it, for a Download button that names its cost.
    /// Storage metadata is one small request, readable by exactly whoever may read the file.
    func fetchSize(_ url: String) async -> Int64? {
        if let s = knownSizes[url] { return s }
        guard url.contains("firebasestorage"),
              let meta = try? await Storage.storage().reference(forURL: url).getMetadata() else { return nil }
        knownSizes[url] = meta.size
        return meta.size
    }

    // MARK: - Scheduling

    private func enqueueOrStart(_ job: Job) {
        job.retryWork?.cancel(); job.retryWork = nil
        if job.task != nil { return }
        if job.priority == .user || runningAutoCount() < maxAuto {
            start(job)
        } else {
            pending.removeAll { $0 == job.url }
            pending.append(job.url)
            // Queued is still "on its way" as far as the bubble is concerned.
            set(job, .downloading(received: 0, total: job.total ?? knownSizes[job.url]))
        }
    }

    private func runningAutoCount() -> Int {
        jobs.values.filter { $0.task != nil && $0.priority == .auto }.count
    }

    private func startNextPending() {
        while runningAutoCount() < maxAuto, let url = pending.popLast() {
            if let job = jobs[url], job.task == nil { start(job) }
        }
    }

    private func start(_ job: Job) {
        pending.removeAll { $0 == job.url }
        guard let u = URL(string: job.url) else { finishJob(job, .failed(permanent: true)); return }
        if job.resumeData == nil { job.resumeData = loadResume(job.url) }
        let task: URLSessionDownloadTask
        if let data = job.resumeData {
            task = session.downloadTask(withResumeData: data)
            job.resumeData = nil
            removeResume(job.url)
        } else {
            task = session.downloadTask(with: u)
        }
        task.taskDescription = job.url
        task.priority = job.priority == .user ? URLSessionTask.highPriority : URLSessionTask.defaultPriority
        job.task = task
        job.stopReason = nil
        set(job, .downloading(received: 0, total: job.total ?? knownSizes[job.url]))
        task.resume()
        updateBackgroundTime()
    }

    private func pause(_ task: URLSessionDownloadTask, _ job: Job) {
        task.cancel(byProducingResumeData: { data in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let data else { return }
                    job.resumeData = data
                    // Written to disk so the next launch continues too (rule 5).
                    MediaDownloads.shared.saveResume(data, for: job.url)
                }
            }
        })
    }

    /// Everything that failed for a reason time can fix, restarted: the signal came back, or the app
    /// is in front again (which also picks up jobs the background time ran out on).
    func retryStalled() {
        for job in jobs.values where job.task == nil {
            if case .failed(false) = job.state {
                job.attempts = 0
                enqueueOrStart(job)
            }
        }
    }

    // MARK: - Session events

    fileprivate func didWrite(_ task: URLSessionDownloadTask, written: Int64, expected: Int64) {
        guard let url = task.taskDescription, let job = jobs[url], job.task === task else { return }
        let total: Int64? = expected > 0 ? expected : nil
        if let total {
            job.total = total
            knownSizes[url] = total
            // The ceiling for automatic downloads: the first callback carries the length, so an
            // over-limit file costs its headers and nothing more.
            if job.priority == .auto, let limit = job.autoLimit, total > limit {
                job.stopReason = .overLimit
                pause(task, job)
                return
            }
        }
        set(job, .downloading(received: written, total: total))
    }

    fileprivate func didLand(_ task: URLSessionDownloadTask, at location: URL) {
        // URLSession deletes `location` when this returns, so the move must happen here, now.
        let dest = workDir.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.moveItem(at: location, to: dest)
        let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
        landed[task.taskIdentifier] = (dest, status)
    }

    fileprivate func didComplete(_ task: URLSessionTask, error: Error?) {
        let arrival = landed.removeValue(forKey: task.taskIdentifier)
        guard let url = task.taskDescription, let job = jobs[url], job.task === task else {
            if let f = arrival?.file { try? FileManager.default.removeItem(at: f) }
            return
        }
        job.task = nil
        defer { startNextPending(); updateBackgroundTime() }

        if let reason = job.stopReason {
            job.stopReason = nil
            if let f = arrival?.file { try? FileManager.default.removeItem(at: f) }
            switch reason {
            case .user, .overLimit:
                job.heldForTap = true
                set(job, .waitingTap(total: job.total))
                resumeWaiters(job, false)
            case .background:
                // Parked, not failed: the next foreground restarts it from its resume data.
                set(job, .failed(permanent: false))
            }
            return
        }

        if error == nil, let arrival, (200..<300).contains(arrival.status) {
            let finish = job.finish
            let file = arrival.file
            Task.detached(priority: job.priority == .user ? .userInitiated : .utility) {
                let ok = await finish(file)
                try? FileManager.default.removeItem(at: file)
                await MainActor.run {
                    // A download that decrypts to nothing is corrupt or truncated. Once more from
                    // scratch; after that it is a failure the user can retry.
                    if ok {
                        MediaDownloads.shared.finishJob(job, .done)
                    } else {
                        MediaDownloads.shared.retryOrFail(job, resumeData: nil)
                    }
                }
            }
            return
        }
        if let f = arrival?.file { try? FileManager.default.removeItem(at: f) }

        if let status = arrival?.status, status == 403 || status == 404 {
            // Gone from the server. For a delivered 1:1 video that is the mailman model working.
            finishJob(job, .failed(permanent: true))
            return
        }
        let resume = (error as NSError?)?.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        retryOrFail(job, resumeData: resume)
    }

    private func retryOrFail(_ job: Job, resumeData: Data?) {
        job.resumeData = resumeData
        job.attempts += 1
        guard job.attempts < maxAttempts else {
            if let d = resumeData { saveResume(d, for: job.url) }
            job.failedAt = Date()
            set(job, .failed(permanent: false))
            resumeWaiters(job, false)
            return
        }
        // Backoff 1, 2, 4, 8s. The bubble keeps its ring meanwhile: to him this is still loading.
        let delay = pow(2.0, Double(job.attempts - 1))
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.jobs[job.url] === job, job.task == nil else { return }
                self.enqueueOrStart(job)
            }
        }
        job.retryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func finishJob(_ job: Job, _ end: MediaDownloadState) {
        set(job, end)
        resumeWaiters(job, end == .done)
        removeResume(job.url)
        // A finished job has nothing left to share; the caches answer from here on. A permanent
        // failure stays so the bubble keeps saying so instead of trying again.
        if end == .done { jobs[job.url] = nil }
    }

    private func set(_ job: Job, _ s: MediaDownloadState) {
        guard job.state != s else { return }
        job.state = s
        observers[job.url]?.values.forEach { $0(s) }
    }

    private func resumeWaiters(_ job: Job, _ ok: Bool) {
        let w = job.waiters
        job.waiters = [:]
        w.values.forEach { $0.resume(returning: ok) }
    }

    // MARK: - Background time (rule 5)

    private func updateBackgroundTime() {
        let active = jobs.values.contains { $0.task != nil }
        if active, backgroundTask == .invalid {
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "MediaDownloads") {
                MainActor.assumeIsolated { MediaDownloads.shared.backgroundTimeExpired() }
            }
        } else if !active, backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }

    private func backgroundTimeExpired() {
        for job in jobs.values {
            guard let task = job.task else { continue }
            job.stopReason = .background
            pause(task, job)
        }
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }

    // MARK: - Resume files

    private func resumeFile(_ url: String) -> URL {
        let safe = Data(url.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "+", with: "-")
        return resumeDir.appendingPathComponent(String(safe.suffix(120)) + ".resume")
    }
    private func loadResume(_ url: String) -> Data? { try? Data(contentsOf: resumeFile(url)) }
    fileprivate func saveResume(_ d: Data, for url: String) { try? d.write(to: resumeFile(url), options: .atomic) }
    private func removeResume(_ url: String) { try? FileManager.default.removeItem(at: resumeFile(url)) }
}

/// URLSession holds its delegate strongly and calls it on `.main` (the session's delegate queue), so
/// every hop into the actor-isolated owner is already on the main thread.
private final class SessionDelegate: NSObject, URLSessionDownloadDelegate {
    weak var owner: MediaDownloads?

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        MainActor.assumeIsolated {
            owner?.didWrite(downloadTask, written: totalBytesWritten, expected: totalBytesExpectedToWrite)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didResumeAtOffset fileOffset: Int64, expectedTotalBytes: Int64) {
        MainActor.assumeIsolated {
            owner?.didWrite(downloadTask, written: fileOffset, expected: expectedTotalBytes)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        MainActor.assumeIsolated { owner?.didLand(downloadTask, at: location) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        MainActor.assumeIsolated { owner?.didComplete(task, error: error) }
    }
}

// ===== What each kind of media does with its bytes =====

enum MediaFetch {
    /// Decrypt a downloaded file with the conversation's key (or pass legacy plaintext through).
    static func clearBytes(_ file: URL, enc: EncMeta?, cid: String) async -> Data? {
        guard let cipher = try? Data(contentsOf: file, options: .mappedIfSafe) else { return nil }
        guard let enc else { return cipher }
        return await Crypto.shared.decryptBytes(cid, cipher: cipher, meta: enc)
    }

    /// A chat photo: decrypt, bound for display, and store as an OWNED file (the mailman model may
    /// delete the server copy, so this is the phone's only one).
    static func photoFinisher(url: String, enc: EncMeta?, cid: String) -> MediaDownloads.Finisher {
        { file in
            guard let clear = await clearBytes(file, enc: enc, cid: cid),
                  let raw = UIImage(data: clear) else { return false }
            let bounded = raw.boundedForDisplay()
            let ready = (bounded === raw ? raw.preparingForDisplay() : bounded) ?? raw
            DiskImageCache.shared.store(ready, data: clear, for: url, owned: true)
            return true
        }
    }

    /// Start (or join) a chat photo's download under the photos policy.
    /// `gated`: the chat bubble's photos obey Settings › Storage and Data and the automatic ceiling;
    /// other callers (the viewer, a reply thumbnail) are the user asking for it directly.
    @MainActor
    static func requestPhoto(url: String, enc: EncMeta?, cid: String, gated: Bool,
                             priority: MediaDownloads.Priority = .auto) {
        MediaDownloads.shared.request(url, priority: priority,
                                      autoAllowed: !gated || AutoDownloadPrefs.allowedNow(.photos),
                                      autoLimit: gated ? MediaAutoDownloader.photoAutoBytes : nil,
                                      finish: photoFinisher(url: url, enc: enc, cid: cid))
    }

    /// A chat video: decrypt into VideoCache, and only once the local copy is really there, remove
    /// the server copy of a delivered 1:1 clip (the mailman model; the player used to do this, so a
    /// clip that arrived through the prefetch sweep was never picked up server-side).
    static func videoFinisher(url: String, enc: EncMeta?, cid: String, messageId: String,
                              authorId: String) -> MediaDownloads.Finisher {
        { file in
            guard let clear = await clearBytes(file, enc: enc, cid: cid),
                  VideoCache.store(clear, for: messageId) else { return false }
            let me = await MainActor.run { AuthService.shared.uid }
            if cid.contains("_"), authorId != me {
                try? await Storage.storage().reference(forURL: url).delete()
            }
            return true
        }
    }

    @MainActor
    static func requestVideo(url: String, enc: EncMeta?, cid: String, messageId: String,
                             authorId: String, priority: MediaDownloads.Priority) {
        MediaDownloads.shared.request(url, priority: priority,
                                      autoAllowed: AutoDownloadPrefs.allowedNow(.videos),
                                      autoLimit: MediaAutoDownloader.maxAutoBytes,
                                      finish: videoFinisher(url: url, enc: enc, cid: cid,
                                                            messageId: messageId, authorId: authorId))
    }

    /// Any other file (voice note, document): decrypt and hand the bytes to `store`.
    static func dataFinisher(enc: EncMeta?, cid: String,
                             store: @escaping @Sendable (Data) -> Bool) -> MediaDownloads.Finisher {
        { file in
            guard let clear = await clearBytes(file, enc: enc, cid: cid) else { return false }
            return store(clear)
        }
    }
}
