import Foundation

/// ⛔ AN UPLOAD THAT OUTLIVES THE PROCESS THAT STARTED IT (his order, 2026-08-25, after "fix it,
/// every corner, even bad network").
///
/// `BackgroundUploader` already hands the bytes to iOS, so leaving the app no longer stops the
/// transfer. But the code that would hang the finished URL on the message lived in the app, and if
/// the app was KILLED — swiped away, jetsammed, out of battery — that code died with it. The system
/// finished carrying a video nobody would ever be told about, and the message went red.
///
/// This is the missing half: the upload's address, written down where a launch can find it. Three
/// facts are enough to finish the job later:
///
///   · the private upload URL, which is what the server remembers the transfer by,
///   · the staged ciphertext on disk, so the remaining bytes can still be sent,
///   · and which message field the finished URL belongs in.
///
/// On the next launch `ChatService.resumePendingUploads` asks each address how much it kept, sends
/// whatever is missing, and attaches the result. An upload interrupted at 90% costs the last 10%
/// instead of the whole file.
///
/// ⚠️ ALBUMS ARE NOT IN THIS. Their items land in an `album` ARRAY, at an index, so finishing one
/// later is a different write and a different race with the other nine. They keep the existing
/// behaviour: the message fails and `autoRetryFailedMedia` re-drives the whole batch.
struct PendingUpload: Codable, Equatable {
    let id: String
    let uploadURL: URL
    let bucket: String
    let storagePath: String
    /// The staged ciphertext. ⚠️ It lives in the temporary directory, which iOS may purge — a job
    /// whose file is gone is dropped rather than mourned, and the message takes the normal failed
    /// and retry path it would have taken anyway.
    let filePath: String
    let cid: String
    let messageId: String
    /// `imageUrl`, `videoUrl`, `audioUrl` or `fileUrl`.
    let urlField: String
    /// Written alongside the URL when the field carries its own seal — a video's clip is sealed
    /// separately from its poster, so `enc` cannot be in the first message write.
    let enc: EncMeta?
    let startedAt: Date
}

/// One JSON file in Application Support. Small, rarely written, and read once at launch.
enum PendingUploadStore {
    private static let lock = NSLock()

    private static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("pending-uploads.json")
    }

    static func all() -> [PendingUpload] {
        lock.withLock {
            guard let data = try? Data(contentsOf: url) else { return [] }
            return (try? JSONDecoder().decode([PendingUpload].self, from: data)) ?? []
        }
    }

    static func add(_ job: PendingUpload) {
        lock.withLock {
            var jobs = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([PendingUpload].self, from: $0) } ?? []
            jobs.removeAll { $0.id == job.id }
            jobs.append(job)
            write(jobs)
        }
    }

    static func remove(_ id: String) {
        lock.withLock {
            var jobs = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([PendingUpload].self, from: $0) } ?? []
            jobs.removeAll { $0.id == id }
            write(jobs)
        }
    }

    /// ⚠️ CALLED WITH THE LOCK ALREADY HELD. NSLock is not recursive, so this must never take it.
    private static func write(_ jobs: [PendingUpload]) {
        guard let data = try? JSONEncoder().encode(jobs) else { return }
        // Complete-until-first-unlock, matching the staged ciphertext it points at: a resume can run
        // in the background after a reboot only once the phone has been unlocked once anyway.
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
