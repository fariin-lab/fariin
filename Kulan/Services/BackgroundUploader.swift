import Foundation
import FirebaseAuth
import FirebaseCore

/// ⛔ AN UPLOAD MUST NOT BELONG TO THE APP THAT STARTED IT (owner, 2026-08-25: "fix it, every
/// corner, even bad network").
///
/// What was wrong: `Storage.putFile` runs inside our process. iOS grants a departing app about
/// thirty seconds and then freezes it, so leaving the app mid-send stops the transfer — and because
/// Firebase's iOS SDK sets its chunk size to LLONG_MAX, nothing was ever chunked, so the server
/// remembered nothing and the next attempt started from byte zero. On a 25 MB video over mobile
/// data that is the difference between arriving and not.
///
/// What this does instead: hands the file to iOS. A background `URLSession` is run by the SYSTEM,
/// not by us. It keeps going while the app is in the background, while the phone is locked, and it
/// wakes the app when it finishes. That is the property the reference apps have and we did not.
///
/// The protocol is Google's resumable upload, which is what Firebase Storage speaks underneath:
///   1. ask for a slot   → POST …?uploadType=resumable, command `start`, and it hands back a
///                          private upload URL
///   2. send the bytes   → POST that URL, command `upload, finalize`, body is the file
///   3. if it breaks     → POST that URL, command `query`, and it says how many bytes it kept.
///                          Send the rest from there. THAT is the resume, and it is the whole point.
/// The finalize reply is the object's metadata, including the download token, so the URL this
/// returns has exactly the shape `StorageReference.downloadURL()` produced before.
///
/// ⚠️ WHAT THIS DOES NOT SURVIVE: the app being KILLED (swiped away, or jetsammed). The system
/// finishes the transfer, but the code that would attach the finished URL to the message died with
/// the process, so on the next launch those tasks are cancelled deliberately — see `adopt()` — and
/// the message is left failed for `autoRetryFailedMedia` to re-drive. That is no worse than today.
/// Surviving a kill as well means persisting the upload URL beside the message and finishing the
/// attach on launch, which is the next piece of work, not this one.
///
/// ⚠️ AND IT IS BEHIND `UploadEngine.backgroundEnabled`, WHICH SHIPS OFF. This code cannot be
/// compiled or run on the machine it was written on, and it sits on the one path every photo, video,
/// voice note and document goes through. Off by default means a bad detail here cannot break media
/// sending for everyone; the switch is in Settings → Storage and Data, so testing it costs a tap
/// rather than a build.
enum UploadEngine {
    private static let key = "upload.background.enabled"

    /// Off until it has been proven on a real phone. See the note above.
    static var backgroundEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

/// Errors this uploader raises are all transport-shaped on purpose: `ChatService.isRetryableUpload`
/// only refuses to retry things it recognises as refusals (unauthorized, over quota), and anything
/// it cannot identify is treated as transport. A failure here should be retried.
enum BackgroundUploadError: LocalizedError {
    case notSignedIn
    case noBucket
    case noUploadURL
    case badStatus(Int)
    case noDownloadToken

    var errorDescription: String? {
        switch self {
        case .notSignedIn:      return "Not signed in."
        case .noBucket:         return "No storage bucket configured."
        case .noUploadURL:      return "The upload could not be started."
        case .badStatus(let c): return "The upload was refused (\(c))."
        case .noDownloadToken:  return "The upload finished but returned no address."
        }
    }
}

final class BackgroundUploader: NSObject {
    static let shared = BackgroundUploader()

    /// What a caller must say for an upload to survive the app being killed: which message the
    /// finished URL belongs to, and under which field. Without it the upload still works, it just
    /// cannot be picked up by a later launch — see `PendingUpload`.
    struct Attach {
        let cid: String
        let messageId: String
        let urlField: String
        let enc: EncMeta?
    }

    /// ⚠️ THE IDENTIFIER IS PART OF THE CONTRACT WITH iOS, not a name. Recreating a session with the
    /// same string is how a relaunched app is handed back the transfers the system was carrying for
    /// it. Change it and every upload in flight at that moment is orphaned.
    static let sessionIdentifier = "com.fariin.messenger.upload"

    /// Set by the app delegate when iOS wakes us for a finished transfer, and called once the
    /// session says it has delivered everything. Not calling it is a watchdog kill.
    var systemCompletionHandler: (() -> Void)?

    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        // ⛔ NOT DISCRETIONARY. Discretionary lets iOS wait for Wi-Fi and a charger, which is right
        // for a nightly sync and wrong for a person who just pressed send and is watching the ring.
        c.isDiscretionary = false
        c.sessionSendsLaunchEvents = true      // wake us when it lands
        // Park rather than fail when the radio has nothing — the same reasoning `MediaSession`
        // spells out for downloads. A lift is not a failure.
        c.waitsForConnectivity = true
        c.timeoutIntervalForRequest = 120
        // A whole day for one upload. It sounds absurd for a photo and it is right for a video on a
        // connection that comes and goes: the alternative is giving up on bytes already sent.
        c.timeoutIntervalForResource = 24 * 3600
        c.urlCache = nil
        return URLSession(configuration: c, delegate: self, delegateQueue: nil)
    }()

    private struct Waiter {
        let continuation: CheckedContinuation<Data, Error>
        let progressId: String?
        /// Bytes already on the server before this task started, and the size of the whole file.
        /// A resume sends only the tail, so the task's own numbers describe the tail — reporting
        /// those straight to the ring would send it back to zero and count the remainder as if it
        /// were the lot.
        let base: Int64
        let total: Int64
    }

    private let lock = NSLock()
    private var waiters: [Int: Waiter] = [:]   // taskIdentifier → who is awaiting it
    private var bodies: [Int: Data] = [:]      // taskIdentifier → the reply, gathered as it arrives

    // MARK: - Launch

    /// Called once at launch. Any transfer the system is still carrying belongs to a process that no
    /// longer exists, so nobody is waiting on it and nobody will attach its result to a message —
    /// cancelling is what stops us paying to store an object no message will ever point at. The
    /// message itself is already failed and `autoRetryFailedMedia` re-drives it.
    func adopt() {
        session.getAllTasks { tasks in
            for t in tasks {
                let orphan = self.lock.withLock { self.waiters[t.taskIdentifier] == nil }
                if orphan { t.cancel() }
            }
        }
    }

    // MARK: - Upload

    /// Uploads `file` to `path` in the app's Storage bucket and returns a download URL of the same
    /// shape `StorageReference.downloadURL()` returns, so callers cannot tell the difference.
    func upload(file: URL, to path: String, contentType: String, progressId: String?,
                attach: Attach? = nil) async throws -> String {
        guard let bucket = FirebaseApp.app()?.options.storageBucket, !bucket.isEmpty else {
            throw BackgroundUploadError.noBucket
        }
        guard let user = Auth.auth().currentUser else { throw BackgroundUploadError.notSignedIn }
        let token = try await user.getIDToken()
        let size = fileSize(file)

        let uploadURL = try await startSession(bucket: bucket, path: path, contentType: contentType,
                                               size: size, token: token)
        // ⛔ THE ADDRESS IS WRITTEN DOWN BEFORE A SINGLE BYTE GOES. If this process dies in the next
        // second, the next launch still knows where the transfer lives, what was being sent and
        // where the answer belongs. Written here rather than after the upload for exactly that
        // reason: the window this protects starts now.
        let jobId = UUID().uuidString
        if let attach {
            PendingUploadStore.add(PendingUpload(id: jobId, uploadURL: uploadURL, bucket: bucket,
                                                 storagePath: path, filePath: file.path,
                                                 cid: attach.cid, messageId: attach.messageId,
                                                 urlField: attach.urlField, enc: attach.enc,
                                                 startedAt: Date()))
        }
        defer { if attach != nil { PendingUploadStore.remove(jobId) } }
        var reply: Data
        do {
            reply = try await send(file: file, from: 0, to: uploadURL, size: size,
                                   token: token, progressId: progressId)
        } catch {
            // ⛔ THIS IS THE RESUME, and it is the reason for the whole file. Ask what landed, send
            // the rest. A dropped connection now costs the bytes that were in flight, not the ones
            // already delivered.
            guard !(error is CancellationError) else { throw error }
            let received = try await receivedOffset(uploadURL, token: token)
            guard received < size else {
                // Everything arrived and only the reply was lost. Finalising from the end is how the
                // server is asked to close the object and hand back its metadata.
                reply = try await send(file: file, from: size, to: uploadURL, size: size,
                                       token: token, progressId: nil)
                return try downloadURL(bucket: bucket, path: path, reply: reply)
            }
            reply = try await send(file: file, from: received, to: uploadURL, size: size,
                                   token: token, progressId: progressId)
        }
        return try downloadURL(bucket: bucket, path: path, reply: reply)
    }

    /// Finish a job this process did not start — the whole point of `PendingUpload`.
    ///
    /// Asks the address how much it kept and sends only what is missing. An upload interrupted at
    /// 90% costs the last 10%; one that had already arrived costs a single finalize. Returns the
    /// download URL, which the caller hangs on the message.
    func finish(_ job: PendingUpload) async throws -> String {
        guard let user = Auth.auth().currentUser else { throw BackgroundUploadError.notSignedIn }
        let token = try await user.getIDToken()
        let file = URL(fileURLWithPath: job.filePath)
        let size = fileSize(file)
        let received = try await receivedOffset(job.uploadURL, token: token)
        let reply = try await send(file: file, from: min(received, size), to: job.uploadURL,
                                   size: size, token: token, progressId: nil)
        return try downloadURL(bucket: job.bucket, path: job.storagePath, reply: reply)
    }

    // MARK: - The three commands

    private func startSession(bucket: String, path: String, contentType: String,
                              size: Int64, token: String) async throws -> URL {
        var comps = URLComponents(string: "https://firebasestorage.googleapis.com/v0/b/\(bucket)/o")!
        comps.queryItems = [URLQueryItem(name: "uploadType", value: "resumable"),
                            URLQueryItem(name: "name", value: path)]
        var r = URLRequest(url: comps.url!)
        r.httpMethod = "POST"
        r.setValue("Firebase \(token)", forHTTPHeaderField: "Authorization")
        r.setValue("resumable", forHTTPHeaderField: "X-Goog-Upload-Protocol")
        r.setValue("start", forHTTPHeaderField: "X-Goog-Upload-Command")
        r.setValue(contentType, forHTTPHeaderField: "X-Goog-Upload-Header-Content-Type")
        r.setValue(String(size), forHTTPHeaderField: "X-Goog-Upload-Header-Content-Length")
        r.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONSerialization.data(withJSONObject: ["name": path, "contentType": contentType])

        // The handshake is small and immediate, so it goes through the ordinary media session rather
        // than the background one — a background session cannot return a body to an awaiting caller
        // without a round trip through its delegate, and there is nothing to gain here.
        let (_, response) = try await MediaSession.shared.data(for: r)
        guard let http = response as? HTTPURLResponse else { throw BackgroundUploadError.noUploadURL }
        guard (200..<300).contains(http.statusCode) else { throw BackgroundUploadError.badStatus(http.statusCode) }
        guard let raw = http.value(forHTTPHeaderField: "X-Goog-Upload-URL") ?? http.value(forHTTPHeaderField: "x-goog-upload-url"),
              let url = URL(string: raw) else { throw BackgroundUploadError.noUploadURL }
        return url
    }

    /// How many bytes the server kept. Asked only after something went wrong.
    private func receivedOffset(_ uploadURL: URL, token: String) async throws -> Int64 {
        var r = URLRequest(url: uploadURL)
        r.httpMethod = "POST"
        r.setValue("Firebase \(token)", forHTTPHeaderField: "Authorization")
        r.setValue("query", forHTTPHeaderField: "X-Goog-Upload-Command")
        let (_, response) = try await MediaSession.shared.data(for: r)
        guard let http = response as? HTTPURLResponse else { return 0 }
        let value = http.value(forHTTPHeaderField: "X-Goog-Upload-Size-Received")
            ?? http.value(forHTTPHeaderField: "x-goog-upload-size-received")
        return Int64(value ?? "0") ?? 0
    }

    /// The bytes themselves, handed to iOS. `from` is where to start: 0 the first time, and whatever
    /// the server kept on a resume.
    private func send(file: URL, from offset: Int64, to uploadURL: URL, size: Int64,
                      token: String, progressId: String?) async throws -> Data {
        // A background upload task takes a FILE, never a Data — that is what lets the system carry it
        // out of process. So a resume writes the remaining bytes to their own file first.
        let body: URL
        let temporary: Bool
        if offset > 0 {
            body = try sliceFile(file, from: offset)
            temporary = true
        } else {
            body = file
            temporary = false
        }
        defer { if temporary { try? FileManager.default.removeItem(at: body) } }

        var r = URLRequest(url: uploadURL)
        r.httpMethod = "POST"
        r.setValue("Firebase \(token)", forHTTPHeaderField: "Authorization")
        r.setValue("upload, finalize", forHTTPHeaderField: "X-Goog-Upload-Command")
        r.setValue(String(offset), forHTTPHeaderField: "X-Goog-Upload-Offset")

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
                let task = session.uploadTask(with: r, fromFile: body)
                task.taskDescription = uploadURL.absoluteString
                lock.withLock {
                    waiters[task.taskIdentifier] = Waiter(continuation: cont, progressId: progressId,
                                                          base: offset, total: max(size, 1))
                }
                task.resume()
            }
        } onCancel: {
            // Deliberately does NOT cancel the transfer. A cancelled await means this screen stopped
            // caring; the bytes already sent are still worth keeping, and `adopt()` clears anything
            // genuinely orphaned at the next launch.
        }
    }

    // MARK: - Helpers

    private func fileSize(_ url: URL) -> Int64 {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let bytes = attrs[.size] as? NSNumber else { return 0 }
        return bytes.int64Value
    }

    /// The tail of a file, from `offset`, written to its own temporary file. Streamed in 1 MB reads
    /// rather than loaded whole: this runs on a resume, which is exactly when the phone is already
    /// carrying a large video in memory.
    private func sliceFile(_ url: URL, from offset: Int64) throws -> URL {
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("resume-\(UUID().uuidString).part")
        FileManager.default.createFile(atPath: out.path, contents: nil)
        let reader = try FileHandle(forReadingFrom: url)
        let writer = try FileHandle(forWritingTo: out)
        defer { try? reader.close(); try? writer.close() }
        try reader.seek(toOffset: UInt64(offset))
        while let chunk = try reader.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            try writer.write(contentsOf: chunk)
        }
        return out
    }

    /// Same shape `StorageReference.downloadURL()` returns, so every reader of these URLs — the
    /// bubbles, the caches, `MediaSession` — is unchanged.
    private func downloadURL(bucket: String, path: String, reply: Data) throws -> String {
        let object = (try? JSONSerialization.jsonObject(with: reply)) as? [String: Any]
        guard let tokens = object?["downloadTokens"] as? String,
              let first = tokens.split(separator: ",").first else {
            throw BackgroundUploadError.noDownloadToken
        }
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let encoded = path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path
        return "https://firebasestorage.googleapis.com/v0/b/\(bucket)/o/\(encoded)?alt=media&token=\(first)"
    }
}

// MARK: - The system reporting back

extension BackgroundUploader: URLSessionDataDelegate {
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.withLock { bodies[dataTask.taskIdentifier, default: Data()].append(data) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didSendBodyData bytesSent: Int64, totalBytesSent: Int64,
                    totalBytesExpectedToSend total: Int64) {
        let waiter = lock.withLock { waiters[task.taskIdentifier] }
        guard let waiter, let id = waiter.progressId else { return }
        // Measured against the WHOLE file, including whatever a previous attempt already delivered.
        let fraction = min(1, Double(waiter.base + totalBytesSent) / Double(waiter.total))
        Task { @MainActor in UploadProgress.shared.report(id, fraction) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let id = task.taskIdentifier
        let (waiter, body) = lock.withLock { (waiters.removeValue(forKey: id), bodies.removeValue(forKey: id)) }
        guard let waiter else { return }   // orphan from a previous launch — see `adopt()`
        if let error {
            waiter.continuation.resume(throwing: error)
            return
        }
        let code = (task.response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            waiter.continuation.resume(throwing: BackgroundUploadError.badStatus(code))
            return
        }
        waiter.continuation.resume(returning: body ?? Data())
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        // iOS woke the app only to hear this. Hand the handler back on the main queue or the app is
        // killed by the watchdog.
        DispatchQueue.main.async {
            let done = self.systemCompletionHandler
            self.systemCompletionHandler = nil
            done?()
        }
    }
}
