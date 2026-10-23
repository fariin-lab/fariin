import Foundation
import UIKit
import ImageIO       // stripping metadata from an image UIKit could not decode
import PDFKit
import FirebaseAuth
import FirebaseFirestore
import FirebaseStorage
import FirebaseFunctions
import CryptoKit     // MD5 only, to recognise our own upload after a lost reply (not for security)

/// Write-side operations (port of the RN Db writes). All E2EE goes through Crypto.
enum ChatService {
    static var db: Firestore { FirestoreHub.db }
    // Falls back to AuthService.shared.uid so this is NEVER empty when signed in (incl. the
    // Firebase-free demo, where currentUser is nil but AuthService holds "demo-me"). An empty uid
    // built dotted field paths like "unreadCount." — an INVALID Firestore path that raises an ObjC
    // NSException (which `try?` can't catch) → crash on chat open.
    static var uid: String { Auth.auth().currentUser?.uid ?? AuthService.shared.uid ?? "" }

    static func convId(_ a: String, _ b: String) -> String {
        [a, b].sorted().joined(separator: "_")
    }

    // MARK: - Username (handle) policy: letters a-z in EITHER case, 0-9, underscore.
    // Owner, 2026-10-07: "REALWARYA or Realwarya … big letters or small or both". The large
    // messengers' rule: the name SHOWS as typed, but it is ONE name whatever the case, so
    // "Realwarya" and "realwarya" can never belong to two people (uniqueness, lookups and links all
    // go through the lowercase form: `usernames/{lower}`, `handleLower`, `findByHandle`).
    static let handleAllowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_")
    /// Strip anything not allowed as the user types (no spaces, dashes, emojis…). Case is kept.
    static func sanitizeHandle(_ raw: String) -> String {
        String(raw.filter { handleAllowed.contains($0) }.prefix(Limits.usernameMaxChars))
    }
    /// What the SERVER will say no to, checked here so the app does not ask about a name that cannot
    /// work. Mirrors `invalidReason` in the backend deliberately — the server is the one that counts,
    /// this one exists so typing feels instant and we do not spend a round trip to be told the
    /// obvious. Returns nil when the shape is fine.
    static func handleShapeProblem(_ h: String) -> String? {
        if h.count < Limits.usernameMinChars { return nil }   // still typing — say nothing yet
        if h.count > Limits.usernameMaxChars { return "Usernames are at most \(Limits.usernameMaxChars) characters." }
        if h.hasPrefix("_") || h.hasSuffix("_") { return "Usernames can't start or end with _." }
        if h.contains("__") { return "Usernames can't contain two _ in a row." }
        // AT LEAST ONE LETTER, matching the server. Not the same as "not only digits": `123_456` has
        // no letter yet is not all digits, and it reads like an account or phone number.
        if !h.contains(where: \.isLetter) { return "Usernames need at least one letter." }
        return nil
    }

    /// Ask the server whether a name is free FOR ME. Never trusted for the claim — see `claimHandle`.
    static func checkHandleAvailable(_ h: String) async throws -> (available: Bool, reason: String?) {
        let res = try await Functions.functions(region: "me-central1")
            .httpsCallable("checkUsername").call(["username": h])
        let d = res.data as? [String: Any] ?? [:]
        return (d["available"] as? Bool ?? false, d["reason"] as? String)
    }

    /// TAKE it. One transaction on the server decides, so two people pressing Done on the same name
    /// at the same instant cannot both win. Throws with the server's own words on failure.
    static func claimHandle(_ h: String) async throws {
        _ = try await Functions.functions(region: "me-central1")
            .httpsCallable("claimUsername").call(["username": h])
    }

    static func isValidHandle(_ h: String) -> Bool {
        if h.lowercased() == ownerShortHandle { return true }   // @v, the admin's own name (server-enforced)
        return h.count >= Limits.usernameMinChars && h.count <= Limits.usernameMaxChars && h.allSatisfy { handleAllowed.contains($0) }
    }
    /// The admin account's one-letter username (owner, 2026-10-07). Only the account that holds or
    /// held @realwarya may claim it: the SERVER decides (`claimUsername`, OWNER_NAMES). Here it is
    /// only let through the length checks so it can be looked up, linked and typed.
    static let ownerShortHandle = "v"
    /// Me: the admin account, under either of its names.
    static var iAmOwnerAccount: Bool {
        let h = (ProfileStore.shared.me?.handle ?? "").lowercased()
        return h == "realwarya" || h == ownerShortHandle
    }

    /// Create (or touch) a 1:1 conversation. Only writes photo keys we actually have,
    /// so re-opening never wipes an existing photo (parity with the RN fix).
    @discardableResult
    static func openConversation(other: UserProfile) async throws -> String {
        let cid = convId(uid, other.id)
        let me = await ProfileStore.shared.fetch(uid)
        var photos: [String: String] = [:]
        if let p = me?.photoUrl, !p.isEmpty { photos[uid] = p }
        if let p = other.photoUrl, !p.isEmpty { photos[other.id] = p }

        // SEED unreadCount/typing ONLY ON CREATION. A merge write of a MAP field writes every key in
        // it, so doing this on every open zeroed `unreadCount.<other>` — wiping the other person's
        // badge for messages they never read — and forced their typing flag to false. Every entry
        // point calls this unconditionally (New Chat, @search, a kulan:// link, a contact tap), so
        // it fired constantly (audit). Names/photos still refresh on every open, as before.
        let ref = db.collection("conversations").document(cid)
        // "DOES NOT EXIST" AND "I COULD NOT FIND OUT" ARE DIFFERENT ANSWERS, and this line used to
        // collapse them into one. A failed read became `exists = false`, which on a fresh install
        // with no cache and no network is exactly what happens for a chat that exists perfectly well
        // on the server — and the seed below would then have stamped a running conversation as a
        // brand-new request. The rules refuse the worst of it, but the app should not be asking.
        let snapshot = try? await ref.getDocument()
        let exists = snapshot?.exists ?? false
        let answered = snapshot != nil
        var seed: [String: Any] = [
            "users": [uid, other.id],
            "names": [uid: me?.name ?? "Me", other.id: other.name.isEmpty ? other.handle : other.name],
            "photos": photos,
            "updatedAt": FieldValue.serverTimestamp(),
        ]
        if !exists {
            seed["unreadCount"] = [uid: 0, other.id: 0]
            seed["typing"] = [uid: false, other.id: false]
            // A brand-new 1:1 is a REQUEST until the other person answers. Stamped once, here, on
            // the only write that can create the document — so the two fields can never be added
            // later to a conversation that was already running. See [MessageRequests].
            //
            // ONLY WHEN THE READ ACTUALLY ANSWERED. If it did not, we do not know this is new, and
            // guessing wrong turns somebody's real chat into a pending request. Creating a genuinely
            // new chat while offline is then refused by the rules, which is the safe way to be wrong.
            // owner 2026-10-21: kept on mere open, on purpose. The create rule refuses a new 1:1
            // without it, so it says "who tapped first", not "who spoke"; `MessageRequests.rawStance`
            // reads a chat with no message yet as nobody's request (either side may knock).
            if answered {
                seed["startedBy"] = uid
                seed["accepted"] = false
                // The Settings default timer, born with the chat (see `applyDefaultDisappear`). In
                // the creating write, not a follow-up: a new 1:1 is a request, and the notice a
                // follow-up would post is refused on a request (it is not plain text).
                let def = UserDefaults.standard.integer(forKey: "defaultDisappearSeconds")
                if def > 0 { seed["disappearSeconds"] = def }
            }
        }
        // ⛔ AND WHEN THE STAMP IS WHAT THE RULES REFUSED, WRITE THE REST — audit C2, 2026-09-11.
        //
        // The pre-read can answer "not there" for a conversation that very much is: a stale cache,
        // or the split second after `verifyChatPin` created it on the server. The seed then carries
        // `accepted: false`, the rules refuse to walk an accepted chat back to a request (correctly),
        // and the WHOLE write is lost — including the names and photos every chat list draws from,
        // which had nothing to do with the stamp and which nothing else on this path rewrites.
        //
        // So a refusal is retried once without the two request fields. If that also fails, the
        // throw is the caller's as before; every call site wraps this in `try?` already.
        do {
            try await ref.setData(seed, merge: true)
        } catch {
            // 2026-09-24 fix-all: the creation seeds go too. The rules now refuse lowering another
            // member's badge, and a seed written over a chat that already exists sets their
            // `unreadCount` back to 0, so on this path it would refuse the retry as well.
            guard seed["unreadCount"] != nil else { throw error }
            seed.removeValue(forKey: "startedBy")
            seed.removeValue(forKey: "accepted")
            seed.removeValue(forKey: "unreadCount")
            seed.removeValue(forKey: "typing")
            seed.removeValue(forKey: "disappearSeconds")   // the chat existed: its timer is its own
            try await ref.setData(seed, merge: true)
        }
        // 2026-09-26 block rebuild: a block is NOT copied onto the chat any more (the person blocked
        // is a member and could read it). The thread and every list ask `BlockList` directly.
        return cid
    }

    /// ⛔ THE SETTINGS DEFAULT TIMER, ON EVERY CHAT I START — owner, 2026-09-26: "disappearing
    /// messages in Settings is not working". It was applied in one place, the FIRST TEXT's own
    /// conversation seed, and only when that send found no chat. But starting a chat goes through
    /// `openConversation`, which creates the chat before anything is sent, so by the first message
    /// the chat existed and the default was never written. Now applied when a chat is CREATED
    /// (1:1 in `openConversation`, groups in `createGroup`). A group goes through `setDisappear`, so the members get the same
    /// "set disappearing message time" notice as for any timer change — never silent. A new 1:1
    /// takes it in its creating write instead (see `openConversation`): it is born a request, and
    /// a request refuses the notice.
    static func applyDefaultDisappear(_ cid: String) async {
        let def = UserDefaults.standard.integer(forKey: "defaultDisappearSeconds")
        guard def > 0 else { return }
        await setDisappear(cid, seconds: def)
    }

    /// `openConversation` for a place that holds only the other person's uid (a group member, a
    /// shared contact card). 2026-09-24 audit: those places set `pendingChatId` and nothing else,
    /// so the chat document did not exist and the first send created it without `startedBy` /
    /// `accepted`, which the create rule refuses: the first message to a group member you had
    /// never messaged failed on every retry.
    static func openConversation(uid other: String) async {
        guard let p = await ProfileStore.shared.fetch(other) else { return }
        _ = try? await openConversation(other: p)
    }

    /// Create a GROUP conversation: random doc id, N members, creator is the sole admin.
    /// Returns the new conversation id.
    @discardableResult
    /// ⛔ FAST, THE REFERENCE APP'S WAY (owner 2026-10-18, build 969: "create takes many seconds").
    /// The chat opens on the LOCAL write: Firestore applies it on this phone at once and sends it in
    /// order, so the member names are read side by side and the group is returned without waiting for
    /// the server's answer. The greeting, the timer and the photo follow in the background, in that
    /// order, behind it. `disappearSeconds`: the creator's choice (0 = off), written in the same
    /// record, so there is no second write or second notice for it.
    static func createGroup(title: String, memberIds: [String], avatarUrl: String? = nil,
                            disappearSeconds: Int = 0,
                            permissions: [String: Bool] = [:]) async throws -> String {
        var memberSet = Set(memberIds); memberSet.insert(uid)
        let users = Array(memberSet)

        var names: [String: String] = [:]
        var photos: [String: String] = [:]
        await withTaskGroup(of: (String, UserProfile?).self) { g in
            for u in users { g.addTask { (u, await ProfileStore.shared.fetch(u)) } }
            for await (u, p) in g {
                guard let p else { continue }
                names[u] = p.name.isEmpty ? p.handle : p.name
                if let ph = p.photoUrl, !ph.isEmpty { photos[u] = ph }
            }
        }
        var unread: [String: Int] = [:]
        var typing: [String: Bool] = [:]
        for u in users { unread[u] = 0; typing[u] = false }

        let ref = db.collection("conversations").document()
        var data: [String: Any] = [
            "type": "group",
            // The same 100 the rename keeps to, and no name made of line breaks (audit 2026-10-20).
            "title": String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100)),
            "users": users,
            "admins": [uid],
            "createdBy": uid,
            "createdAt": FieldValue.serverTimestamp(),
            "names": names,
            "photos": photos,
            "unreadCount": unread,
            "typing": typing,
            "updatedAt": FieldValue.serverTimestamp(),
        ]
        if let avatarUrl, !avatarUrl.isEmpty { data["avatarUrl"] = avatarUrl }
        // The member switches picked on the New Group page, in the group from its first write.
        for (k, v) in permissions where k != "e2ee" { data[k] = v }
        // 2026-10-19 groups v2 (owner): a new group is not end-to-end encrypted from its first write
        // (the rules take `false` and nothing else here). Known locally at once, so the first message,
        // sent before the server has answered, goes in the clear too (groupIsPlain).
        data["e2ee"] = false
        sealMembersLock.withLock { _ = plainGroups.insert(ref.documentID) }
        // Not awaited: the write is on this phone now and the listener sees it; the server's answer
        // comes behind (a refusal is logged; the chat then simply does not stay).
        // Refused: said, not only logged (audit 2026-10-20: the chat opened and then went away).
        ref.setData(data) { err in
            guard let err else { return }
            print("[createGroup] write refused: \(err.localizedDescription)")
            Task { @MainActor in ToastNotice.show("Could not create the group. Try again.") }
        }
        let cid = ref.documentID
        Task.detached(priority: .userInitiated) {
            // Greet the new group with a system event (also gives the chat list a real preview).
            try? await writeSystemMessage(cid: cid, text: "\(myName()) created the group")
            if disappearSeconds > 0 { await setDisappear(cid, seconds: disappearSeconds) }
        }
        return cid
    }

    // MARK: - Media upload (the one path everything encrypted goes through)

    /// Upload encrypted bytes to `path` and return the download URL.
    ///
    /// **`putFile`, not `putData`**, for three reasons that all bite hardest on a weak connection:
    /// the bytes stop sitting in RAM (a 100MB video was held as plaintext AND as a second encrypted
    /// copy at the same time), GTMSessionUploadFetcher persists FILE-backed uploads so it can
    /// restore one after the app is reopened, and the upload becomes a real task rather than a
    /// handle we throw away.
    ///
    /// **It does NOT resume from a byte offset, and cannot.** Firebase's iOS SDK sets the upload
    /// chunk size to `LLONG_MAX`, so nothing is ever chunked and there is no offset to resume from
    /// (firebase-ios-sdk issue 10137). A dropped upload starts over. What this adds is that it
    /// starts over BY ITSELF with jittered backoff instead of failing the send, and keeps going for
    /// the grace period iOS grants after the user leaves the app.
    /// `progressId` is the optimistic bubble's clientId. Pass it and the bubble shows a ring that
    /// FILLS instead of a spinner that only says "busy".
    static func uploadEncrypted(_ bytes: Data, to path: String,
                                contentType: String = "application/octet-stream",
                                progressId: String? = nil,
                                attach: BackgroundUploader.Attach? = nil,
                                trace: UploadTrace? = nil) async throws -> String {
        let ref = Storage.storage().reference().child(path)
        let meta = StorageMetadata(); meta.contentType = contentType

        let bg = await beginUploadAssertion()
        defer {
            Task { @MainActor in
                endUploadAssertion(bg)
                if let progressId { UploadProgress.shared.finish(progressId) }
            }
        }

        return try await withStagedFile(bytes) { tmp in
            var attempt = 0
            while true {
                do {
                    // A RETRY RESTARTS FROM ZERO, and the ring has to say so. Firebase's iOS SDK sets
                    // the chunk size to LLONG_MAX, so nothing is ever chunked and a dropped upload
                    // starts over — a ring left at 80% while the bytes go again would be a lie.
                    if let progressId, attempt > 0 { await UploadProgress.shared.reset(progressId) }
                    trace?.set { $0.attempts = attempt + 1 }
                    // THE SWITCH, AND IT SHIPS OFF. `BackgroundUploader` hands the file to iOS, so
                    // the transfer survives leaving the app and a broken connection resumes from
                    // where it stopped instead of from zero — the two things this loop cannot fix by
                    // trying harder. It is new code on the path every photo, video, voice note and
                    // document takes, and it could not be compiled or run where it was written, so
                    // it is opt-in until a real phone has proved it. Settings → Storage and Data.
                    if UploadEngine.backgroundEnabled {
                        let url = try await BackgroundUploader.shared.upload(file: tmp, to: path,
                                                                             contentType: contentType,
                                                                             progressId: progressId,
                                                                             attach: attach)
                        trace?.set { $0.url = Date() }
                        return url
                    }
                    let token = try await putFileReportingProgress(ref, from: tmp, metadata: meta,
                                                                   progressId: progressId, trace: trace)
                    // ⛔ NO SECOND ROUND TRIP FOR THE ADDRESS (owner, 2026-10-17). The put's own reply
                    // already carries the download token, so the URL is built here exactly the way
                    // `BackgroundUploader` builds it. `downloadURL()` is only the fallback for a reply
                    // that came back without a token.
                    let url: String
                    if let token, !token.isEmpty {
                        url = BackgroundUploader.tokenURL(bucket: ref.bucket, path: ref.fullPath,
                                                          token: token)
                    } else {
                        url = try await ref.downloadURL().absoluteString
                    }
                    trace?.set { $0.url = Date() }
                    return url
                } catch {
                    // ⛔ OUR OWN EARLIER ATTEMPT MAY HAVE LANDED. A put that reached the server but
                    // lost its reply leaves the object in place, and the create-only rule then
                    // refuses the retry as if a stranger owned the path: a red bubble for a clip
                    // that was delivered, and an orphan object nobody points at. On a refusal, ask
                    // what is there; if it is byte-for-byte ours (same MD5), that is our upload.
                    if !isRetryableUpload(error), !Task.isCancelled,
                       let url = await alreadyUploaded(ref, bytes: bytes) {
                        return url
                    }
                    attempt += 1
                    // ⛔ SIX, NOT FOUR, AND A MINUTE OF PATIENCE (owner, 2026-08-25: "every corner,
                    // even bad network"). Four tries over about half a minute is tuned for a
                    // connection that hiccups. On a phone that loses signal for a minute at a time it
                    // simply runs out of attempts and hands back a red bubble, and the person is then
                    // waiting on a finger. Six tries reach roughly two minutes, which covers a lift,
                    // a tunnel or a cell handover — and `autoRetryFailedMedia` picks up whatever is
                    // still failing after that, the moment the signal is genuinely back.
                    guard attempt < 6, !Task.isCancelled, isRetryableUpload(error) else {
                        if !Task.isCancelled { Telemetry.event(.error, component: "media", code: "upload_" + Telemetry.code(error), detail: ["attempt": String(attempt)]) }   // owner 2026-10-21
                        throw error
                    }
                    await Backoff.sleep(attempt: attempt, base: 2, cap: 60)
                }
            }
        }
    }

    /// Timestamps for the hidden PHOTO# diagnostic line (owner, 2026-10-17): where a slow photo
    /// send spends its time. Times only, never content or keys.
    final class UploadTrace: @unchecked Sendable {
        struct Marks { var bytes100: Date?; var putOK: Date?; var url: Date?; var attempts = 0 }
        private let lock = NSLock()
        private var marks = Marks()
        func set(_ change: (inout Marks) -> Void) { lock.lock(); change(&marks); lock.unlock() }
        var snapshot: Marks { lock.lock(); defer { lock.unlock() }; return marks }
    }

    /// `putFileAsync` is the reason the bubble could only ever show a spinner: the async wrapper
    /// throws the task away, and the task is the only thing that reports bytes. The observable form
    /// gives the same result and hands back progress on the way.
    private static func putFileReportingProgress(_ ref: StorageReference, from tmp: URL,
                                                 metadata: StorageMetadata,
                                                 progressId: String?,
                                                 trace: UploadTrace? = nil) async throws -> String? {
        let task = ref.putFile(from: tmp, metadata: metadata)
        // ⛔ A STALLED TRANSFER IS RESTARTED, NOT WAITED OUT — owner, 2026-10-10 ("the image upload
        // never ends", ring frozen part-way; the reference app restarts a stuck part in seconds). The SDK
        // retries a stalled transfer silently for `maxUploadRetryTime` (120 s) per attempt, and the
        // caller's loop then started again up to six times: many minutes of a frozen ring. Now no new
        // bytes for `stallLimit` ends this attempt with a timeout (retryable), the task is cancelled,
        // and the caller's loop starts a fresh transfer about two seconds later.
        final class Box: @unchecked Sendable {
            let lock = NSLock(); var done = false; var lastBytes: Int64 = -1; var lastMove = Date()
            var allSent = false
        }
        let box = Box()
        let stallLimit: TimeInterval = 20
        // ⛔ ALL BYTES SENT IS NOT A STALL (owner, 2026-10-17). Once 100% has gone, no new bytes is
        // the normal wait for the server to finish and reply; cutting it at 20 s threw away a
        // finished upload and sent the whole photo again. That phase gets its own, longer limit.
        let finishingLimit: TimeInterval = 60
        // Exactly one resume: success, failure and the stall check race, and only the first one
        // counts (`box.done`). Observers are torn down so a retry's task cannot report into it.
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String?, Error>) in
                let finish: (Result<String?, Error>) -> Void = { result in
                    box.lock.lock()
                    if box.done { box.lock.unlock(); return }
                    box.done = true
                    box.lock.unlock()
                    task.removeAllObservers()
                    cont.resume(with: result)
                }
                task.observe(.progress) { snap in
                    guard let p = snap.progress else { return }
                    box.lock.lock()
                    if p.completedUnitCount != box.lastBytes { box.lastBytes = p.completedUnitCount; box.lastMove = Date() }
                    let firstFull = !box.allSent && p.totalUnitCount > 0 && p.completedUnitCount >= p.totalUnitCount
                    if firstFull { box.allSent = true }
                    box.lock.unlock()
                    if firstFull { trace?.set { $0.bytes100 = Date() } }
                    guard let progressId, p.totalUnitCount > 0 else { return }
                    let fraction = Double(p.completedUnitCount) / Double(p.totalUnitCount)
                    Task { @MainActor in UploadProgress.shared.report(progressId, fraction) }
                }
                task.observe(.success) { snap in
                    trace?.set { $0.putOK = Date() }
                    // The download token from the put's own reply (first of a comma list), so the
                    // caller can skip `downloadURL()`. nil when the reply has none.
                    let tokens = snap.metadata?.dictionaryRepresentation()["downloadTokens"] as? String
                    finish(.success(tokens?.split(separator: ",").first.map(String.init)))
                }
                task.observe(.failure) { snap in
                    finish(.failure(snap.error ?? NSError(domain: StorageErrorDomain, code: -1)))
                }
                Task.detached {
                    while true {
                        try? await Task.sleep(nanoseconds: 5_000_000_000)
                        box.lock.lock()
                        let done = box.done, idle = Date().timeIntervalSince(box.lastMove)
                        let limit = box.allSent ? finishingLimit : stallLimit
                        box.lock.unlock()
                        if done { return }
                        if idle >= limit {
                            print("[Upload] no progress for \(Int(idle)) s, restarting the transfer")
                            finish(.failure(URLError(.timedOut)))   // retryable: a fresh attempt follows
                            task.cancel()
                            return
                        }
                    }
                }
            }
        } onCancel: {
            task.cancel()
        }
    }

    /// Runs `body` with `bytes` staged to a protected temp file, and removes that file afterwards on
    /// EVERY exit path: success, throw, or cancellation. A leaked temp file is a sealed copy of a
    /// private message left sitting in tmp.
    ///
    /// Split out from the Storage call on purpose. The cleanup guarantee is the part worth testing,
    /// and inline it could only be tested by actually uploading something.
    static func withStagedFile<T>(_ bytes: Data, _ body: (URL) async throws -> T) async throws -> T {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("upload-\(UUID().uuidString).enc")
        try bytes.write(to: tmp, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        defer { try? FileManager.default.removeItem(at: tmp) }
        return try await body(tmp)
    }

    /// ⛔ FINISH WHAT A DEAD PROCESS STARTED. Called once at launch.
    ///
    /// `BackgroundUploader` keeps the transfer alive when the app is merely backgrounded; this is
    /// for when the app was KILLED. Each job carries the private upload address, the staged
    /// ciphertext, and which field on which message the finished URL belongs in. Ask what landed,
    /// send the rest, attach it.
    ///
    /// Silent by design: a job that cannot be finished is LEFT for the next launch rather than
    /// deleted, unless its staged file is gone, in which case there is nothing left to send and the
    /// message takes the ordinary failed-and-retry path it would have taken anyway.
    static func resumePendingUploads() async {
        for job in PendingUploadStore.all() {
            guard FileManager.default.fileExists(atPath: job.filePath) else {
                PendingUploadStore.remove(job.id)
                continue
            }
            do {
                let url = try await BackgroundUploader.shared.finish(job)
                var fields: [String: Any] = [job.urlField: url]
                if let enc = job.enc { fields["enc"] = enc.asDict }
                let msgRef = db.collection("conversations").document(job.cid)
                    .collection("messages").document(job.messageId)
                try await attachMedia(fields, to: msgRef)
                PendingUploadStore.remove(job.id)
                try? FileManager.default.removeItem(atPath: job.filePath)
            } catch {
                // 2026-09-24 audit: a job whose message was deleted meanwhile was kept "for the next
                // launch", so it uploaded again and failed again on EVERY launch, forever. The attach
                // write fails as not-found (5) or, through the rules reading a missing doc, as
                // permission-denied (7); either way ask the server whether the message is still
                // there, and drop the job only on a definite "no". Offline stays queued as before.
                let ns = error as NSError
                if ns.domain == FirestoreErrorDomain, ns.code == 5 || ns.code == 7,
                   let snap = try? await db.collection("conversations").document(job.cid)
                       .collection("messages").document(job.messageId).getDocument(source: .server),
                   !snap.exists {
                    PendingUploadStore.remove(job.id)
                    try? FileManager.default.removeItem(atPath: job.filePath)
                    continue
                }
                print("resumePendingUploads: \(job.storagePath) not finished yet:", error)
            }
        }
    }

    /// A refusal is not a network problem. Retrying an unauthorized or over-quota upload only burns
    /// the user's data and delays the error they actually need to see, so those fail immediately.
    /// Anything we cannot identify is treated as transport and retried.
    private static func isRetryableUpload(_ error: Error) -> Bool {
        // The background engine talks to the REST endpoint and reports a rules refusal as a plain
        // HTTP status, which fell through to "transport" below: the same create-only denial the SDK
        // path fails on at once spent all six attempts and about two minutes here.
        if case BackgroundUploadError.badStatus(let code)? = error as? BackgroundUploadError {
            return !(code == 401 || code == 403)
        }
        let ns = error as NSError
        guard ns.domain == StorageErrorDomain else { return true }
        switch StorageErrorCode(rawValue: ns.code) {
        case .unauthorized, .unauthenticated, .quotaExceeded, .cancelled, .objectNotFound: return false
        default: return true
        }
    }

    /// The download address of the object at `ref` IF it is exactly `bytes` (Storage's MD5 of the
    /// stored object against ours), else nil. Every chat object is fresh ciphertext under a new
    /// message id, so a match means our own earlier attempt, never somebody else's file.
    private static func alreadyUploaded(_ ref: StorageReference, bytes: Data) async -> String? {
        guard let meta = try? await ref.getMetadata(), let stored = meta.md5Hash else { return nil }
        let ours = Data(Insecure.MD5.hash(data: bytes)).base64EncodedString()
        guard stored == ours else { return nil }
        return try? await ref.downloadURL().absoluteString
    }

    /// Holds the app awake for the short grace period iOS grants after the user leaves, so
    /// backgrounding mid-send does not kill the upload outright.
    @MainActor private static func beginUploadAssertion() -> UIBackgroundTaskIdentifier {
        var id: UIBackgroundTaskIdentifier = .invalid
        id = UIApplication.shared.beginBackgroundTask(withName: "fariin-media-upload") {
            // iOS is about to reclaim it; ending it ourselves avoids the watchdog kill.
            if id != .invalid { UIApplication.shared.endBackgroundTask(id); id = .invalid }
        }
        return id
    }

    @MainActor private static func endUploadAssertion(_ id: UIBackgroundTaskIdentifier) {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
    }

    /// Upload a group avatar (plain image, like profile photos). Stored under the existing
    /// `profiles/` Storage path (so no rule change) keyed by cid, then set as the conv avatarUrl.
    /// Admin-gated by the conversation update rule (avatarUrl isn't a non-admin field).
    @discardableResult
    static func uploadGroupAvatar(cid: String, data rawData: Data) async throws -> String {
        let data = ProfileStore.squareJPEG(rawData)
        let ref = Storage.storage().reference().child("profiles/group_\(cid).jpg")
        let meta = StorageMetadata(); meta.contentType = "image/jpeg"
        _ = try await ref.putDataAsync(data, metadata: meta)
        let url = try await ref.downloadURL().absoluteString
        try await db.collection("conversations").document(cid).updateData([
            "avatarUrl": url,
            "updatedAt": FieldValue.serverTimestamp(),
        ])
        return url
    }

    /// Remove the group's photo (owner 2026-10-20): the field goes and so does the file.
    static func removeGroupAvatar(cid: String) async throws {
        try await db.collection("conversations").document(cid).updateData([
            "avatarUrl": FieldValue.delete(),
            "updatedAt": FieldValue.serverTimestamp(),
        ])
        try? await Storage.storage().reference().child("profiles/group_\(cid).jpg").delete()
        try? await writeSystemMessage(cid: cid, text: "\(myName()) removed the group photo")
    }

    /// GROUP WALLPAPER — owner 2026-10-18: "only the owner or an admin can change it; when an admin
    /// changes it, everyone sees that wallpaper when they enter the group". The picture goes up as
    /// `profiles/group_<cid>-wp<millis>.jpg` (storage.rules `groupWallpaperEditor`, the same people
    /// the group photo allows). A NEW name per wallpaper, so the download link changes with it and
    /// every phone knows to fetch the new one (an overwrite keeps the old link and token).
    /// The JPEG is already downscaled by the caller (`WallpaperStore.sharedUploadJPEG`).
    static func uploadGroupWallpaper(cid: String, jpeg: Data) async throws -> String {
        let stamp = Int64(Date().timeIntervalSince1970 * 1000)
        let ref = Storage.storage().reference().child("profiles/group_\(cid)-wp\(stamp).jpg")
        let meta = StorageMetadata(); meta.contentType = "image/jpeg"
        _ = try await ref.putDataAsync(jpeg, metadata: meta)
        return try await ref.downloadURL().absoluteString
    }

    /// Write the group's shared wallpaper (`ChatWallpaper.stored`, or "u:<download link>" for a
    /// photo) plus one notice line, the way `renameGroup` does it. The rules let only the people
    /// who may change group info write it (firestore.rules `nonOwnerAdminWriteOK`, and the
    /// members-can-edit-info branch). The previous photo file is removed best-effort.
    static func setGroupWallpaper(cid: String, stored: String, previous: String?) async throws {
        let convRef = db.collection("conversations").document(cid)
        try await convRef.updateData(["wallpaper": stored, "updatedAt": FieldValue.serverTimestamp()])
        let text = stored == "none" ? "\(myName()) removed the group wallpaper"
                                    : "\(myName()) changed the group wallpaper"
        try? await writeSystemMessage(cid: cid, text: text)
        if let previous, previous.hasPrefix("u:"), previous != stored,
           let old = Storage.storage().safeReference(forURL: String(previous.dropFirst(2))) {
            try? await old.delete()
        }
    }

    // MARK: - Group management (each writes a system event message + updates the conv)

    /// Add members + a "X added Y" system message. New members can't read prior history
    /// (their per-message wraps don't exist) — honest and expected, like sender keys.
    /// Returns the display names of added members who have NO published key yet (they won't see
    /// messages until they open Fariin) so the UI can warn the adder honestly.
    @discardableResult
    static func addGroupMembers(cid: String, add: [String]) async throws -> [String] {
        let newOnes = add.filter { !$0.isEmpty }
        guard !newOnes.isEmpty else { return [] }
        forgetSealMembers(cid)   // 2026-09-24 fix-all #111: the next seal re-reads the member list
        let convRef = db.collection("conversations").document(cid)
        // The member cap on growth: config/limits.group_members_max (admin panel), fallback 30. The
        // rules hold the same number on every add; this check only gives a clear message first.
        let maxMembers = AppLimits.shared.groupMembersMax
        var currentCount = ConversationsRepository.shared.conversations.first(where: { $0.id == cid })?.users.count ?? 0
        if currentCount == 0 {
            currentCount = ((try? await convRef.getDocument())?.data()?["users"] as? [String])?.count ?? 0
        }
        if currentCount + newOnes.count > maxMembers {
            throw NSError(domain: "ChatService", code: 30,
                          userInfo: [NSLocalizedDescriptionKey: "A group can have at most \(maxMembers) members."])
        }
        var update: [String: Any] = [
            "users": FieldValue.arrayUnion(newOnes),
            "updatedAt": FieldValue.serverTimestamp(),
        ]
        // Re-adding a removed member lifts their ban — but ONLY when an ADMIN adds. A non-admin member
        // (membersCanAdd) writes through a field-whitelisted rule branch that forbids `bannedUids`, so
        // touching it would reject the whole add. Admins write through the any-field admin branch.
        // 2026-09-24 audit: the rules now hold an admin to their rights, and an admin without Add
        // members adds through the membersCanAdd branch, so the test is the right, not the badge.
        let iAmGroupAdmin = ConversationsRepository.shared.conversations.first(where: { $0.id == cid })?.adminCan(uid, .inviteUsers) ?? false
        if iAmGroupAdmin { update["bannedUids"] = FieldValue.arrayRemove(newOnes) }
        var addedNames: [String] = []
        var keyless: [String] = []
        for u in newOnes {
            if let p = await ProfileStore.shared.fetch(u) {
                let nm = p.name.isEmpty ? p.handle : p.name
                update["names.\(u)"] = nm
                addedNames.append(nm)
                if let ph = p.photoUrl, !ph.isEmpty { update["photos.\(u)"] = ph }
                // 2026-09-25 photo audit: the large photo too, so a new member's profile opens with
                // their poster instead of waiting for their next photo change. ADMIN ONLY: the
                // members-can-add rule does not list `posters`, and one refused field would refuse
                // the whole add. Everyone else's gap is closed by the member's own phone
                // (`ProfileStore.healMyMirrors`), which the own-entry rule allows.
                if iAmGroupAdmin, let pu = p.posterUrl, !pu.isEmpty { update["posters.\(u)"] = pu }
                if (p.publicKeyB64 ?? "").isEmpty { keyless.append(nm) }   // hasn't opened Fariin
            } else {
                addedNames.append("New member")   // fallback so the event isn't blank
                keyless.append("New member")
            }
            update["unreadCount.\(u)"] = 0
        }
        // 2026-09-24 fix-all: ONE BATCH, the fix `removeGroupMember` and `leaveGroup` already got. The
        // add and its "X added Y" notice were two awaited writes, so a kill or a dropped signal between
        // them left new members in the group with no notice ever shown. The notice's preview rides on
        // the same update (the membersCanAdd rule branch admits `lastMessage`/`lastSender` = me); the
        // message rule reads the conversation as it was before the batch, where I am already a member.
        // A member the message rule would refuse (announcement mode, or muted) still adds, without the
        // notice, exactly as before, instead of the refused notice taking the whole add down with it.
        let conv = ConversationsRepository.shared.conversations.first(where: { $0.id == cid })
        let canNotice = conv?.canSend(uid, now: Date().timeIntervalSince1970 * 1000) ?? true
        let batch = db.batch()
        if canNotice, !addedNames.isEmpty {
            let text = "\(myName()) added \(addedNames.joined(separator: ", "))"
            batch.setData(["text": text, "authorId": uid, "type": "system",
                           "createdAt": FieldValue.serverTimestamp()],
                          forDocument: convRef.collection("messages").document())
            update["lastMessage"] = text
            update["lastSender"] = uid
        }
        batch.updateData(update, forDocument: convRef)
        try await batch.commit()
        // Again once the add has landed: a send between the top of this function and the commit
        // would have cached the old list for its ten seconds, leaving the new members without wraps.
        forgetSealMembers(cid)
        return keyless
    }

    /// Remove a member (admin) + system message.
    ///
    /// ONE BATCH (2026-09-24 audit), the same fix `leaveGroup` got. It was two awaited writes, the
    /// "X removed Y" notice first, so a kill or a dropped signal between them left the notice in
    /// the chat while Y was still a member and not banned. The removal goes through the admin
    /// branch of the conversation rule (any field), so the notice's preview fields ride on the same
    /// update; the message rule reads the conversation as it was before the batch.
    static func removeGroupMember(cid: String, uid removed: String, name: String) async throws {
        forgetSealMembers(cid)   // 2026-09-24 fix-all #111: the next seal re-reads the member list
        let convRef = db.collection("conversations").document(cid)
        let text = "\(myName()) removed \(name)"
        // 2026-10-19: no notice when the message rule would refuse mine (admins-only sending and
        // I'm not one, muted, or the group suspended), the same `canNotice` addGroupMembers uses, so
        // a refused notice cannot take the removal down with it. The removed member's badge key goes
        // only with the notice: the rules let a group write touch another member's `unreadCount`
        // key only inside a send by me (`lastSender` = me).
        // The group's own doc when the list has no copy (audit 2026-10-20: a group below the
        // list's window read as "may notice", and in a suspended group the refused notice took
        // the whole removal down). No answer at all: no notice, so the removal still goes through.
        var conv = ConversationsRepository.shared.conversations.first(where: { $0.id == cid })
        if conv == nil, let snap = try? await convRef.getDocument(), let data = snap.data() {
            conv = Conversation(id: cid, data: data)
        }
        let canNotice = conv.map {
            $0.canSend(uid, now: Date().timeIntervalSince1970 * 1000) && !$0.groupMod.blocksSending()
        } ?? false
        var update: [String: Any] = [
            "users": FieldValue.arrayRemove([removed]),
            "admins": FieldValue.arrayRemove([removed]),
            // Ban the removed user so they can't rejoin via an invite link (a "kick" must stick). Re-adding
            // them (Add Members) or approving a join request lifts the ban. Clear their admin/restriction state.
            "bannedUids": FieldValue.arrayUnion([removed]),
            "adminRights.\(removed)": FieldValue.delete(),
            "adminBy.\(removed)": FieldValue.delete(),   // owner 2026-10-18
            "restrictedFlags.\(removed)": FieldValue.delete(),
            "restrictedUntil.\(removed)": FieldValue.delete(),
            "updatedAt": FieldValue.serverTimestamp(),
        ]
        let batch = db.batch()
        if canNotice {
            batch.setData(["text": text, "authorId": uid, "type": "system",
                           "createdAt": FieldValue.serverTimestamp()],
                          forDocument: convRef.collection("messages").document())
            update["lastMessage"] = text
            update["lastSender"] = uid
            update["unreadCount.\(removed)"] = FieldValue.delete()
        }
        batch.updateData(update, forDocument: convRef)
        try await batch.commit()
    }

    /// Leave a group (remove self). Writes the system message FIRST (while still a member,
    /// so the message-create rule passes), then removes self.
    ///
    /// ONE BATCH (2026-09-24 audit). It was three awaited writes, so a kill or a dropped signal
    /// between them left "X left" in the chat while X was still a member. The message rule reads
    /// the conversation with `get()`, which sees the state BEFORE the batch, so I still count as a
    /// member for the two notices; the self-leave update branch limits no other keys.
    ///
    /// A TRANSACTION, NOT A BATCH (2026-09-24 audit). "Am I the last admin?" was answered from the
    /// local cache, so two admins leaving at the same moment each saw the other still listed, both
    /// skipped the heir, and the group was left with no admin. The answer now comes from the server
    /// read inside the transaction, and a concurrent leave makes it retry against the new state.
    /// The rules refuse an admin-emptying leave as well. Cost: leaving needs a connection.
    static func leaveGroup(cid: String) async throws {
        let convRef = db.collection("conversations").document(cid)
        let me = uid
        let left = "\(myName()) left"
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            db.runTransaction({ txn, errPtr -> Any? in
                let snap: DocumentSnapshot
                do { snap = try txn.getDocument(convRef) } catch {
                    errPtr?.pointee = error as NSError
                    return nil
                }
                let data = snap.data() ?? [:]
                let users = data["users"] as? [String] ?? []
                let admins = data["admins"] as? [String] ?? []
                let names = data["names"] as? [String: String] ?? [:]
                // 2026-10-19: the notices only when the message rule would take mine (read from the
                // server copy just fetched): a member of an admins-only group, a muted member, or a
                // suspended group leaves without them instead of the refused notice refusing the leave.
                let fresh = Conversation(id: cid, data: data)
                let canNotice = fresh.canSend(me, now: Date().timeIntervalSince1970 * 1000)
                    && !fresh.groupMod.blocksSending()
                func notice(_ text: String) {
                    guard canNotice else { return }
                    txn.setData(["text": text, "authorId": me, "type": "system",
                                 "createdAt": FieldValue.serverTimestamp()],
                                forDocument: convRef.collection("messages").document())
                }
                var convUpdate: [String: Any] = [
                    "users": FieldValue.arrayRemove([me]),
                    "admins": FieldValue.arrayRemove([me]),
                    "updatedAt": FieldValue.serverTimestamp(),
                ]
                // If I'm the LAST admin, promote a remaining member in the same write so the group
                // never ends up with no one who can manage it.
                let owner = data["createdBy"] as? String ?? ""
                let ownerHeir: String? = (!owner.isEmpty && owner == me)
                    ? (admins.first(where: { $0 != me && users.contains($0) }) ?? users.first(where: { $0 != me }))
                    : nil
                if admins.filter({ $0 != me }).isEmpty,
                   let heir = users.first(where: { $0 != me }) {
                    convUpdate["admins"] = [heir]   // one field cannot take arrayUnion and arrayRemove at once
                    // Tell everyone who inherited admin (otherwise the heir never learns). 2026-10-19:
                    // not when the same person is also named the owner below; that line says it all.
                    if ownerHeir != heir { notice("\(names[heir] ?? "A member") is now an admin") }
                }
                // 2026-09-24 decision D23: the OWNER leaving hands ownership on in this same write:
                // to the longest-serving admin (`admins` keeps promotion order, arrayUnion appends),
                // else the longest-serving member (`users` keeps join order), who was made admin just
                // above. Before this `createdBy` kept naming the leaver, and the rules' keep-the-owner
                // check then refused every other admin's write. The rules allow exactly this hand-off.
                if let heir = ownerHeir {
                    convUpdate["createdBy"] = heir
                    // The rules want the new owner in `admins` after the write.
                    if !admins.contains(heir) { convUpdate["admins"] = admins.filter { $0 != me } + [heir] }
                    // The owner holds every right; drop a limited-admin entry so no screen shows one.
                    convUpdate["adminRights.\(heir)"] = FieldValue.delete()
                    convUpdate["adminBy.\(heir)"] = FieldValue.delete()   // owner 2026-10-18
                    notice("\(names[heir] ?? "A member") is now the owner")
                }
                notice(left)
                if canNotice {
                    convUpdate["lastMessage"] = left
                    convUpdate["lastSender"] = me
                }
                txn.updateData(convUpdate, forDocument: convRef)
                return nil
            }, completion: { _, error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            })
        }
    }

    /// Announcement mode (admin): when true, only admins may send. Enforced in the message
    /// CREATE rule (real, not just UI) + a system message so members know.
    static func setOnlyAdminsSend(cid: String, _ value: Bool) async throws {
        try await db.collection("conversations").document(cid).updateData([
            "onlyAdminsSend": value,
            "updatedAt": FieldValue.serverTimestamp(),
        ])
        try await writeSystemMessage(cid: cid, text: value
            ? "\(myName()) restricted messaging to admins only"
            : "\(myName()) allowed everyone to send messages")
    }

    /// What members may send (owner 2026-10-19): the whole `memberSend` map in one write, and the
    /// group told in one line when a mode was picked (`notice`), as Announcement mode is.
    static func setMemberSend(cid: String, _ send: [String: Bool], notice: String? = nil) async throws {
        try await db.collection("conversations").document(cid).updateData([
            "memberSend": send,
            "updatedAt": FieldValue.serverTimestamp(),
        ])
        if let notice { try await writeSystemMessage(cid: cid, text: "\(myName()) \(notice)") }
    }

    /// One kind only (audit 2026-10-20): a field-path write, so two admins flipping different kinds
    /// at once do not overwrite each other. Photos/videos also drop the old `media` key.
    static func setMemberSendKind(cid: String, _ kind: String, _ on: Bool, pair: (String, Bool)? = nil) async throws {
        var data: [String: Any] = ["memberSend.\(kind)": on, "updatedAt": FieldValue.serverTimestamp()]
        // The old `media` key goes; `pair` keeps the other of photos/videos what it said.
        if let pair {
            data["memberSend.\(pair.0)"] = pair.1
            data["memberSend.media"] = FieldValue.delete()
        }
        try await db.collection("conversations").document(cid).updateData(data)
    }

    /// Slow mode (2026-10-20): seconds between a member's messages, 0 = off, with a line in the group.
    static func setGroupSlowMode(cid: String, seconds: Int) async throws {
        try await db.collection("conversations").document(cid).updateData([
            "slowMode": seconds,
            "updatedAt": FieldValue.serverTimestamp(),
        ])
        let what = seconds == 0 ? "turned off slow mode"
            : seconds < 60 ? "set slow mode to \(seconds) seconds"
            : seconds < 3600 ? "set slow mode to \(seconds / 60) minute\(seconds == 60 ? "" : "s")"
            : "set slow mode to 1 hour"
        try await writeSystemMessage(cid: cid, text: "\(myName()) \(what)")
    }

    /// End Group (owner 2026-10-20): the owner closes the group for everyone, for good. Server-side
    /// (functions-groups endGroup), which checks the owner and writes the notice line.
    static func endGroup(cid: String) async throws {
        _ = try await Functions.functions(region: "me-central1").httpsCallable("endGroup").call(["cid": cid])
    }

    /// Block Group (owner 2026-10-20): nobody in it can add me back (the server reads this list when
    /// someone adds me), then I leave. Joining again by a link stays my own choice.
    static func blockGroup(cid: String) async throws {
        guard let me = Auth.auth().currentUser?.uid else { return }
        // Out first: a leave that fails leaves no block behind on a group I am still in (audit).
        try await leaveGroup(cid: cid)
        try await db.collection("users").document(me).collection("blockedGroups").document(cid)
            .setData(["at": FieldValue.serverTimestamp()])
    }

    /// Chat history for new members (owner 2026-10-20): Hidden stamps the moment (server time);
    /// Visible removes it. The group is told in one line, as other settings do.
    static func setHideHistory(cid: String, hidden: Bool) async throws {
        try await db.collection("conversations").document(cid).updateData([
            "hideHistoryAt": hidden ? FieldValue.serverTimestamp() : FieldValue.delete(),
            "updatedAt": FieldValue.serverTimestamp(),
        ])
        try? await writeSystemMessage(cid: cid, text: hidden
            ? "\(myName()) hid chat history from new members"
            : "\(myName()) made chat history visible to new members")
    }

    /// Toggle a member permission (admin): "membersCanAdd" or "membersCanEditInfo".
    static func setGroupPermission(cid: String, key: String, _ value: Bool) async throws {
        try await db.collection("conversations").document(cid).updateData([
            key: value,
            "updatedAt": FieldValue.serverTimestamp(),
        ])
    }

    /// Set the group description / "about" (admin). No system message (low-signal change).
    static func setGroupDescription(cid: String, text: String) async throws {
        let desc = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(AppLimits.shared.groupDescMax))
        try await db.collection("conversations").document(cid).updateData([
            "desc": desc,
            "updatedAt": FieldValue.serverTimestamp(),
        ])
    }

    /// Rename a group (admin) + system message.
    static func renameGroup(cid: String, title: String) async throws {
        let t = String(title.trimmingCharacters(in: .whitespaces).prefix(100))
        guard !t.isEmpty else { return }
        let convRef = db.collection("conversations").document(cid)
        try await convRef.updateData(["title": t, "updatedAt": FieldValue.serverTimestamp()])
        try? await writeSystemMessage(cid: cid, text: "\(myName()) renamed the group to “\(t)”")
    }

    /// Promote a member to admin (owner, or an admin with "Add new admins") + system message.
    /// owner 2026-10-18: the new admin's rights are written out (`rights`, default
    /// `Conversation.Right.defaults`), with `adminBy` = me and `adminEdit` naming them, which is what
    /// firestore.rules `delegatedAdminEditOK` holds a non-owner promoter to. A non-owner passes only
    /// rights they hold themselves.
    static func promoteGroupAdmin(cid: String, uid promoted: String, name: String,
                                  rights: [String] = Conversation.Right.defaults.map(\.rawValue)) async throws {
        let convRef = db.collection("conversations").document(cid)
        var data: [String: Any] = [
            "admins": FieldValue.arrayUnion([promoted]),
            "adminRights.\(promoted)": rights,
            "adminBy.\(promoted)": uid,
            "adminEdit": ["uid": promoted, "by": uid],
            "updatedAt": FieldValue.serverTimestamp(),
        ]
        // An admin is never restricted: clear any lingering mute so a later demote can't silently
        // re-apply a stale "forever" restriction. Only someone who may lift restrictions writes
        // these (the rules want Remove members for them); for anyone else they stay, harmlessly,
        // since admins are exempt (audit 2026-10-20: a delegated admin's promote was refused).
        let conv = await MainActor.run { ConversationsRepository.shared.conversations.first { $0.id == cid } }
        let me = uid
        if conv?.isOwner(me) == true || conv?.adminCan(me, .banUsers) == true {
            data["restrictedFlags.\(promoted)"] = FieldValue.delete()
            data["restrictedUntil.\(promoted)"] = FieldValue.delete()
        }
        try await convRef.updateData(data)
        try? await writeSystemMessage(cid: cid, text: "\(myName()) made \(name) an admin")
    }

    /// Demote an admin back to a regular member (the owner, or the admin who promoted them) + system
    /// message. Clears any per-flag grant and who promoted them.
    static func demoteGroupAdmin(cid: String, uid demoted: String, name: String) async throws {
        let convRef = db.collection("conversations").document(cid)
        try await convRef.updateData([
            "admins": FieldValue.arrayRemove([demoted]),
            "adminRights.\(demoted)": FieldValue.delete(),
            "adminBy.\(demoted)": FieldValue.delete(),
            "adminEdit": ["uid": demoted, "by": uid],
            "updatedAt": FieldValue.serverTimestamp(),
        ])
        try? await writeSystemMessage(cid: cid, text: "\(myName()) removed \(name) as admin")
    }

    /// Set an admin's granted per-flag rights (the owner, or the admin who promoted them). `rights`
    /// is a subset of Conversation.Right raw values; a non-owner may list only rights they hold.
    static func setAdminRights(cid: String, uid target: String, rights: [String]) async throws {
        try await db.collection("conversations").document(cid).updateData([
            "adminRights.\(target)": rights,
            "adminEdit": ["uid": target, "by": uid],
            "updatedAt": FieldValue.serverTimestamp(),
        ])
    }

    /// owner 2026-10-18: LET A REMOVED PERSON BACK (Removed Users). Takes them off `bannedUids`, so
    /// an invite link or a join request works for them again; it does not add them to the group.
    /// firestore.rules: the remove-members right, or the add-members right (which may only shrink it).
    static func unbanGroupMember(cid: String, uid target: String) async throws {
        try await db.collection("conversations").document(cid).updateData([
            "bannedUids": FieldValue.arrayRemove([target]),
            "updatedAt": FieldValue.serverTimestamp(),
        ])
    }

    /// owner 2026-10-18: TRANSFER OWNERSHIP (owner only; firestore.rules `ownerHandOffOK`). The new
    /// owner must be a member; they become an admin if they were not. I stay in the group as an admin
    /// with every right, "Add new admins" included, the way the reference app leaves its old owner.
    static func transferGroupOwnership(cid: String, to heir: String, name: String) async throws {
        let convRef = db.collection("conversations").document(cid)
        let me = uid
        let text = "\(name) is now the owner"
        let batch = db.batch()
        batch.setData(["text": text, "authorId": me, "type": "system",
                       "createdAt": FieldValue.serverTimestamp()],
                      forDocument: convRef.collection("messages").document())
        batch.updateData([
            "createdBy": heir,
            "admins": FieldValue.arrayUnion([heir]),
            // The owner holds every right; no entry, nobody's appointee.
            "adminRights.\(heir)": FieldValue.delete(),
            "adminBy.\(heir)": FieldValue.delete(),
            "restrictedFlags.\(heir)": FieldValue.delete(),
            "restrictedUntil.\(heir)": FieldValue.delete(),
            "adminRights.\(me)": Conversation.Right.allCases.map(\.rawValue),
            "adminBy.\(me)": heir,
            "lastMessage": text,
            "lastSender": me,
            "updatedAt": FieldValue.serverTimestamp(),
        ], forDocument: convRef)
        try await batch.commit()
    }

    /// Restrict a member with an auto-expiring timeout (the reference app bannedRights model). `flags` is a
    /// subset of Conversation.Restrict raw values; `until` is an absolute ms timestamp (0 = clear).
    static func restrictMember(cid: String, uid: String, name: String, flags: [String], until: Double) async throws {
        let convRef = db.collection("conversations").document(cid)
        // The server's clock, which the rules judge `until` by (audit 2026-10-20: a phone running
        // behind made a 1 hour mute already over when it landed).
        if flags.isEmpty || until <= ServerClock.now.timeIntervalSince1970 * 1000 {
            try await convRef.updateData([
                "restrictedFlags.\(uid)": FieldValue.delete(),
                "restrictedUntil.\(uid)": FieldValue.delete(),
                "updatedAt": FieldValue.serverTimestamp(),
            ])
            try? await writeSystemMessage(cid: cid, text: "\(myName()) lifted the restrictions on \(name)")
        } else {
            try await convRef.updateData([
                "restrictedFlags.\(uid)": flags,
                "restrictedUntil.\(uid)": until,
                "updatedAt": FieldValue.serverTimestamp(),
            ])
            try? await writeSystemMessage(cid: cid, text: "\(myName()) restricted \(name)")
        }
    }

    /// Convenience: fully mute a member (block all sending) for `seconds` (0 = forever).
    static func muteMember(cid: String, uid: String, name: String, seconds: Double) async throws {
        let forever = 60.0 * 60 * 24 * 365 * 50   // ~50y sentinel = "forever"
        let until = (ServerClock.now.timeIntervalSince1970 + (seconds > 0 ? seconds : forever)) * 1000
        try await restrictMember(cid: cid, uid: uid, name: name, flags: Conversation.muteAllFlags, until: until)
    }

    /// Lift all restrictions on a member.
    static func unmuteMember(cid: String, uid: String, name: String) async throws {
        try await restrictMember(cid: cid, uid: uid, name: name, flags: [], until: 0)
    }

    private static func myName() -> String {
        let n = ProfileStore.shared.me?.name ?? ""
        return n.isEmpty ? "Someone" : n
    }

    /// A system-event message: PLAINTEXT (membership/rename events aren't private content),
    /// shown centered in the thread. Also updates the chat-list preview.
    /// `extra` rides on the message document beside the text, for notices that carry a value the
    /// reader's phone needs in order to word the line itself.
    private static func writeSystemMessage(cid: String, text: String, extra: [String: Any] = [:]) async throws {
        let convRef = db.collection("conversations").document(cid)
        let msgRef = convRef.collection("messages").document()
        let batch = db.batch()
        var doc: [String: Any] = [
            "text": text,
            "authorId": uid,
            "type": "system",
            "createdAt": FieldValue.serverTimestamp(),
        ]
        doc.merge(extra) { _, new in new }
        batch.setData(doc, forDocument: msgRef)
        batch.updateData([
            "lastMessage": text,
            "lastSender": uid,
            "updatedAt": FieldValue.serverTimestamp(),
        ], forDocument: convRef)
        try await batch.commit()
    }

    /// Encrypt + send a text message and bump the conversation. Throws
    /// MissingRecipientKeyError if the recipient has no key yet (never sends plaintext).
    /// Sender-fetched link preview attached to a text send (the reference app's model — see LinkPreviewService).
    struct OutgoingLinkPreview {
        let url: String
        let title: String
        let desc: String
        let imageJPEG: Data?
    }

    /// Seal + upload a composer link-preview draft for one message: text fields sealed exactly like
    /// the caption, the image encrypted + uploaded exactly like a photo. Best-effort — a nil return
    /// (or a failed image upload) never blocks the text itself.
    private static func sealLinkPreview(_ p: OutgoingLinkPreview, cid: String, members: [String]?,
                                        msgId: String) async -> [String: Any]? {
        func seal(_ s: String) async -> String? {
            guard !s.isEmpty else { return nil }
            if let members { return try? await Crypto.shared.sealForGroup(s, members: members, cid: cid) }
            return try? await Crypto.shared.encryptForConversation(cid, s)
        }
        guard let cu = await seal(p.url) else { return nil }
        var d: [String: Any] = ["url": cu]
        if let ct = await seal(p.title) { d["title"] = ct }
        if let cd = await seal(p.desc) { d["desc"] = cd }
        if let jpeg = p.imageJPEG {
            do {
                let cipher: Data, meta: EncMeta
                if let members { (cipher, meta) = try await Crypto.shared.sealBytesForGroup(jpeg, members: members, cid: cid) }
                else { (cipher, meta) = try await Crypto.shared.encryptBytes(cid, jpeg) }
                let url = try await uploadEncrypted(cipher, to: "chat/\(cid)/\(msgId)-lp.enc")
                // Seed the cache so the sender's own card swaps from draft to server image invisibly.
                if let ui = UIImage(data: jpeg) { DiskImageCache.shared.store(ui, for: url, owned: true) }
                d["imageUrl"] = url
                d["imageEnc"] = meta.asDict
            } catch { /* the card ships without its image */ }
        }
        return d
    }

    /// 2026-10-23 (owner, build 1014): THE CARD FOLLOWS THE TEXT, the reference app's way. A text
    /// holding a link is written at once (`sendText` with no preview) and its card is added here,
    /// in one update of `linkPreview` on that same message, once it has been fetched, sealed and its
    /// image uploaded. The rules take this once, from the author, within two minutes of the send.
    /// Best effort: false means the message simply stays without a card.
    /// Not on a 1:1 request still waiting for its answer (a request is one short text), and not for
    /// a group member kept from sending links.
    @discardableResult
    static func attachLinkPreview(cid: String, clientId: String, preview: OutgoingLinkPreview,
                                  group: [String]?) async -> Bool {
        guard !clientId.isEmpty, !clientId.contains("/") else { return false }
        let convRef = db.collection("conversations").document(cid)
        var members = await freshGroupMembers(cid, group)
        if members == nil, !cid.contains("_") { members = try? await groupDocMembers(cid) }
        if members == nil, !cid.contains("_") { return false }
        let me = uid
        let local = await MainActor.run { ConversationsRepository.shared.conversations.first { $0.id == cid } }
        if members != nil {
            if local?.isRestricted(me, .sendLinks, now: Date().timeIntervalSince1970 * 1000) == true { return false }
        } else {
            func open(_ c: Conversation) -> Bool { c.startedBy.isEmpty || c.accepted || c.reqOff }
            if !(local.map(open) ?? false) {
                // The phone's copy can be a beat behind (my reply that accepts rides the send).
                guard let d = (try? await convRef.getDocument(source: .server))?.data(),
                      open(Conversation(id: cid, data: d)) else { return false }
            }
        }
        guard let lp = await sealLinkPreview(preview, cid: cid, members: members, msgId: clientId) else { return false }
        do {
            try await convRef.collection("messages").document(clientId).updateData(["linkPreview": lp])
            return true
        } catch {
            DiagLog.add("LINK# card not attached cid=\(cid) err=\((error as NSError).code)")
            return false
        }
    }

    /// ⛔ `countsAsUnread` — a NOTICE IS NOT A MESSAGE. Pin notices, poll cards and location markers
    /// all route through here, and this unconditionally incremented the other person's unread badge,
    /// so pinning something in an already-read chat lit up their chat row with a "1" for a message
    /// they had not been sent. The reaction path already refuses to do this and says why ("a reaction
    /// shouldn't reorder chats or re-arm unread"); the intent existed and these three callers simply
    /// were not covered by it.
    ///
    /// owner audit 2026-10-06 chat #24: `tapTs` is when Send was tapped (ms epoch) and `turn` is the
    /// place in this chat's send line taken at that tap. Both are optional: a caller without them is
    /// stamped and queued on entry here, which is still before every await below.
    static func sendText(cid: String, text: String, replyTo: ReplyRef? = nil, clientId: String? = nil, group: [String]? = nil, mentions: [String] = [], preview: OutgoingLinkPreview? = nil, forwarded: Bool = false, countsAsUnread: Bool = true,
                         tapTs: Double? = nil, turn: SendTurn? = nil,
                         storyMention: StoryMentionRef? = nil) async throws {
        // owner audit 2026-10-06 chat #24: stamped and queued BEFORE the first await. `clientTs` used
        // to be read after encryption and the server reads, so of two quick sends whichever cleared
        // those awaits first took the earlier stamp, and nothing kept their writes in tap order.
        let clientTs = tapTs ?? Date().timeIntervalSince1970 * 1000
        let turn = turn ?? SendTurn.take(cid)
        defer { turn.finish() }   // every exit, thrown or returned, lets the next send go
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        // Group path: per-member encryption + unread fan-out. 1:1 path below is untouched.
        // Resolve members even if the caller didn't pass them (e.g. the very first message
        // right after creation, before the conversations listener has the doc). A group cid
        // is a random id with no "_", so that distinguishes it from a 1:1 "uidA_uidB" cid.
        var members = await freshGroupMembers(cid, group)   // 2026-09-24 fix-all #111
        if members == nil, !cid.contains("_") { members = try await groupDocMembers(cid) }
        if let members {
            try await sendGroupText(cid: cid, members: members, text: t, replyTo: replyTo, clientId: clientId, mentions: mentions, preview: preview, forwarded: forwarded,
                                    clientTs: clientTs, turn: turn)
            return
        }

        let cipher = try await Crypto.shared.encryptForConversation(cid, t)
        var replyEnc: [String: Any]?
        if let r = replyTo {
            let rc = try await Crypto.shared.encryptForConversation(cid, r.text)
            var e: [String: Any] = ["id": r.id, "authorId": r.authorId, "text": rc]
            if r.isStatus { e["isStatus"] = true }
            if r.isReaction == true { e["isReaction"] = true }   // the story react bar (see ReplyRef)
            if let thumb = r.storyThumbUrl, !thumb.isEmpty { e["storyThumb"] = thumb }   // plaintext story URL (not E2EE)
            replyEnc = e
        }

        let other = cid.split(separator: "_").map(String.init).first { $0 != uid } ?? ""
        let convRef = db.collection("conversations").document(cid)

        // A KNOCK COUNTS AGAINST THE DAY — owner's spec, 2026-09-11 §25. The one message to a
        // stranger bumps `users/{me}/limits/requests` before it goes, and the message rule reads
        // that counter. The local mirror answers first; a chat born a moment ago that the listener
        // has not delivered yet is read from the server, because that brand-new chat is exactly
        // the case this counts. See `MessageRequests.countKnock` for why it is best effort.
        // owner 2026-10-18: `rawStance`, not `stance`. With Message Requests switched off in the
        // admin panel the first message to a stranger is still a new chat with a stranger, and the
        // rules still hold it to the day's budget, so it is still counted.
        // ...and `answering`: a reply to somebody else's unanswered chat carries `accepted: true`
        // in the same write. With requests on the composer only exists after Accept, so this
        // changes nothing; with them off it is the one moment "friends" begins.
        var knocking: Bool?
        var answering = false
        let localConv = await MainActor.run { ConversationsRepository.shared.conversations.first { $0.id == cid } }
        if let localConv {
            let raw = MessageRequests.rawStance(localConv)
            knocking = raw == .firstMessage
            answering = raw == .incoming
        }
        if knocking == nil, let d = (try? await convRef.getDocument())?.data() {
            let raw = MessageRequests.rawStance(Conversation(id: cid, data: d))
            knocking = raw == .firstMessage
            answering = raw == .incoming
        }
        if knocking == true { await MessageRequests.countKnock(clientId: clientId) }   // 2026-09-24 feature-audit: once per clientId

        // Brand-new chat? The "Disappearing Messages for new chats" default applies only to chats
        // born here. This asked the LOCAL mirror, which is EMPTY until the first conversations
        // snapshot lands — so a send into an EXISTING chat during that window (cold start, opened
        // straight from @search) wrote the default timer onto a conversation both people had
        // already configured, silently, with none of the system notices setDisappear insists on
        // (audit). Ask the server, and treat "couldn't tell" as not-new so we never flip it blind.
        let localSaysNew = await MainActor.run {
            !ConversationsRepository.shared.conversations.contains { $0.id == cid }
        }
        var isNewConv = localSaysNew
        if localSaysNew, let snap = try? await convRef.getDocument() {
            isNewConv = !snap.exists
        } else if localSaysNew {
            isNewConv = false   // the check itself failed — never seed on a guess
        }

        // ⛔ THE LIVE SWITCH BEFORE A FIRST MESSAGE — owner 2026-10-21. The listener (and the copy
        // saved on the phone) can be behind a flip in the panel, and the rules read the live one,
        // so a first message asks the server once (2s at most, then the cache) for the switch and,
        // if never seen, the recipient's own override. Everything below that depends on "are
        // requests on for them" (the link card, the `reqOff` stamp) then reads the truth.
        let firstMessage = knocking == true || isNewConv
        if firstMessage { await MsgPolicy.shared.confirm(for: other) }
        // owner 2026-10-21 (his decision): a chat whose first message goes while Message Requests
        // are OFF for the recipient stays an ordinary chat if they come back on. Marked `reqOff`,
        // in the same write as the rest of the seed; the rules allow it only while the switch is
        // really off for them and nobody has written yet (see `firestore.rules`, reqOffStampOk).
        let stampReqOff = firstMessage && !MsgPolicy.shared.requestsOn(for: other) && localConv?.reqOff != true

        // Ensure the conversation exists BEFORE the message. The rules require
        // convData().users to authorize a message create; on a brand-new chat the
        // create otherwise loses the race and is rolled back server-side (message
        // "sends" locally then silently vanishes). Awaiting this first send keeps
        // the writes ordered so the conv is committed before the message.
        var convSeed: [String: Any] = [
            "users": [uid, other],
            "updatedAt": FieldValue.serverTimestamp(),
        ]
        if isNewConv {
            let def = UserDefaults.standard.integer(forKey: "defaultDisappearSeconds")
            if def > 0 { convSeed["disappearSeconds"] = def }
            // 2026-09-24 audit: a new 1:1 is born a request, and the create rule refuses one without
            // these two, so a chat reached without `openConversation` could never send its first
            // message. `isNewConv` is true only when the server read answered "not there", the same
            // condition `openConversation` stamps on.
            convSeed["startedBy"] = uid
            convSeed["accepted"] = false
        }
        if stampReqOff { convSeed["reqOff"] = true }
        // A chat already in this phone's list with both of us in it exists on the server: the seed
        // would only cost a round trip before the message and a second chat-list write (audit 04 F3).
        let seedNeeded = isNewConv || stampReqOff
            || !(localConv.map { $0.users.contains(uid) && $0.users.contains(other) } ?? false)
        if seedNeeded {
        do {
            do {
                try await convRef.setData(convSeed, merge: true)
            } catch let e where stampReqOff && SendQueue.isPermanentRefusal(e) {
                // owner 2026-10-21: the stamp alone was refused (the switch came back on, or the
                // other person wrote first): the message still goes, as an ordinary first message.
                convSeed.removeValue(forKey: "reqOff")
                DiagLog.add("REQ# reqOff stamp refused cid=\(cid)")
                try await convRef.setData(convSeed, merge: true)
            }
        } catch {
            // Owner, 2026-10-08: a refused seed write is a refused send; wake the recovery net.
            await MainActor.run { SessionRecovery.noteRefusal(error, "send") }
            throw error
        }
        }
        // ...and that first message is a knock, which the check above could not see (no document yet).
        if isNewConv && knocking == nil { await MessageRequests.countKnock(clientId: clientId) }

        let msgRef = textMessageRef(convRef, clientId: clientId)   // owner audit 2026-10-06 chat #77
        let batch = db.batch()
        var msg: [String: Any] = [
            "text": cipher,
            "authorId": uid,
            "createdAt": FieldValue.serverTimestamp(),
            "clientTs": clientTs,   // tap time — display order is send order (chat #24: stamped at the tap)
        ]
        if let clientId { msg["clientId"] = clientId }   // lets the client reconcile its optimistic copy
        if let replyEnc { msg["replyTo"] = replyEnc }
        if !mentions.isEmpty { msg["mentions"] = mentions }
        if forwarded { msg["forwarded"] = true }
        // A story mention card (`Message.storyMention`, owner 2026-10-16). 1:1 only, like replies.
        if let storyMention { msg["storyMention"] = ["id": storyMention.id, "thumb": storyMention.thumbUrl] }
        // 2026-09-24 feature-audit: a knock carries no link card. The rules take a request's one
        // message as plain short text and refuse `linkPreview` on it, so the card turned every first
        // message holding a link into a send that failed on every Resend. Stripped here rather than
        // only in the composer, so a queued retry or a forward is covered too; the link stays in the text.
        // owner 2026-10-18: not with Message Requests off for them (MsgPolicy); the rules take any
        // first message then, card included.
        let knockPreview = ((knocking == true || isNewConv) && MsgPolicy.shared.requestsOn(for: other)) ? nil : preview
        if let knockPreview, let lp = await sealLinkPreview(knockPreview, cid: cid, members: nil, msgId: msgRef.documentID) {
            msg["linkPreview"] = lp
        }
        batch.setData(msg, forDocument: msgRef)
        var convUpdate: [String: Any] = [
            "lastMessage": cipher,
            "lastSender": uid,                 // drives the read-receipt ticks in the chat list
            "updatedAt": FieldValue.serverTimestamp(),
        ]
        if countsAsUnread { convUpdate["unreadCount.\(other)"] = FieldValue.increment(Int64(1)) }
        if answering { convUpdate["accepted"] = true }   // owner 2026-10-18, see `answering` above
        batch.updateData(convUpdate, forDocument: convRef)
        try await commitTextInTurn(batch, turn: turn, clientId: clientId)
    }

    /// 2026-09-24 fix-all #111: the member list a group message is sealed to, read from the SERVER
    /// rather than taken from the screen's cached conversation. A member removed on another device
    /// stayed in that cache until this phone's listener caught up, and anything sent in that window
    /// was still wrapped for them. One server read per group, reused for 10 seconds so a burst of
    /// sends (an album, a forward to one group) pays once. Offline, the cached list is used: the
    /// send is queued either way. A 1:1 cid ("uidA_uidB") passes straight through.
    private static let sealMembersLock = NSLock()
    private static var sealMembersConfirmed: [String: (users: [String], at: Date)] = [:]
    /// The members from the group's own doc, for a send that had none. A group I was removed from,
    /// or one deleted, while the send waited offline throws a refusal, so the queue marks it failed
    /// instead of retrying it on every launch down the 1:1 path (audit 2026-10-20). Offline is not
    /// a refusal: nil, and the send keeps its retry.
    static func groupDocMembers(_ cid: String) async throws -> [String]? {
        do {
            let snap = try await db.collection("conversations").document(cid).getDocument()
            if !snap.exists, !snap.metadata.isFromCache {
                throw NSError(domain: FirestoreErrorDomain, code: FirestoreErrorCode.permissionDenied.rawValue,
                              userInfo: [NSLocalizedDescriptionKey: "This group is no longer available."])
            }
            return snap.data()?["users"] as? [String]
        } catch let e as NSError where e.domain == FirestoreErrorDomain
                    && e.code == FirestoreErrorCode.permissionDenied.rawValue {
            throw e
        } catch {
            return nil
        }
    }

    static func freshGroupMembers(_ cid: String, _ cached: [String]?) async -> [String]? {
        guard !cid.contains("_") else { return cached }
        if let hit = sealMembersLock.withLock({ sealMembersConfirmed[cid] }),
           Date().timeIntervalSince(hit.at) < 10 {
            return hit.users
        }
        guard let snap = try? await db.collection("conversations").document(cid).getDocument(source: .server),
              let users = snap.data()?["users"] as? [String] else { return cached }
        let plain = (snap.data()?["e2ee"] as? Bool) == false
        sealMembersLock.withLock {
            sealMembersConfirmed[cid] = (users, Date())
            if plain { plainGroups.insert(cid) }
        }
        return users
    }

    /// 2026-10-19 groups v2 (owner): GROUPS ARE NO LONGER END-TO-END ENCRYPTED for new messages.
    /// A group whose document says `e2ee == false` (written by the server's groupsE2eeOff step, or
    /// by createGroup for a new group) sends text and files in the clear; the database rules refuse
    /// plain text in a group that has not switched, so anything unsure seals as before. The answer
    /// comes from the server read `freshGroupMembers` makes before every group send, else from the
    /// chat list's copy. The switch only ever goes one way, so a remembered "plain" never goes stale.
    /// A 1:1 cid ("uidA_uidB") is never plain.
    private static var plainGroups: Set<String> = []
    static func groupIsPlain(_ cid: String) async -> Bool {
        guard !cid.contains("_") else { return false }
        if sealMembersLock.withLock({ plainGroups.contains(cid) }) { return true }
        let listed = await MainActor.run {
            ConversationsRepository.shared.conversations.first { $0.id == cid }?.e2eeOff ?? false
        }
        if listed { sealMembersLock.withLock { _ = plainGroups.insert(cid) } }
        return listed
    }

    /// Drop the reused list when this device changes membership itself.
    static func forgetSealMembers(_ cid: String) {
        _ = sealMembersLock.withLock { sealMembersConfirmed.removeValue(forKey: cid) }
    }

    /// Group text send: encrypt once per member, fan out the unread increment to everyone
    /// but me. The conversation already exists (created by createGroup), so no users write.
    private static func sendGroupText(cid: String, members: [String], text t: String,
                                      replyTo: ReplyRef?, clientId: String?, mentions: [String] = [],
                                      preview: OutgoingLinkPreview? = nil, forwarded: Bool = false,
                                      clientTs: Double, turn: SendTurn) async throws {
        let cipher = try await Crypto.shared.sealForGroup(t, members: members, cid: cid)
        var replyEnc: [String: Any]?
        if let r = replyTo {
            let rc = try await Crypto.shared.sealForGroup(r.text, members: members, cid: cid)
            var e: [String: Any] = ["id": r.id, "authorId": r.authorId, "text": rc]
            if r.isStatus { e["isStatus"] = true }
            if r.isReaction == true { e["isReaction"] = true }   // the story react bar (see ReplyRef)
            if let thumb = r.storyThumbUrl, !thumb.isEmpty { e["storyThumb"] = thumb }
            replyEnc = e
        }
        let convRef = db.collection("conversations").document(cid)
        let msgRef = textMessageRef(convRef, clientId: clientId)   // owner audit 2026-10-06 chat #77
        let batch = db.batch()
        var msg: [String: Any] = [
            "text": cipher,
            "authorId": uid,
            "createdAt": FieldValue.serverTimestamp(),
            "clientTs": clientTs,   // tap time — display order is send order (chat #24: stamped at the tap)
        ]
        if let clientId { msg["clientId"] = clientId }
        if let replyEnc { msg["replyTo"] = replyEnc }
        if !mentions.isEmpty { msg["mentions"] = mentions }
        if forwarded { msg["forwarded"] = true }
        // 2026-09-24 decision D-composer-3: a poll says in the clear only whether it takes one answer
        // or several, so the rules can hold a single-answer vote to one option. The question and the
        // options stay sealed in `text`.
        if t.hasPrefix(Message.pollMarker),
           let data = Data(base64Encoded: String(t.dropFirst(Message.pollMarker.count))),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            msg["pollMulti"] = (obj["multi"] as? Bool) ?? false
            // 2026-10-19: the end time in the clear too, so the rules stop late votes.
            if let ends = (obj["ends"] as? NSNumber)?.int64Value, ends > 0 { msg["pollEndsAt"] = ends }
        }
        // 2026-09-24 feature-audit: a member an admin has kept from sending media sends the link as
        // plain text. The rules count a link card as media (`sendMedia`), so it was refused on every
        // Resend while the same words without a link went through.
        let me = uid
        let mediaBarred = await MainActor.run {
            ConversationsRepository.shared.conversations.first { $0.id == cid }?
                // owner 2026-10-18: `sendLinks` (also true under the old all-media `sendMedia`).
                .isRestricted(me, .sendLinks, now: Date().timeIntervalSince1970 * 1000) ?? false
        }
        if !mediaBarred, let preview,
           let lp = await sealLinkPreview(preview, cid: cid, members: members, msgId: msgRef.documentID) {
            msg["linkPreview"] = lp
        }
        batch.setData(msg, forDocument: msgRef)
        var convUpdate: [String: Any] = [
            "lastMessage": cipher,
            "lastSender": uid,
            "updatedAt": FieldValue.serverTimestamp(),
        ]
        // 2026-10-19 groups v2: words in the clear say they are a member's (Conversation.lastPlainTag).
        if !cipher.hasPrefix("enc") { convUpdate["lastPlainTag"] = Conversation.plainTag(cipher) }
        for m in members where m != uid {
            convUpdate["unreadCount.\(m)"] = FieldValue.increment(Int64(1))
        }
        batch.updateData(convUpdate, forDocument: convRef)
        try await commitTextInTurn(batch, turn: turn, clientId: clientId)
    }

    // MARK: - Text send order, cancel and retry safety (owner audit 2026-10-06, chat #23 #24 #77)

    /// owner audit 2026-10-06 chat #77: a text with a clientId is written at `messages/{clientId}`.
    /// The id used to be random, so a send re-driven after a kill (the SDK replaying its own queued
    /// write while `SendQueue.alreadySent` asked the server too early) wrote a SECOND document.
    /// With one fixed address the replay and the retry name the same document: the second write is
    /// an update the rules refuse, the batch with its unread increment is rolled back, and the
    /// person gets one message. The pending bubble already uses the clientId as its id.
    private static func textMessageRef(_ convRef: DocumentReference, clientId: String?) -> DocumentReference {
        let messages = convRef.collection("messages")
        guard let clientId, !clientId.isEmpty, !clientId.contains("/") else { return messages.document() }
        return messages.document(clientId)
    }

    /// owner audit 2026-10-06 chat #24: one line of text sends per chat, in tap order. The server
    /// stamps `createdAt` when the write arrives and the SDK sends writes in the order they were
    /// committed, so holding each commit until the send tapped before it has committed keeps the
    /// server order equal to the tap order. Only the hand-off to the SDK waits, never the server's
    /// answer, and never longer than `maxWait`: a send stuck behind a dead one goes anyway.
    final class SendTurn: @unchecked Sendable {
        private static let lock = NSLock()
        private static var tails: [String: SendTurn] = [:]
        private static let maxWait: TimeInterval = 10

        private let cid: String
        private var previous: SendTurn?
        private var done = false

        private init(cid: String, previous: SendTurn?) {
            self.cid = cid
            self.previous = previous
        }

        /// The next place in `cid`'s line. Call it at the tap, on the main thread, so the line is the
        /// order the taps happened in.
        static func take(_ cid: String) -> SendTurn {
            lock.withLock {
                let turn = SendTurn(cid: cid, previous: tails[cid])
                tails[cid] = turn
                return turn
            }
        }

        var isDone: Bool { Self.lock.withLock { done } }

        /// Lets the next send in the line go. Safe to call more than once.
        func finish() {
            Self.lock.withLock {
                guard !done else { return }
                done = true
                previous = nil   // a finished turn holds nothing, so the line never grows
                if Self.tails[cid] === self { Self.tails[cid] = nil }
            }
        }

        /// 2026-10-20 (owner): after `FirestoreHub.swapped`. Turns taken on the stuck client end their
        /// lines, so the first send on the fresh client does not sit out `maxWait` behind them.
        static func releaseAll() {
            lock.withLock { tails.removeAll() }
        }

        /// Waits until the send before this one has committed (or given up), at most `maxWait`.
        func waitForPrevious() async {
            let deadline = Date().addingTimeInterval(Self.maxWait)
            while let prev = Self.lock.withLock({ previous }), !prev.isDone, Date() < deadline {
                if Task.isCancelled { return }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
        }
    }

    /// owner audit 2026-10-06 chat #23: text sends the user deleted before they went out, and the
    /// clientIds whose write has already been handed to the SDK.
    private static let textSendLock = NSLock()
    private static var cancelledTextSends = Set<String>()
    private static var committedTextSends = Set<String>()

    /// owner audit 2026-10-06 chat #23. Deleting an unsent text dropped its bubble and its queue
    /// entry, but a send suspended in this process (offline, waiting inside `sendText`) still wrote
    /// the message when the signal came back. Called by the delete: a send that has not committed
    /// yet now stops at its commit; one whose write the SDK already holds is taken back by deleting
    /// its document (the author may delete their own message; it lives at `messages/{clientId}`).
    static func cancelTextSend(cid: String, clientId: String) {
        let alreadyCommitted = textSendLock.withLock { () -> Bool in
            cancelledTextSends.insert(clientId)
            return committedTextSends.contains(clientId)
        }
        if alreadyCommitted {
            Task { await cancelAnnounced(cid: cid, messageId: clientId) }
        }
    }

    /// Waits for this send's turn, then hands the batch to the SDK unless the send was deleted
    /// meanwhile. The turn is released the moment the SDK holds the write, before the server answers.
    private static func commitTextInTurn(_ batch: WriteBatch, turn: SendTurn, clientId: String?) async throws {
        await turn.waitForPrevious()
        if let clientId {
            let cancelled = textSendLock.withLock { () -> Bool in
                if cancelledTextSends.contains(clientId) { return true }
                committedTextSends.insert(clientId)
                return false
            }
            if cancelled { turn.finish(); return }   // deleted before it went: nothing is written
        }
        // Owner, 2026-10-08: a send the server never answers looked sent forever and woke nothing.
        // After 15s with no answer, while the app is in front, tell the recovery net once. The local
        // write stays queued in the SDK and goes out by itself after recovery: nothing is dropped
        // and nothing is sent twice.
        let answered = StallFlag()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            if !answered.isSet, UIApplication.shared.applicationState == .active {
                print("[Recovery] send unanswered for 15s")
                SessionRecovery.noteStall("send")
            }
        }
        do {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                batch.commit { error in
                    if let error { c.resume(throwing: error) } else { c.resume() }
                }
                turn.finish()   // the SDK holds the write now, in order
            }
            answered.set()
        } catch {
            answered.set()
            // Why the server said no (owner 2026-10-21, first messages vanishing): code 7 is the
            // rules; the text says which (including "evaluation limit").
            let ns = error as NSError
            DiagLog.add("SEND# refused code=\(ns.code) \(ns.localizedDescription.prefix(200))")
            Telemetry.event(.error, component: "send", code: Telemetry.code(error))   // owner 2026-10-21: code only, never the text
            DiagLog.flagForUpload()   // sent within seconds, so the cause can be read the same day
            await MainActor.run { SessionRecovery.noteRefusal(error, "send") }
            throw error
        }
    }

    /// Set once a send's server answer (or error) has arrived; read by the 15s stall watch.
    private final class StallFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.withLock { value } }
        func set() { lock.withLock { value = true } }
    }

    /// Encrypt + send a photo. The JPEG bytes are sealed with Crypto.encryptBytes
    /// and the ciphertext is uploaded to Storage; the server never sees the image.
    /// Downscale + recompress a photo before encrypting/uploading. Cuts upload size
    /// (and failure rate) massively; full-res camera/library photos are huge.
    /// Global Sent Media Quality (Settings > Storage and Data). High = bigger photos
    /// (2048px @ 0.9) and 1080p video; Standard = the long-standing 1600px @ 0.72 + 720p.
    static var highQualitySends: Bool {
        UserDefaults.standard.string(forKey: "sentMediaQuality") == "high"
    }

    /// The photo-SEND compression (thumbnails/stories/wallpapers keep their own explicit calls).
    static func sendJPEG(_ data: Data) -> Data {
        highQualitySends ? downscaledJPEG(data, maxDimension: 2048, quality: 0.9)
                         : downscaledJPEG(data)
    }

    /// ⛔ THE PICTURE THAT TRAVELS WITH THE MESSAGE. About 40px on its long side at low quality is
    /// 600 to 900 bytes of JPEG, so it fits inside the message document beside the caption and is on
    /// the recipient's screen the instant the bubble is — no URL, no download, no auto-download
    /// policy to satisfy. That is the whole of the owner's report (2026-08-25): a spinner on an empty
    /// box until the full file lands.
    ///
    /// The reference goes one further and strips the JPEG's header off the wire, rebuilding it on the
    /// phone, which saves a few hundred more bytes. Not copied: sealed and base64'd this is around a
    /// kilobyte either way, and a hand-rebuilt header is a decode failure waiting to happen.
    ///
    /// Rebuilt from raw pixels like every other send path here, so the camera's metadata does not
    /// ride along inside the preview.
    static func inlineThumb(_ data: Data, maxDimension: CGFloat = 40) -> String? {
        guard let img = UIImage(data: data) else { return nil }
        let longest = max(img.size.width, img.size.height)
        guard longest > 0 else { return nil }
        let scale = min(1, maxDimension / longest)
        let size = CGSize(width: max(1, (img.size.width * scale).rounded()),
                          height: max(1, (img.size.height * scale).rounded()))
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1        // 40 POINTS would be 120 pixels on a 3x phone, and three times the bytes
        format.opaque = true    // no alpha channel: this is a JPEG and a photo has no transparency
        let small = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            img.draw(in: CGRect(origin: .zero, size: size))
        }
        return small.jpegData(compressionQuality: 0.45)?.base64EncodedString()
    }

    static func downscaledJPEG(_ data: Data, maxDimension: CGFloat = 1600, quality: CGFloat = 0.72) -> Data {
        // The three `?? data` fallbacks used to hand back the ORIGINAL FILE. Photos are normally
        // rebuilt from raw pixels here, which drops the camera's metadata as a side effect — but on
        // those fallback paths the original went out untouched, GPS coordinates and all, the same
        // leak that video had until this session. Rare (an image UIKit cannot decode, or an encode
        // that fails) is not the same as never, and a privacy promise that holds "almost always" is
        // not a privacy promise. `stripped` is the fallback now.
        guard let img = UIImage(data: data) else { return stripped(data) }
        let longEdge = max(img.size.width, img.size.height)
        let scale = min(1, maxDimension / longEdge)
        if scale >= 1 { return img.jpegData(compressionQuality: quality) ?? stripped(data) }
        let newSize = CGSize(width: (img.size.width * scale).rounded(),
                             height: (img.size.height * scale).rounded())
        // ⛔ SCALE 1, NOT THE SCREEN'S (owner, 2026-10-17). With no format the renderer draws at 3x
        // on a modern phone, so "1600" came out as 4800 pixels and a 4032px photo went up BIGGER
        // than it started. `UIImage(data:)` is scale 1, so `img.size` is already pixels.
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        if let alpha = img.cgImage?.alphaInfo {
            format.opaque = [.none, .noneSkipFirst, .noneSkipLast].contains(alpha)
        }
        let resized = UIGraphicsImageRenderer(size: newSize, format: format).image { _ in
            img.draw(in: CGRect(origin: .zero, size: newSize))
        }
        return resized.jpegData(compressionQuality: quality) ?? stripped(data)
    }

    /// Re-write an image file keeping the pixels and dropping everything else.
    ///
    /// Uses ImageIO rather than UIKit precisely because this runs when UIKit has ALREADY failed —
    /// ImageIO reads formats UIImage will not, which is the case that lands here. Copying an image
    /// source to a destination does not carry the source's metadata dictionary across unless it is
    /// asked to, so the location, the device and the timestamps are gone.
    ///
    /// Returns the original ONLY if the file cannot be read as an image at all, in which case it is
    /// not a photo and there is nothing to leak from.
    private static func stripped(_ data: Data) -> Data {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(src),
              let out = CFDataCreateMutable(nil, 0),
              let dest = CGImageDestinationCreateWithData(out, type, 1, nil) else { return data }
        // An empty properties dictionary, not nil: nil means "carry the source's properties over".
        CGImageDestinationAddImageFromSource(dest, src, 0, [:] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return data }
        return out as Data
    }

    /// HOW MANY UPLOADS MAY RUN AT ONCE inside one album.
    ///
    /// Nothing stops a person selecting thirty photos — the grid draws ten and puts "+20" on the
    /// last tile, which is the right behaviour and stays. But thirty simultaneous uploads on mobile
    /// data do not go faster than ten; they share one pipe and make every one of them slower, which
    /// is the opposite of what releasing them together was for.
    ///
    /// ⚠️ The comment beside the album's task group already asserted "our album caps at ten, so
    /// releasing them together sits inside their number". That was an assumption, not a rule —
    /// nothing enforced it anywhere. This is the rule, so the sentence is now true.
    static let maxAlbumUploadsInFlight = 10

    /// Pixel size WITHOUT decoding the image.
    ///
    /// An album writes its tile aspects before uploading anything, and `UIImage(data:)` on every
    /// picture just to measure them would decode the whole batch twice. `CGImageSource` reads the
    /// header only. The resize that happens later preserves aspect, so these are the same ratios the
    /// finished grid is solved from.
    static func pixelSize(_ data: Data) -> CGSize? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Double,
              let h = props[kCGImagePropertyPixelHeight] as? Double,
              w > 0, h > 0 else { return nil }
        return CGSize(width: w, height: h)
    }

    /// FINISH A MEDIA MESSAGE that was written before its bytes existed.
    ///
    /// Every media send now writes its message the instant Send is tapped, so the recipient sees a
    /// real bubble — the waveform, the file name, the blurred photo — while the upload runs. This is
    /// the second write that attaches the media.
    ///
    /// ⚠️ Clearing `uploading` happens HERE, in the same write as the media, and that pairing is not
    /// tidiness: the firestore.rules branch that permits this update requires both, which is what
    /// makes it usable exactly once on a message still waiting for its bytes, and useless for
    /// editing a delivered one.
    private static func attachMedia(_ fields: [String: Any],
                                    to msgRef: DocumentReference,
                                    conv: [String: Any]? = nil,
                                    convRef: DocumentReference? = nil) async throws {
        var payload = fields
        payload["uploading"] = FieldValue.delete()
        let batch = db.batch()
        batch.updateData(payload, forDocument: msgRef)
        if let conv, let convRef, !conv.isEmpty { batch.updateData(conv, forDocument: convRef) }
        try await batch.commit()
    }

    static func sendImage(cid: String, data rawData: Data, replyTo: ReplyRef? = nil, clientId: String? = nil, group: [String]? = nil, viewOnce: Bool = false, caption: String = "", forwarded: Bool = false) async throws {
        let clientTs = Date().timeIntervalSince1970 * 1000   // captured BEFORE the upload — order is when send was tapped
        let tap = Date(), trace = UploadTrace()             // PHOTO# timings, 2026-10-17
        let data = sendJPEG(rawData)
        var members = await freshGroupMembers(cid, group)   // 2026-09-24 fix-all #111
        if members == nil, !cid.contains("_") { members = try await groupDocMembers(cid) }
        let convRef = db.collection("conversations").document(cid)
        let cipher: Data, meta: EncMeta
        // THE CONVERSATION TOUCH IS NOT A PREREQUISITE OF THE UPLOAD. It only ensures the 1:1 doc
        // carries `users` + `updatedAt`, which the message write needs — not the Storage put. It was
        // awaited inline, so a full round trip stood between the finished ciphertext and the first
        // byte leaving the phone. Started here, awaited just before the batch that actually needs it.
        var ensureConv: Task<Void, Error>?
        if let members {
            (cipher, meta) = try await Crypto.shared.sealBytesForGroup(data, members: members, cid: cid)
        } else {
            (cipher, meta) = try await Crypto.shared.encryptBytes(cid, data)
            let other = cid.split(separator: "_").map(String.init).first { $0 != uid } ?? ""
            ensureConv = Task {
                try await convRef.setData(["users": [uid, other],
                                           "updatedAt": FieldValue.serverTimestamp()], merge: true)
            }
        }
        let encDone = Date()

        let msgRef = convRef.collection("messages").document()

        // THE BYTES GO NOW. Everything below this line — the caption seal, the reply seal, the
        // BlurHash — was computed AFTER the upload returned, and none of it has ever depended on the
        // upload. On a photo with a caption and a reply that is three more seals plus a BlurHash
        // encode (which decodes and downsamples the image again) added onto the end of the slowest
        // step, instead of hidden underneath it. They run together now, so the send costs the upload
        // and not the upload plus the paperwork.
        async let uploadedURL = uploadEncrypted(cipher,
                                                to: "chat/\(cid)/\(msgRef.documentID).enc",
                                                progressId: clientId,
                                                // Where this URL belongs if the app dies before it
                                                // lands — see `PendingUpload`. The photo's own seal
                                                // is already in the message write below, so no enc.
                                                attach: .init(cid: cid, messageId: msgRef.documentID,
                                                              urlField: "imageUrl", enc: nil),
                                                trace: trace)

        // Caption travels INSIDE the image message (the caption is the message body) — sealed
        // exactly like a text message.
        var captionCipher = ""
        let trimmedCaption = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedCaption.isEmpty {
            if let members {
                captionCipher = (try? await Crypto.shared.sealForGroup(trimmedCaption, members: members, cid: cid)) ?? ""
            } else {
                captionCipher = (try? await Crypto.shared.encryptForConversation(cid, trimmedCaption)) ?? ""
            }
        }

        // Encrypt the reply snippet the same way as the conversation (group vs 1:1) —
        // replying to a message WITH a photo, like every standard messenger.
        var replyEnc: [String: Any]?
        if let r = replyTo {
            let rc: Any
            if let members { rc = try await Crypto.shared.sealForGroup(r.text, members: members, cid: cid) }
            else { rc = try await Crypto.shared.encryptForConversation(cid, r.text) }
            replyEnc = ["id": r.id, "authorId": r.authorId, "text": rc]
        }

        // BlurHash: a ~28-char sketch of the photo, sealed like the caption, so the recipient's
        // bubble shows a real blurred preview before any bytes download. Computed here, still
        // alongside the upload, rather than after it.
        let sized = UIImage(data: data)
        var blurSealed: String?
        if !viewOnce, let ui = sized, let hash = BlurHash.encode(ui) {
            blurSealed = members != nil
                ? (try? await Crypto.shared.sealForGroup(hash, members: members!, cid: cid))
                : (try? await Crypto.shared.encryptForConversation(cid, hash))
        }
        // And the real one. Same moment, same seal, same reason as the blurhash above — this is just
        // a picture instead of a sketch of one. A view-once photo publishes neither: both are a copy
        // the recipient would keep after the single view is spent.
        var thumbSealed: String?
        if !viewOnce, let tiny = inlineThumb(data) {
            thumbSealed = members != nil
                ? (try? await Crypto.shared.sealForGroup(tiny, members: members!, cid: cid))
                : (try? await Crypto.shared.encryptForConversation(cid, tiny))
        }

        // ⛔ THE MESSAGE IS WRITTEN ONLY AFTER THE UPLOAD HAS FINISHED — owner, 2026-10-10,
        // reversing 2026-08-16: "do not deliver the image while the upload is in progress; the moment
        // it reaches 100%, deliver it". The reference messengers do the same: the sender sees their
        // photo with its progress ring (the optimistic bubble, unchanged), the recipient gets nothing
        // until the bytes are there, and a Cancel before that point sends nothing at all. The old
        // order put a blurred bubble with a spinner on the recipient's phone during the whole upload.
        try await ensureConv?.value
        let url = try await uploadedURL
        if let clientId { await MediaSend.shared.markItemDone(clientId) }
        // Seed the cache with the plaintext image under its URL so when the optimistic bubble
        // reconciles to the server message, SecureImageView renders instantly (no shimmer / re-download).
        if let ui = UIImage(data: rawData) { DiskImageCache.shared.store(ui, for: url, owned: true) }

        // The LAST moment Cancel can win: after this the message is committed whole.
        try Task.checkCancellation()
        let batch = db.batch()
        var imgMsg: [String: Any] = [
            "type": "image", "enc": meta.asDict, "text": captionCipher, "imageUrl": url,
            "authorId": uid, "createdAt": FieldValue.serverTimestamp(), "clientTs": clientTs,
        ]
        if let replyEnc { imgMsg["replyTo"] = replyEnc }
        if let clientId { imgMsg["clientId"] = clientId }   // reconcile the optimistic bubble
        if viewOnce { imgMsg["viewOnce"] = true }           // view-once photo
        if forwarded { imgMsg["forwarded"] = true }
        if let ui = sized {                                 // natural aspect ratio
            imgMsg["width"] = Double(ui.size.width); imgMsg["height"] = Double(ui.size.height)
        }
        if let blurSealed, !blurSealed.isEmpty { imgMsg["blurhash"] = blurSealed }
        if let thumbSealed, !thumbSealed.isEmpty { imgMsg["thumb"] = thumbSealed }
        batch.setData(imgMsg, forDocument: msgRef)
        // A VIEW-ONCE photo publishes NO thumbnail to the conversation doc (audit): lastImageUrl +
        // lastImageEnc are a decryptable copy both sides keep forever.
        var convUpdate: [String: Any] = [
            "lastMessage": viewOnce ? "View-once photo" : "📷 Photo",
            "lastSender": uid,
            "updatedAt": FieldValue.serverTimestamp(),
        ]
        if !viewOnce { convUpdate["lastImageUrl"] = url; convUpdate["lastImageEnc"] = meta.asDict }
        if let members {
            for m in members where m != uid { convUpdate["unreadCount.\(m)"] = FieldValue.increment(Int64(1)) }
        } else {
            let other = cid.split(separator: "_").map(String.init).first { $0 != uid } ?? ""
            convUpdate["unreadCount.\(other)"] = FieldValue.increment(Int64(1))
        }
        batch.updateData(convUpdate, forDocument: convRef)
        try await batch.commit()

        // Hidden diagnostic (owner, 2026-10-17): ms since the send tap for each step. Sizes and
        // times only. -1 means the step was not seen (the background uploader reports no bytes).
        let m = trace.snapshot
        func ms(_ d: Date?) -> Int { d.map { Int($0.timeIntervalSince(tap) * 1000) } ?? -1 }
        let px = sized.map { "\(Int($0.size.width))x\(Int($0.size.height))" } ?? "?"
        DiagLog.add("PHOTO# raw=\(rawData.count) sent=\(cipher.count) px=\(px) enc=\(ms(encDone)) "
                    + "bytes100=\(ms(m.bytes100)) putOK=\(ms(m.putOK)) url=\(ms(m.url)) "
                    + "commit=\(ms(Date())) attempts=\(m.attempts)")
    }

    /// Send 2+ photos as ONE album message (grid + one caption), as standard messengers do. Each photo is
    /// E2EE'd + uploaded separately; a single message doc carries the array of {imageUrl, enc, w, h}.
    static func sendAlbum(cid: String, images: [Data], caption: String, clientId: String? = nil, group: [String]? = nil) async throws {
        let clientTs = Date().timeIntervalSince1970 * 1000   // captured BEFORE the uploads
        var members = await freshGroupMembers(cid, group)   // 2026-09-24 fix-all #111
        if members == nil, !cid.contains("_") { members = try await groupDocMembers(cid) }
        let convRef = db.collection("conversations").document(cid)
        let msgRef = convRef.collection("messages").document()

        // ONCE, NOT PER ITEM — same note as sendMixedAlbum. This upsert lived inside the loop below,
        // so a ten-photo album wrote the same two fields ten times.
        if members == nil {
            let other = cid.split(separator: "_").map(String.init).first { $0 != uid } ?? ""
            try await convRef.setData(["users": [uid, other], "updatedAt": FieldValue.serverTimestamp()], merge: true)
        }
        // Immutable snapshots for the concurrent tiles: `members` is a `var` and `msgRef` is a
        // Firebase reference, and neither can be captured by them.
        let sealMembers = members
        let msgId = msgRef.documentID

        // Upload + seal every photo (natural aspect kept for the grid). Each item uploads under its
        // own progress key ("clientId#i") — this was the ONE send path that never passed a
        // progressId, which is why an album's ring only ever spun — and in its own child task, so
        // the X on one tile can abort exactly that upload while the rest of the album keeps going.
        //
        // EVERY TILE AT ONCE, AND THIS IS THE PATH THAT MATTERS. ThreadView sends a photos-only
        // album through here and only reaches sendMixedAlbum when a video is in the selection, so
        // this serial loop was the actual cause of "one photo is instant, a group of them you can
        // watch" (owner). The reference app's own ceiling is twelve concurrent uploads and our album
        // caps at ten, so releasing them together sits inside their number.
        //
        // Re-sorted by index afterwards: a task group finishes in whatever order the network feels
        // like, and an album that arrives shuffled is worse than a slow one.
        // ⛔ THE MESSAGE GOES OUT BEFORE THE TILES DO — the last of the five media paths, and the
        // one that gained the most. Every tile had to finish before anything was written, so ONE
        // slow photo held up the whole set and the recipient saw nothing until the last byte of the
        // last picture landed.
        //
        // Aspects are read off the source images first (header only, no decode) so the placeholder
        // grid is solved by the SAME layout, with the SAME ratios, as the album that replaces it.

        let tileWork: Task<[AlbumTile], Error> = Task { try await withThrowingTaskGroup(of: AlbumTile?.self) { group in
            // BOUNDED. Start at most `maxAlbumUploadsInFlight`, then add one more each time a tile
            // finishes, so a thirty-photo album still uploads ten at a time instead of thirty.
            var started = 0
            func startTile(_ i: Int) {
                let raw = images[i]
                group.addTask {
                    // A whole-message Cancel cancels the group; each tile lands on it here.
                    try Task.checkCancellation()
                    let itemKey = clientId.map { MediaSend.itemKey($0, i) }
                    if let itemKey, await MediaSend.shared.isItemCancelled(itemKey) { return nil }
                    let data = sendJPEG(raw)
                    let cipher: Data, meta: EncMeta
                    if let sealMembers { (cipher, meta) = try await Crypto.shared.sealBytesForGroup(data, members: sealMembers, cid: cid) }
                    else { (cipher, meta) = try await Crypto.shared.encryptBytes(cid, data) }
                    let path = "chat/\(cid)/\(msgId)-\(i).enc"
                    let up: Task<String, Error> = Task { try await uploadEncrypted(cipher, to: path, progressId: itemKey) }
                    if let itemKey { await MediaSend.shared.registerItem(itemKey, up) }
                    let url: String
                    do {
                        url = try await up.value
                        if let itemKey {
                            await MediaSend.shared.finishItem(itemKey)
                            await MediaSend.shared.markItemDone(itemKey)   // this tile's ring comes off NOW
                        }
                    } catch {
                        // THIS tile's X: skip the item, the album goes on without it. Any other failure
                        // (or a whole-message Cancel, which cancels item tasks too) fails the send.
                        if let itemKey, await MediaSend.shared.isItemCancelled(itemKey) { return nil }
                        throw error
                    }
                    // The X can land in the instant the upload completes — honour it even then.
                    if let itemKey, await MediaSend.shared.isItemCancelled(itemKey) { return nil }
                    if let ui = UIImage(data: raw) { DiskImageCache.shared.store(ui, for: url, owned: true) }   // instant reconcile
                    let sz = UIImage(data: data)?.size ?? CGSize(width: 1, height: 1)
                    return AlbumTile(index: i, imageUrl: url, imageEnc: meta,
                                     width: Double(sz.width), height: Double(sz.height),
                                     videoUrl: nil, videoEnc: nil, duration: 0)
                }
                started += 1
            }
            // Prime the pipe, then top it up as each one lands.
            while started < images.count && started < maxAlbumUploadsInFlight { startTile(started) }
            var acc: [AlbumTile] = []
            for try await tile in group {
                if let tile { acc.append(tile) }
                if started < images.count { startTile(started) }
            }
            return acc.sorted { $0.index < $1.index }
        } }

        // Caption sealed like a text body (one body for the album).
        var captionCipher = ""
        let trimmed = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            if let members { captionCipher = (try? await Crypto.shared.sealForGroup(trimmed, members: members, cid: cid)) ?? "" }
            else { captionCipher = (try? await Crypto.shared.encryptForConversation(cid, trimmed)) ?? "" }
        }

        // Owner, 2026-10-10: the album reaches the recipient only once EVERY photo has uploaded
        // (see sendImage). Cancelled tiles drop out; all cancelled = nothing is sent at all.
        let tiles = try await tileWork.value
        let items: [[String: Any]] = tiles.map {
            ["imageUrl": $0.imageUrl, "enc": $0.imageEnc.asDict, "width": $0.width, "height": $0.height]
        }
        guard !items.isEmpty else { throw CancellationError() }

        let batch = db.batch()
        var msg: [String: Any] = [
            "type": "album", "albumSizes": tiles.map { [$0.width, $0.height] }, "text": captionCipher, "album": items,
            "authorId": uid, "createdAt": FieldValue.serverTimestamp(), "clientTs": clientTs,
        ]
        // The album's FIRST tile, blurred, for the same reason a photo and now a video carry one:
        // without it the grid falls through to the grey shimmer while its bytes arrive. One hash for
        // the message, matching the model, which holds a single `blurhash` per message.
        if let firstData = images.first, let ui = UIImage(data: firstData), let hash = BlurHash.encode(ui) {
            let sealed = members != nil
                ? (try? await Crypto.shared.sealForGroup(hash, members: members!, cid: cid))
                : (try? await Crypto.shared.encryptForConversation(cid, hash))
            if let sealed, !sealed.isEmpty { msg["blurhash"] = sealed }
        }
        // The same first tile as a real picture instead of a sketch — one per message, matching the
        // model, and drawn on the grid's first cell while every tile's bytes are still coming.
        if let firstData = images.first, let tiny = inlineThumb(firstData) {
            let sealed = members != nil
                ? (try? await Crypto.shared.sealForGroup(tiny, members: members!, cid: cid))
                : (try? await Crypto.shared.encryptForConversation(cid, tiny))
            if let sealed, !sealed.isEmpty { msg["thumb"] = sealed }
        }
        if let clientId { msg["clientId"] = clientId }
        // The LAST moment Cancel can win. Without this, a Cancel that lands while the caption is
        // being sealed still commits, and the album he cancelled appears a minute later anyway.
        try Task.checkCancellation()
        batch.setData(msg, forDocument: msgRef)
        var convUpdate: [String: Any] = [
            "lastMessage": items.count == 1 ? "📷 Photo" : "📷 \(items.count) Photos", "lastSender": uid,
            "updatedAt": FieldValue.serverTimestamp(),
        ]
        if let first = items.first, let u = first["imageUrl"], let e = first["enc"] {
            convUpdate["lastImageUrl"] = u
            convUpdate["lastImageEnc"] = e
        }
        if items.count > 1 {
            convUpdate["lastImages"] = items.prefix(3).map { ["imageUrl": $0["imageUrl"] as Any, "enc": $0["enc"] as Any] }
        }
        if let members { for m in members where m != uid { convUpdate["unreadCount.\(m)"] = FieldValue.increment(Int64(1)) } }
        else {
            let other = cid.split(separator: "_").map(String.init).first { $0 != uid } ?? ""
            convUpdate["unreadCount.\(other)"] = FieldValue.increment(Int64(1))
        }
        batch.updateData(convUpdate, forDocument: convRef)
        try await batch.commit()
    }

    // One item to send inside a MIXED album (photos + videos in ONE message group).
    enum AlbumSendItem {
        case image(Data)                                                        // jpeg bytes
        case video(Data, thumbnail: Data, duration: Double, width: Double, height: Double)  // mp4 + poster
    }

    /// Send images AND videos together as ONE album message (standard mixed grouping). Every
    /// item is E2EE'd + uploaded independently, then a single doc carries the mixed array; videos
    /// store {kind:"video", imageUrl=poster, videoUrl, videoEnc, duration}. One caption, one timestamp,
    /// one delivery status — the group never splits into separate messages.
    /// One finished album tile, in a shape a task group can hand back.
    ///
    /// Deliberately NOT the `[String: Any]` the message actually carries: a dictionary of `Any` is
    /// not Sendable, so building it inside the group would not compile. The dictionaries are
    /// assembled from these afterwards, in index order.
    private struct AlbumTile: Sendable {
        let index: Int
        let imageUrl: String
        let imageEnc: EncMeta
        let width: Double
        let height: Double
        /// Present only on a video tile; a photo tile leaves all three nil/zero.
        let videoUrl: String?
        let videoEnc: EncMeta?
        let duration: Double
    }

    static func sendMixedAlbum(cid: String, items: [AlbumSendItem], caption: String,
                               clientId: String? = nil, group: [String]? = nil, forwarded: Bool = false) async throws {
        let clientTs = Date().timeIntervalSince1970 * 1000   // captured BEFORE the uploads
        var members = await freshGroupMembers(cid, group)   // 2026-09-24 fix-all #111
        if members == nil, !cid.contains("_") { members = try await groupDocMembers(cid) }
        let convRef = db.collection("conversations").document(cid)
        let msgRef = convRef.collection("messages").document()

        // ONCE, NOT PER ITEM. This upsert used to live inside `seal`, which is called for every tile
        // in the album — so a ten-photo album made ten identical writes of the same two fields, and
        // a video tile made two of them by itself (poster, then clip). It has nothing to do with the
        // bytes being sealed; it is the 1:1 conversation existing, which is true once for the album.
        if members == nil {
            let other = cid.split(separator: "_").map(String.init).first { $0 != uid } ?? ""
            try await convRef.setData(["users": [uid, other], "updatedAt": FieldValue.serverTimestamp()], merge: true)
        }

        // IMMUTABLE SNAPSHOTS, taken before the tiles below start running together. `members` is a
        // `var` and `msgRef` is a Firebase reference; neither can be captured by the concurrent
        // closures. Everything the tiles need is a plain value from here on.
        let sealMembers = members
        let msgId = msgRef.documentID

        @Sendable func seal(_ data: Data) async throws -> (Data, EncMeta) {
            if let sealMembers { return try await Crypto.shared.sealBytesForGroup(data, members: sealMembers, cid: cid) }
            return try await Crypto.shared.encryptBytes(cid, data)
        }

        // Per-item progress keys and per-item cancellable uploads, exactly as sendAlbum does them —
        // see the note there. A video item's poster is quick and unkeyed; the clip itself carries
        // the item's progress key, so the tile's ring fills with the part that takes the time.
        // EVERY TILE AT ONCE. This was a plain `for` loop — seal, upload, wait, next — so a five-photo
        // album made five transfers end to end while a single photo (one transfer) looked instant.
        // That is exactly what the owner saw: "single photo you can't catch the ring, a group you
        // can". Nothing in the loop ever depended on the tile before it. The FORWARD path in this
        // same file was parallelised for this reason and says so; sending was never given the same
        // treatment.
        //
        // Indexed and re-sorted afterwards, because a task group finishes in whatever order the
        // network feels like and an album that arrives shuffled is worse than a slow one — the same
        // rule the forward path already follows.
        //
        // Cancellation is unchanged in meaning: a tile that was X'd returns nil and is dropped, and
        // anything that throws cancels its siblings and propagates, so a partial album still cannot
        // be delivered.
        let tiles: [AlbumTile] = try await withThrowingTaskGroup(of: AlbumTile?.self) { group in
            for (i, item) in items.enumerated() {
                group.addTask {
                    try Task.checkCancellation()
                    let itemKey = clientId.map { MediaSend.itemKey($0, i) }
                    if let itemKey, await MediaSend.shared.isItemCancelled(itemKey) { return nil }
                    /// One upload as a child task filed under this item's key, so the tile's X can abort
                    /// exactly this transfer. Returns nil when the item was X'd (skip it); rethrows all else.
                    func uploadItem(_ cipher: Data, _ suffix: String, keyed: Bool) async throws -> String? {
                        let up: Task<String, Error> = Task {
                            try await uploadEncrypted(cipher, to: "chat/\(cid)/\(msgId)-\(suffix).enc",
                                                      progressId: keyed ? itemKey : nil)
                        }
                        if let itemKey { await MediaSend.shared.registerItem(itemKey, up) }
                        do {
                            let url = try await up.value
                            if let itemKey { await MediaSend.shared.finishItem(itemKey) }
                            // Done = the KEYED transfer only. A video item uploads its poster first through
                            // this same func with keyed=false — marking that would kill the ring before the
                            // clip, the part the ring is FOR, had sent its first byte.
                            if keyed, let itemKey { await MediaSend.shared.markItemDone(itemKey) }
                            if let itemKey, await MediaSend.shared.isItemCancelled(itemKey) { return nil }
                            return url
                        } catch {
                            if let itemKey, await MediaSend.shared.isItemCancelled(itemKey) { return nil }
                            throw error
                        }
                    }
                    switch item {
                    case .image(let raw):
                        let data = sendJPEG(raw)
                        let (cipher, meta) = try await seal(data)
                        guard let url = try await uploadItem(cipher, "\(i)", keyed: true) else { return nil }
                        if let ui = UIImage(data: raw) { DiskImageCache.shared.store(ui, for: url, owned: true) }
                        let sz = UIImage(data: data)?.size ?? CGSize(width: 1, height: 1)
                        return AlbumTile(index: i, imageUrl: url, imageEnc: meta,
                                         width: Double(sz.width), height: Double(sz.height),
                                         videoUrl: nil, videoEnc: nil, duration: 0)
                    case .video(let mp4, let thumb, let duration, let w, let h):
                        // Poster thumbnail (shown in the grid) + the encrypted video clip.
                        let thumbJpeg = downscaledJPEG(thumb)
                        let (thumbCipher, thumbMeta) = try await seal(thumbJpeg)
                        guard let thumbUrl = try await uploadItem(thumbCipher, "\(i)-thumb", keyed: false) else { return nil }
                        if let ui = UIImage(data: thumb) { DiskImageCache.shared.store(ui, for: thumbUrl, owned: true) }
                        let (vidCipher, vidMeta) = try await seal(mp4)
                        guard let vidUrl = try await uploadItem(vidCipher, "\(i)-video", keyed: true) else { return nil }
                        // KEEP THE SENDER'S OWN COPY, like sendVideo does (audit). The mailman model has the
                        // recipient DELETE the server object once they've watched it, which is only safe
                        // because the sender kept a local copy — sendVideo stores one, this path did not, so
                        // the sender's own album video 404'd forever after the other side pressed play (and
                        // forwarding that album failed for good). Keyed by the synthetic album-child id the
                        // viewer and cache use: "<parentId>-<index>".
                        guard VideoCache.store(mp4, for: "\(msgId)-\(i)") else { throw VideoCache.NoRoomError() }
                        return AlbumTile(index: i, imageUrl: thumbUrl, imageEnc: thumbMeta,
                                         width: w, height: h,
                                         videoUrl: vidUrl, videoEnc: vidMeta, duration: duration)
                    }
                }
            }
            var acc: [AlbumTile] = []
            for try await tile in group { if let tile { acc.append(tile) } }
            return acc
        }
        .sorted { $0.index < $1.index }

        // The dictionaries, built here rather than in the group, because `[String: Any]` is not
        // Sendable. Order is the album's own order, restored by the sort above.
        let out: [[String: Any]] = tiles.map { t in
            guard let vurl = t.videoUrl, let venc = t.videoEnc else {
                return ["kind": "image", "imageUrl": t.imageUrl, "enc": t.imageEnc.asDict,
                        "width": t.width, "height": t.height]
            }
            return ["kind": "video", "imageUrl": t.imageUrl, "enc": t.imageEnc.asDict,
                    "videoUrl": vurl, "videoEnc": venc.asDict, "duration": t.duration,
                    "width": t.width, "height": t.height]
        }
        let videoCount = tiles.filter { $0.videoUrl != nil }.count
        let photoCount = tiles.count - videoCount

        // Every tile was X'd → there is no album left to send.
        guard !out.isEmpty else { throw CancellationError() }

        var captionCipher = ""
        let trimmed = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            if let members { captionCipher = (try? await Crypto.shared.sealForGroup(trimmed, members: members, cid: cid)) ?? "" }
            else { captionCipher = (try? await Crypto.shared.encryptForConversation(cid, trimmed)) ?? "" }
        }

        let batch = db.batch()
        var msg: [String: Any] = [
            "type": "album", "album": out, "text": captionCipher,
            "authorId": uid, "createdAt": FieldValue.serverTimestamp(), "clientTs": clientTs,
        ]
        // The album's FIRST tile, blurred, for the same reason a photo and now a video carry one:
        // without it the grid falls through to the grey shimmer while its bytes arrive. One hash for
        // the message, matching the model, which holds a single `blurhash` per message.
        let firstTile: Data? = items.first.flatMap { item in
            switch item {
            case .image(let d): return d
            case .video(_, let thumbnail, _, _, _): return thumbnail
            }
        }
        if let firstTile, let ui = UIImage(data: firstTile), let hash = BlurHash.encode(ui) {
            let sealed = members != nil
                ? (try? await Crypto.shared.sealForGroup(hash, members: members!, cid: cid))
                : (try? await Crypto.shared.encryptForConversation(cid, hash))
            if let sealed, !sealed.isEmpty { msg["blurhash"] = sealed }
        }
        // And as a picture. `firstTile` is already a photo or a video's poster, so one call covers
        // a mixed album the same way the hash above does.
        if let firstTile, let tiny = inlineThumb(firstTile) {
            let sealed = members != nil
                ? (try? await Crypto.shared.sealForGroup(tiny, members: members!, cid: cid))
                : (try? await Crypto.shared.encryptForConversation(cid, tiny))
            if let sealed, !sealed.isEmpty { msg["thumb"] = sealed }
        }
        if let clientId { msg["clientId"] = clientId }
        if forwarded { msg["forwarded"] = true }
        // The LAST moment Cancel can win — same line, same reason as sendAlbum's.
        try Task.checkCancellation()
        batch.setData(msg, forDocument: msgRef)
        // Chat-list preview: describe the mix (counts reflect what actually shipped, X'd tiles out).
        let preview: String = {
            if videoCount > 0 && photoCount > 0 { return "🎬 \(out.count) Media" }
            if videoCount > 0 { return "🎥 \(videoCount) Video\(videoCount > 1 ? "s" : "")" }
            return "📷 \(photoCount) Photos"
        }()
        var convUpdate: [String: Any] = [
            "lastMessage": preview, "lastSender": uid, "updatedAt": FieldValue.serverTimestamp(),
        ]
        // Refresh the chat-list thumbnail (photo parity with sendImage): first image in the mix,
        // else the first video's poster — both carry {imageUrl, enc}, which is all the list needs.
        if let firstThumb = out.first(where: { ($0["kind"] as? String) == "image" }) ?? out.first,
           let u = firstThumb["imageUrl"], let e = firstThumb["enc"] {
            convUpdate["lastImageUrl"] = u
            convUpdate["lastImageEnc"] = e
            // The list's overlapped stack (owner, 2026-10-04): that same first picture, then the
            // next ones, 3 at most. Only the cover pictures: {imageUrl, enc}, nothing playable.
            let rest = out.filter { ($0["imageUrl"] as? String) != (u as? String) }
            convUpdate["lastImages"] = ([firstThumb] + rest).prefix(3).compactMap { t -> [String: Any]? in
                guard let tu = t["imageUrl"], let te = t["enc"] else { return nil }
                return ["imageUrl": tu, "enc": te]
            }
        }
        if let members { for m in members where m != uid { convUpdate["unreadCount.\(m)"] = FieldValue.increment(Int64(1)) } }
        else {
            let other = cid.split(separator: "_").map(String.init).first { $0 != uid } ?? ""
            convUpdate["unreadCount.\(other)"] = FieldValue.increment(Int64(1))
        }
        batch.updateData(convUpdate, forDocument: convRef)
        try await batch.commit()
    }

    /// Encrypt + send a voice note. Same E2EE pipeline as photos: the m4a bytes
    /// are sealed and the ciphertext uploaded; the server never hears the audio.
    static func sendAudio(cid: String, data: Data, duration: Double, waveform: [Int] = [], replyTo: ReplyRef? = nil, clientId: String? = nil, group: [String]? = nil, forwarded: Bool = false, viewOnce: Bool = false) async throws {
        let clientTs = Date().timeIntervalSince1970 * 1000   // captured BEFORE the upload
        var members = await freshGroupMembers(cid, group)   // 2026-09-24 fix-all #111
        if members == nil, !cid.contains("_") { members = try await groupDocMembers(cid) }
        let convRef = db.collection("conversations").document(cid)
        let cipher: Data, meta: EncMeta
        if let members {
            (cipher, meta) = try await Crypto.shared.sealBytesForGroup(data, members: members, cid: cid)
        } else {
            (cipher, meta) = try await Crypto.shared.encryptBytes(cid, data)
            let other = cid.split(separator: "_").map(String.init).first { $0 != uid } ?? ""
            try await convRef.setData(["users": [uid, other], "updatedAt": FieldValue.serverTimestamp()], merge: true)
        }

        let msgRef = convRef.collection("messages").document()
        // Persist the plaintext I just recorded so playing my OWN note NEVER downloads+decrypts (the
        // "loading" spin). Store under BOTH keys the bubble can be identified by: the FINAL message id
        // (== the server doc id the reconciled bubble carries) AND the clientId (the optimistic bubble,
        // and a belt in case reconcile timing differs). VoiceMessageView.load() checks both.
        // NOT for a one-time note: the sender's pill is inert (senders cannot replay, same rule as
        // the view-once photo), so caching our own plaintext would be a copy nobody can reach kept
        // for no one.
        if !viewOnce {
            AudioCache.store(data, for: msgRef.documentID)
            if let clientId { AudioCache.store(data, for: clientId) }
        }
        // ⛔ UPLOAD STARTED, NOT AWAITED. The message goes out first — see the note in sendImage.
        // A voice note is the one that matters most here: it is the main way this app is used, and
        // the recipient can be shown a REAL voice bubble immediately, with the true waveform and the
        // true length, because both are computed on the recorder before a byte is uploaded.
        async let uploadedURL = uploadEncrypted(cipher, to: "chat/\(cid)/\(msgRef.documentID).m4a.enc",
                                                progressId: clientId,
                                                attach: .init(cid: cid, messageId: msgRef.documentID,
                                                              urlField: "audioUrl", enc: nil))

        // Encrypt the reply snippet the same way as the conversation (group vs 1:1).
        var replyEnc: [String: Any]?
        if let r = replyTo {
            let rc: Any
            if let members { rc = try await Crypto.shared.sealForGroup(r.text, members: members, cid: cid) }
            else { rc = try await Crypto.shared.encryptForConversation(cid, r.text) }
            replyEnc = ["id": r.id, "authorId": r.authorId, "text": rc]
        }

        let batch = db.batch()
        var msg: [String: Any] = [
            // A one-time note carries NO waveform, the same instinct as the view-once photo
            // skipping its blurhash: the preview machinery must not keep a shape of something
            // meant to exist for one listen.
            "type": "audio", "duration": duration, "waveform": viewOnce ? [] : waveform,
            "enc": meta.asDict, "text": "", "authorId": uid, "createdAt": FieldValue.serverTimestamp(),
            "clientTs": clientTs, "uploading": true,
        ]
        if let clientId { msg["clientId"] = clientId }   // reconcile the optimistic bubble in place
        if let replyEnc { msg["replyTo"] = replyEnc }    // voice notes can be replies too (Bug 1)
        if forwarded { msg["forwarded"] = true }
        if viewOnce { msg["viewOnce"] = true }           // one-time voice (same field the photo uses)
        batch.setData(msg, forDocument: msgRef)
        var convUpdate: [String: Any] = [
            // Length rides inside the marker ("🎤 Voice message · 0:53") so the chat list
            // can show it without a schema change; old plain markers still parse (prefix match).
            "lastMessage": viewOnce ? "🎤 One-time voice message"
                                    : "🎤 Voice message · " + voiceDurationLabel(duration),
            "lastSender": uid,
            "updatedAt": FieldValue.serverTimestamp(),
        ]
        if let members {
            for m in members where m != uid { convUpdate["unreadCount.\(m)"] = FieldValue.increment(Int64(1)) }
        } else {
            let other = cid.split(separator: "_").map(String.init).first { $0 != uid } ?? ""
            convUpdate["unreadCount.\(other)"] = FieldValue.increment(Int64(1))
        }
        batch.updateData(convUpdate, forDocument: convRef)
        try await batch.commit()

        // Now the audio itself; the bubble has been on their screen since before this line.
        let url = try await uploadedURL
        try await attachMedia(["audioUrl": url], to: msgRef)
    }

    /// Encrypt + send a VIDEO message. Same E2EE pipeline as photos: the transcoded mp4
    /// AND its thumbnail are sealed separately; the server stores only ciphertext. The
    /// thumbnail rides on the message (and the chat-list preview) so bubbles render
    /// instantly without downloading the video.
    /// PHASE ONE OF A VIDEO SEND: the message, written before the clip it describes even exists.
    ///
    /// ⛔ WHY THIS IS SPLIT OFF FROM `sendVideo` (owner, 2026-08-25: "when someone sends something I
    /// see nothing until it downloads"). A video is TRANSCODED before it can be sent, and he timed
    /// that at 3.88 seconds on an eighteen second clip. `sendVideo` cannot be called until the
    /// transcode finishes, so for those seconds the RECIPIENT had nothing whatsoever — no bubble, no
    /// poster, no progress. The sender's own optimistic bubble hid that from the person sending.
    ///
    /// Everything the recipient needs to draw the real bubble exists BEFORE the transcode starts: the
    /// poster frame, the duration, the pixel size, the caption, the inline thumbnail. So it all goes
    /// out here, and `attachVideo` hangs the clip on it afterwards. That is the same two-phase shape
    /// `sendImage` has used since 2026-08-16, through the same rules branch.
    ///
    /// ⚠️ THE MESSAGE HAS NO `enc` UNTIL PHASE TWO. `enc` on a video message is the CLIP's seal, and
    /// there is no clip yet. `pendingMediaKind` keys on a missing `videoUrl`, not on `enc`, so the
    /// bubble is correct in the gap.
    ///
    /// Returns the message id, which `attachVideo` needs. A send that dies between the two phases
    /// must call `cancelAnnounced`, or the recipient is left with a bubble that never fills.
    static func announceVideo(cid: String, poster: Data, duration: Double, width: Double, height: Double,
                              caption: String = "", clientId: String? = nil, group: [String]? = nil,
                              forwarded: Bool = false) async throws -> String {
        let clientTs = Date().timeIntervalSince1970 * 1000   // when SEND was tapped, not when it landed
        var members = await freshGroupMembers(cid, group)   // 2026-09-24 fix-all #111
        if members == nil, !cid.contains("_") { members = try await groupDocMembers(cid) }
        var captionCipher = ""
        let trimmedCaption = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedCaption.isEmpty {
            if let m = members { captionCipher = (try? await Crypto.shared.sealForGroup(trimmedCaption, members: m, cid: cid)) ?? "" }
            else { captionCipher = (try? await Crypto.shared.encryptForConversation(cid, trimmedCaption)) ?? "" }
        }
        let convRef = db.collection("conversations").document(cid)
        let msgRef = convRef.collection("messages").document()
        var ensureConv: Task<Void, Error>?
        let thCipher: Data, thMeta: EncMeta
        if let members {
            (thCipher, thMeta) = try await Crypto.shared.sealBytesForGroup(poster, members: members, cid: cid)
        } else {
            (thCipher, thMeta) = try await Crypto.shared.encryptBytes(cid, poster)
            let other = cid.split(separator: "_").map(String.init).first { $0 != uid } ?? ""
            ensureConv = Task {
                try await convRef.setData(["users": [uid, other],
                                           "updatedAt": FieldValue.serverTimestamp()], merge: true)
            }
        }
        // The poster is a few KB and it is the only upload standing between the tap and the bubble
        // appearing on the other phone. The clip, which is the slow one, has not even been compressed
        // yet — that runs while this is in flight.
        let thumbUrl = try await uploadEncrypted(thCipher, to: "chat/\(cid)/\(msgRef.documentID).thumb.enc")
        try await ensureConv?.value
        // Seed the cache so the sender's optimistic bubble reconciles with no shimmer (photo parity).
        if let ui = UIImage(data: poster) { DiskImageCache.shared.store(ui, for: thumbUrl, owned: true) }

        var msg: [String: Any] = [
            "type": "video",
            "thumbUrl": thumbUrl, "thumbEnc": thMeta.asDict,
            "duration": duration, "width": width, "height": height,
            "text": captionCipher, "authorId": uid, "createdAt": FieldValue.serverTimestamp(),
            "clientTs": clientTs, "uploading": true,
        ]
        if let posterImage = UIImage(data: poster), let hash = BlurHash.encode(posterImage) {
            let sealed = members != nil
                ? (try? await Crypto.shared.sealForGroup(hash, members: members!, cid: cid))
                : (try? await Crypto.shared.encryptForConversation(cid, hash))
            if let sealed, !sealed.isEmpty { msg["blurhash"] = sealed }
        }
        // The picture that needs no download at all — see `inlineThumb`. It matters most here: even
        // the poster above has to be fetched before it can be drawn, and this does not.
        if let tiny = inlineThumb(poster) {
            let sealed = members != nil
                ? (try? await Crypto.shared.sealForGroup(tiny, members: members!, cid: cid))
                : (try? await Crypto.shared.encryptForConversation(cid, tiny))
            if let sealed, !sealed.isEmpty { msg["thumb"] = sealed }
        }
        if let clientId { msg["clientId"] = clientId }
        if forwarded { msg["forwarded"] = true }

        let batch = db.batch()
        batch.setData(msg, forDocument: msgRef)
        var convUpdate: [String: Any] = [
            "lastMessage": "🎥 Video · " + voiceDurationLabel(duration),
            "lastImageUrl": thumbUrl,
            "lastImageEnc": thMeta.asDict,
            "lastSender": uid,
            "updatedAt": FieldValue.serverTimestamp(),
        ]
        if let members {
            for m in members where m != uid { convUpdate["unreadCount.\(m)"] = FieldValue.increment(Int64(1)) }
        } else {
            let other = cid.split(separator: "_").map(String.init).first { $0 != uid } ?? ""
            convUpdate["unreadCount.\(other)"] = FieldValue.increment(Int64(1))
        }
        batch.updateData(convUpdate, forDocument: convRef)
        try await batch.commit()
        return msgRef.documentID
    }

    /// PHASE TWO: the clip itself, sealed and uploaded, hung on the message `announceVideo` wrote.
    /// The recipient has been looking at that bubble, with its real picture in it, for the whole of
    /// the transcode and this upload.
    static func attachVideo(cid: String, messageId: String, video: Data,
                            clientId: String? = nil, group: [String]? = nil) async throws {
        var members = await freshGroupMembers(cid, group)   // 2026-09-24 fix-all #111
        if members == nil, !cid.contains("_") { members = try await groupDocMembers(cid) }
        let msgRef = db.collection("conversations").document(cid).collection("messages").document(messageId)
        // Mailman model: the SENDER's copy lives on their own device from day one — the server object
        // exists only to deliver, and the recipient deletes it on pickup. Stored before the upload so
        // it survives a send that never completes. If it did not land, stop here: delivering a clip
        // the recipient will delete on pickup, with no copy on this phone, loses it for good.
        guard VideoCache.store(video, for: messageId) else { throw VideoCache.NoRoomError() }
        let cipher: Data, meta: EncMeta
        if let members {
            (cipher, meta) = try await Crypto.shared.sealBytesForGroup(video, members: members, cid: cid)
        } else {
            (cipher, meta) = try await Crypto.shared.encryptBytes(cid, video)
        }
        let url = try await uploadEncrypted(cipher, to: "chat/\(cid)/\(messageId).mp4.enc",
                                            progressId: clientId,
                                            // ⚠️ `enc` RIDES ALONG HERE and nowhere else: a video's
                                            // clip is sealed separately from its poster, so phase
                                            // one had nothing to write. A resume must carry both or
                                            // the clip arrives undecryptable.
                                            attach: .init(cid: cid, messageId: messageId,
                                                          urlField: "videoUrl", enc: meta))
        // The clip has landed — the ring comes off here rather than when the message commits, the
        // same reasoning the photo path spells out.
        if let clientId { await MediaSend.shared.markItemDone(clientId) }
        // `enc` rides along because phase one had no clip to seal. The rules' finish-an-upload branch
        // names both fields.
        try await attachMedia(["videoUrl": url, "enc": meta.asDict], to: msgRef)
    }

    /// A video announced but never delivered — the transcode failed, the clip was over the limit, the
    /// upload died. Without this the recipient keeps a bubble that spins for ever. Hard delete, which
    /// the rules allow the author of a message to do; the conversation row is left alone because the
    /// next message rewrites it anyway.
    static func cancelAnnounced(cid: String, messageId: String) async {
        try? await db.collection("conversations").document(cid)
            .collection("messages").document(messageId).delete()
    }

    static func sendVideo(cid: String, video: Data, thumbnail: Data, duration: Double,
                          width: Double, height: Double, caption: String = "", clientId: String? = nil, group: [String]? = nil, forwarded: Bool = false) async throws {
        let clientTs = Date().timeIntervalSince1970 * 1000   // captured BEFORE the upload
        var members = await freshGroupMembers(cid, group)   // 2026-09-24 fix-all #111
        if members == nil, !cid.contains("_") { members = try await groupDocMembers(cid) }
        // Caption travels INSIDE the video message (sealed like a text message), same as images.
        var captionCipher = ""
        let trimmedCaption = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedCaption.isEmpty {
            if let m = members { captionCipher = (try? await Crypto.shared.sealForGroup(trimmedCaption, members: m, cid: cid)) ?? "" }
            else { captionCipher = (try? await Crypto.shared.encryptForConversation(cid, trimmedCaption)) ?? "" }
        }
        let convRef = db.collection("conversations").document(cid)
        let vidCipher: Data, vidMeta: EncMeta, thCipher: Data, thMeta: EncMeta
        // Same as sendImage: the conversation touch is a prerequisite of the MESSAGE write, not of
        // the uploads, so it no longer stands in front of them.
        var ensureConv: Task<Void, Error>?
        if let members {
            (vidCipher, vidMeta) = try await Crypto.shared.sealBytesForGroup(video, members: members, cid: cid)
            (thCipher, thMeta) = try await Crypto.shared.sealBytesForGroup(thumbnail, members: members, cid: cid)
        } else {
            (vidCipher, vidMeta) = try await Crypto.shared.encryptBytes(cid, video)
            (thCipher, thMeta) = try await Crypto.shared.encryptBytes(cid, thumbnail)
            let other = cid.split(separator: "_").map(String.init).first { $0 != uid } ?? ""
            ensureConv = Task {
                try await convRef.setData(["users": [uid, other],
                                           "updatedAt": FieldValue.serverTimestamp()], merge: true)
            }
        }
        let msgRef = convRef.collection("messages").document()
        // THE CLIP AND ITS POSTER GO TOGETHER NOW, and this reverses a deliberate decision, so the
        // reasoning is on the record. They were serial so that a failed clip would not have already
        // spent the user's data on a poster for a video that never arrives. But the poster is, by
        // that same comment's own admission, a few KB — while the round trip it costs is paid on
        // EVERY successful send. Trading a few wasted KB on the rare failure for a whole round trip
        // saved on every success is the right way round.
        //
        // Progress still reports the clip alone: the poster is too small to do anything but make the
        // ring jump, which was the other half of the original reasoning and still holds.
        async let videoUp = uploadEncrypted(vidCipher, to: "chat/\(cid)/\(msgRef.documentID).mp4.enc",
                                            progressId: clientId,
                                            // The same descriptor `attachVideo` carries. This path
                                            // is the one forwarding and retry take, and leaving it
                                            // out would mean a forwarded video is the only send that
                                            // cannot survive the app being killed. `enc` rides along
                                            // for the reason written there: a clip is sealed apart
                                            // from its poster.
                                            attach: .init(cid: cid, messageId: msgRef.documentID,
                                                          urlField: "videoUrl", enc: vidMeta))
        async let thumbUp = uploadEncrypted(thCipher, to: "chat/\(cid)/\(msgRef.documentID).thumb.enc")
        // ⛔ ONLY THE POSTER IS AWAITED HERE. The video keeps uploading while the message goes out.
        //
        // This is the best case of the lot: the thumbnail is a fraction of the clip, so the
        // recipient gets the REAL first frame, the true duration and the right bubble size
        // immediately, and only pressing play has to wait. Before this they had nothing at all
        // until an entire video had uploaded.
        let thumbUrl = try await thumbUp
        try await ensureConv?.value
        // Seed the cache so the optimistic bubble reconciles with no shimmer (photo parity).
        if let ui = UIImage(data: thumbnail) { DiskImageCache.shared.store(ui, for: thumbUrl, owned: true) }

        let batch = db.batch()
        var msg: [String: Any] = [
            "type": "video", "enc": vidMeta.asDict,
            "thumbUrl": thumbUrl, "thumbEnc": thMeta.asDict,
            "duration": duration, "width": width, "height": height,
            "text": captionCipher, "authorId": uid, "createdAt": FieldValue.serverTimestamp(),
            "clientTs": clientTs, "uploading": true,
        ]
        // A BLURRED SKETCH OF THE POSTER, the same one a photo has carried since it was added.
        //
        // Only `sendImage` ever computed one, so a received VIDEO had nothing to draw and fell all
        // the way through to the grey shimmer — which is the placeholder the owner photographed and
        // asked to be rid of. It is ~28 characters, it is sealed like the caption, and the poster it
        // is made from is already in hand here, so it costs one encode and no extra bytes worth
        // counting.
        if let poster = UIImage(data: thumbnail), let hash = BlurHash.encode(poster) {
            let sealed = members != nil
                ? (try? await Crypto.shared.sealForGroup(hash, members: members!, cid: cid))
                : (try? await Crypto.shared.encryptForConversation(cid, hash))
            if let sealed, !sealed.isEmpty { msg["blurhash"] = sealed }
        }
        // And the inline thumbnail, from that same poster. The poster above is a real file with a
        // URL, so even the "instant" case still costs a download before anything is drawn. This one
        // costs none: it IS the message.
        if let tiny = inlineThumb(thumbnail) {
            let sealed = members != nil
                ? (try? await Crypto.shared.sealForGroup(tiny, members: members!, cid: cid))
                : (try? await Crypto.shared.encryptForConversation(cid, tiny))
            if let sealed, !sealed.isEmpty { msg["thumb"] = sealed }
        }
        if let clientId { msg["clientId"] = clientId }
        if forwarded { msg["forwarded"] = true }
        batch.setData(msg, forDocument: msgRef)
        var convUpdate: [String: Any] = [
            "lastMessage": "🎥 Video · " + voiceDurationLabel(duration),
            "lastImageUrl": thumbUrl,       // chat list shows the real thumbnail (photo parity)
            "lastImageEnc": thMeta.asDict,
            "lastSender": uid,
            "updatedAt": FieldValue.serverTimestamp(),
        ]
        if let members {
            for m in members where m != uid { convUpdate["unreadCount.\(m)"] = FieldValue.increment(Int64(1)) }
        } else {
            let other = cid.split(separator: "_").map(String.init).first { $0 != uid } ?? ""
            convUpdate["unreadCount.\(other)"] = FieldValue.increment(Int64(1))
        }
        batch.updateData(convUpdate, forDocument: convRef)
        // Mailman model: the SENDER's copy lives on their own device from day one — the
        // server object exists only to deliver, and the recipient deletes it on pickup. Kept BEFORE
        // the message is announced, and the send stops if it did not land: a full disk used to let
        // the clip go out with no copy here, and the recipient's pickup then deleted the only other.
        guard VideoCache.store(video, for: msgRef.documentID) else { throw VideoCache.NoRoomError() }
        try await batch.commit()
        // Same as the photo path: from here Cancel has a document to delete, and only this side
        // knows its id.
        if let clientId { await MediaSend.shared.noteAnnounced(clientId, messageId: msgRef.documentID) }
        // And the clip itself, whenever it finishes.
        let videoUrl = try await videoUp
        // The clip has landed — the ring comes off here rather than when the message commits. Same
        // reasoning as the photo path above, written out there.
        if let clientId { await MediaSend.shared.markItemDone(clientId) }
        try await attachMedia(["videoUrl": videoUrl], to: msgRef)
    }

    /// Encrypt + send a document/file. Contents are E2EE (same pipeline as photos); the file
    /// NAME is metadata stored in the clear (like image dimensions) so the bubble can label it.
    static func sendFile(cid: String, data rawData: Data, fileName: String, clientId: String? = nil, group: [String]? = nil, forwarded: Bool = false) async throws {
        let clientTs = Date().timeIntervalSince1970 * 1000   // captured BEFORE the upload
        var members = await freshGroupMembers(cid, group)   // 2026-09-24 fix-all #111
        if members == nil, !cid.contains("_") { members = try await groupDocMembers(cid) }
        let convRef = db.collection("conversations").document(cid)
        let cipher: Data, meta: EncMeta
        if let members {
            (cipher, meta) = try await Crypto.shared.sealBytesForGroup(rawData, members: members, cid: cid)
        } else {
            (cipher, meta) = try await Crypto.shared.encryptBytes(cid, rawData)
            let other = cid.split(separator: "_").map(String.init).first { $0 != uid } ?? ""
            try await convRef.setData(["users": [uid, other], "updatedAt": FieldValue.serverTimestamp()], merge: true)
        }
        let msgRef = convRef.collection("messages").document()
        // reference-style document preview (owner's reference): a PDF's first page — or an image
        // file's own pixels — rides along as an ENCRYPTED thumbnail, the video-poster pipeline
        // reused (thumbUrl/thumbEnc parse on every message type). Best-effort: a failed preview
        // never fails the send; other document types keep the plain icon.
        //
        // The file and its preview are INDEPENDENT blobs, and they used to upload in SEQUENCE —
        // two full network round trips one after the other, which is why even a 142 KB PDF sat
        // on the clock for seconds (owner screenshot). Now they fly together: the wall time is
        // the slower upload, and for small files that is one round trip, not two.
        async let thumbTask: [String: Any] = {
            guard let preview = documentPreviewJPEG(fileName: fileName, data: rawData) else { return [:] }
            let tCipher: Data?, tMeta: EncMeta?
            if let members {
                (tCipher, tMeta) = (try? await Crypto.shared.sealBytesForGroup(preview, members: members, cid: cid)) ?? (nil, nil)
            } else {
                (tCipher, tMeta) = (try? await Crypto.shared.encryptBytes(cid, preview)) ?? (nil, nil)
            }
            guard let tCipher, let tMeta,
                  let tUrl = try? await uploadEncrypted(
                      tCipher, to: "chat/\(cid)/\(msgRef.documentID).filethumb.enc") else { return [:] }
            return ["thumbUrl": tUrl, "thumbEnc": tMeta.asDict]
        }()
        // ⛔ STARTED, NOT AWAITED — the message goes out first. See the note in sendImage.
        // A document is the easiest case of all: its name and its size are known before a single
        // byte moves, so the recipient gets the finished-looking file row immediately and only the
        // tap-to-open has to wait.
        async let uploadedURL = uploadEncrypted(cipher, to: "chat/\(cid)/\(msgRef.documentID).file.enc",
                                                progressId: clientId,
                                                attach: .init(cid: cid, messageId: msgRef.documentID,
                                                              urlField: "fileUrl", enc: nil))
        // The preview tile is small and is what makes the row look real, so it IS awaited here
        // rather than attached later — it costs a fraction of the document itself.
        let thumbFields: [String: Any] = await thumbTask
        let batch = db.batch()
        var msg: [String: Any] = [
            "type": "file", "fileName": fileName, "fileSize": rawData.count,
            "enc": meta.asDict, "text": "", "authorId": uid, "createdAt": FieldValue.serverTimestamp(),
            "clientTs": clientTs, "uploading": true,
        ]
        for (k, v) in thumbFields { msg[k] = v }
        if let clientId { msg["clientId"] = clientId }
        if forwarded { msg["forwarded"] = true }
        batch.setData(msg, forDocument: msgRef)
        var convUpdate: [String: Any] = [
            "lastMessage": "📄 File", "lastSender": uid, "updatedAt": FieldValue.serverTimestamp(),
        ]
        if let members {
            for m in members where m != uid { convUpdate["unreadCount.\(m)"] = FieldValue.increment(Int64(1)) }
        } else {
            let other = cid.split(separator: "_").map(String.init).first { $0 != uid } ?? ""
            convUpdate["unreadCount.\(other)"] = FieldValue.increment(Int64(1))
        }
        batch.updateData(convUpdate, forDocument: convRef)
        try await batch.commit()

        try await attachMedia(["fileUrl": try await uploadedURL], to: msgRef)
    }

    /// First-page render for a PDF, the pixels for an image file — nil for anything else
    /// (those keep the plain document icon).
    /// Internal, not private: the optimistic file bubble calls this too, so the tile it shows while
    /// uploading is byte-for-byte the one the echo will carry and the bubble never changes size.
    static func documentPreviewJPEG(fileName: String, data: Data) -> Data? {
        if fileName.lowercased().hasSuffix(".pdf") {
            guard let doc = PDFDocument(data: data), let page = doc.page(at: 0) else { return nil }
            let bounds = page.bounds(for: .mediaBox)
            guard bounds.width > 0, bounds.height > 0 else { return nil }
            let scale = 300 / max(bounds.width, bounds.height)
            let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
            let img = UIGraphicsImageRenderer(size: size).image { ctx in
                UIColor.white.setFill()
                ctx.fill(CGRect(origin: .zero, size: size))
                // PDF space is bottom-up; flip, scale, and honor a non-zero page origin.
                ctx.cgContext.translateBy(x: 0, y: size.height)
                ctx.cgContext.scaleBy(x: scale, y: -scale)
                ctx.cgContext.translateBy(x: -bounds.origin.x, y: -bounds.origin.y)
                page.draw(with: .mediaBox, to: ctx.cgContext)
            }
            return img.jpegData(compressionQuality: 0.8)
        }
        if UIImage(data: data) != nil {
            return downscaledJPEG(data, maxDimension: 300, quality: 0.8)
        }
        return nil
    }

    /// Send a GIF (a public Giphy URL — public content, so NOT E2EE; we store the url directly).
    static func sendGif(cid: String, url: String, width: Double, height: Double, replyTo: ReplyRef? = nil, clientId: String? = nil, group: [String]? = nil, forwarded: Bool = false) async throws {
        var members = await freshGroupMembers(cid, group)   // 2026-09-24 fix-all #111
        if members == nil, !cid.contains("_") { members = try await groupDocMembers(cid) }
        // The quote, sealed exactly the way the photo path seals it — group key when this is a
        // group, conversation key otherwise. A GIF was the ONE message type that could not carry a
        // reply: the bubble has always known how to draw one (`replyQuote` in the isGif branch), but
        // nothing could ever produce a GIF that had one, so the composer's quote was built, dropped
        // on the floor, and left sitting in the bar (owner 2026-08-16).
        var replyEnc: [String: Any]?
        if let r = replyTo {
            let rc: Any
            if let members { rc = try await Crypto.shared.sealForGroup(r.text, members: members, cid: cid) }
            else { rc = try await Crypto.shared.encryptForConversation(cid, r.text) }
            var e: [String: Any] = ["id": r.id, "authorId": r.authorId, "text": rc]
            if r.isStatus { e["isStatus"] = true }
            if r.isReaction == true { e["isReaction"] = true }   // the story react bar (see ReplyRef)
            if let thumb = r.storyThumbUrl, !thumb.isEmpty { e["storyThumb"] = thumb }   // plaintext story URL (not E2EE)
            replyEnc = e
        }
        let convRef = db.collection("conversations").document(cid)
        if members == nil {
            let other = cid.split(separator: "_").map(String.init).first { $0 != uid } ?? ""
            try await convRef.setData(["users": [uid, other], "updatedAt": FieldValue.serverTimestamp()], merge: true)
        }
        let msgRef = convRef.collection("messages").document()
        let batch = db.batch()
        var msg: [String: Any] = [
            "type": "gif", "imageUrl": url, "width": width, "height": height,
            "text": "", "authorId": uid, "createdAt": FieldValue.serverTimestamp(),
            "clientTs": Date().timeIntervalSince1970 * 1000,
        ]
        if let clientId { msg["clientId"] = clientId }   // reconcile the optimistic bubble in place
        if forwarded { msg["forwarded"] = true }
        if let replyEnc { msg["replyTo"] = replyEnc }
        batch.setData(msg, forDocument: msgRef)
        var convUpdate: [String: Any] = [
            "lastMessage": "GIF", "lastSender": uid, "updatedAt": FieldValue.serverTimestamp(),
        ]
        if let members {
            for m in members where m != uid { convUpdate["unreadCount.\(m)"] = FieldValue.increment(Int64(1)) }
        } else {
            let other = cid.split(separator: "_").map(String.init).first { $0 != uid } ?? ""
            convUpdate["unreadCount.\(other)"] = FieldValue.increment(Int64(1))
        }
        batch.updateData(convUpdate, forDocument: convRef)
        try await batch.commit()
    }

    /// Forward an existing message into another conversation. Because every chat is
    /// E2EE with its own key, media is decrypted from the source chat and re-encrypted
    /// for the target by reusing the normal send pipeline (never re-uses source ciphertext).
    // Thrown when a forward's source media can't be retrieved/decrypted. It MUST throw (not
    // return) so ForwardPicker reports the failure instead of silently dismissing as "sent".
    enum ForwardError: Error { case sourceUnavailable }

    /// ⛔ WHETHER A FORWARDED COPY SAYS "FORWARDED" — owner, 2026-09-29, four cases: Salmo's message
    /// or mine, forwarded back into the chat with Salmo, is a plain new message from me; either one
    /// forwarded to anybody else says Forwarded.
    ///
    /// The rule underneath all four is the DESTINATION: the label tells the reader "this came from
    /// another conversation". Back into the very chat it came from, it did not, so there is nothing
    /// to tell (the reference apps treat that as a re-send). Anywhere else it did. And a message that
    /// already arrived forwarded stays forwarded wherever it goes, including back into its own chat:
    /// its words were never either side's, and a forward must not launder that away.
    ///
    /// ONE function, read by both the optimistic bubble (`ForwardPicker`) and the real send below,
    /// so the bubble can never say one thing and the delivered message another.
    static func isForward(_ m: Message, from sourceCid: String, to targetCid: String) -> Bool {
        m.forwarded || sourceCid != targetCid
    }

    /// `clientId` matches the optimistic bubble ForwardPicker parked in PendingOutbox, so the echo
    /// REPLACES that bubble rather than landing beside it as a duplicate.
    static func forwardMessage(_ m: Message, from sourceCid: String, to targetCid: String,
                               clientId: String? = nil) async throws {
        let forwarded = isForward(m, from: sourceCid, to: targetCid)
        if m.isSticker {   // 2026-10-17 chat stickers
            try await StickerSend.forward(m, from: sourceCid, to: targetCid, clientId: clientId, forwarded: forwarded)
        } else if m.isImage {
            let bytes: Data
            if let local = m.localImageData {
                bytes = local
            } else if let s = m.imageUrl, let url = URL(string: s), let meta = m.enc,
                      let (cipher, _) = try? await MediaSession.shared.data(from: url),
                      let dec = await Crypto.shared.decryptBytes(sourceCid, cipher: cipher, meta: meta) {
                bytes = dec
            } else { throw ForwardError.sourceUnavailable }
            try await sendImage(cid: targetCid, data: bytes, clientId: clientId, caption: m.text, forwarded: forwarded)
        } else if m.isAlbum {
            // The album forwards as ONE album, grouped like the original — the owner rejected
            // the reference app's break-apart-into-singles ("is broke is send one by one"). Each item
            // decrypts from the source chat and re-seals for the target through the real album
            // pipeline. ANY missing item fails the whole forward — never deliver a smaller album
            // than the bubble showed.
            // EVERY ITEM AT ONCE. This was a plain `for` loop, so forwarding a ten-photo album made
            // ten round trips end to end before a single byte went back out — and a video item made
            // two of them, poster then clip. Nothing in the loop depended on the item before it.
            //
            // Indexed and re-sorted afterwards, because a task group finishes in whatever order the
            // network feels like and an album that arrives shuffled is worse than a slow one.
            // The all-or-nothing rule is unchanged: any item that cannot be rebuilt throws, and a
            // throw inside the group cancels the siblings and propagates, so a partial album still
            // cannot be delivered.
            var indexed: [(Int, AlbumSendItem)] = try await withThrowingTaskGroup(
                of: (Int, AlbumSendItem).self
            ) { group in
                for (idx, it) in m.album.enumerated() {
                    group.addTask {
                        guard let purl = URL(string: it.imageUrl),
                              let (pCipher, _) = try? await MediaSession.shared.data(from: purl),
                              let poster = await Crypto.shared.decryptBytes(sourceCid, cipher: pCipher, meta: it.enc)
                        else { throw ForwardError.sourceUnavailable }
                        guard it.isVideo else { return (idx, .image(poster)) }
                        guard let vs = it.videoUrl, let vurl = URL(string: vs), let venc = it.videoEnc,
                              let (vCipher, _) = try? await MediaSession.shared.data(from: vurl),
                              let clip = await Crypto.shared.decryptBytes(sourceCid, cipher: vCipher, meta: venc)
                        else { throw ForwardError.sourceUnavailable }
                        return (idx, .video(clip, thumbnail: poster, duration: it.duration,
                                            width: it.width, height: it.height))
                    }
                }
                var out: [(Int, AlbumSendItem)] = []
                for try await pair in group { out.append(pair) }
                return out
            }
            indexed.sort { $0.0 < $1.0 }
            let items = indexed.map(\.1)
            guard !items.isEmpty else { throw ForwardError.sourceUnavailable }
            try await sendMixedAlbum(cid: targetCid, items: items, caption: m.text, clientId: clientId, forwarded: forwarded)
        } else if m.isAudio {
            guard let s = m.audioUrl, let url = URL(string: s), let meta = m.enc,
                  let (cipher, _) = try? await MediaSession.shared.data(from: url),
                  let dec = await Crypto.shared.decryptBytes(sourceCid, cipher: cipher, meta: meta)
            else { throw ForwardError.sourceUnavailable }
            try await sendAudio(cid: targetCid, data: dec, duration: m.duration ?? 0, waveform: m.waveform, clientId: clientId, forwarded: forwarded)
        } else if m.isVideo {
            // The clip and its poster are two independent fetches and were done one after the other.
            // Started together now. The local copy is still preferred for the clip: the server object
            // may already be delivered-and-deleted by the mailman sweep, and a cache hit costs nothing
            // to try first.
            async let clipBytes: Data? = {
                if let cached = VideoCache.data(for: m.id) { return cached }
                guard let s = m.videoUrl, let url = URL(string: s), let meta = m.enc,
                      let (cipher, _) = try? await MediaSession.shared.data(from: url)
                else { return nil }
                return await Crypto.shared.decryptBytes(sourceCid, cipher: cipher, meta: meta)
            }()
            async let thumbBytes: Data? = {
                guard let s = m.thumbUrl, let url = URL(string: s), let meta = m.thumbEnc,
                      let (cipher, _) = try? await MediaSession.shared.data(from: url)
                else { return nil }
                return await Crypto.shared.decryptBytes(sourceCid, cipher: cipher, meta: meta)
            }()
            guard let bytes = await clipBytes, let thumb = await thumbBytes
            else { throw ForwardError.sourceUnavailable }
            try await sendVideo(cid: targetCid, video: bytes, thumbnail: thumb, duration: m.duration ?? 0,
                                width: m.width ?? 720, height: m.height ?? 720, caption: m.text, clientId: clientId, forwarded: forwarded)
        } else if m.isGif {
            guard let gifUrl = m.imageUrl, !gifUrl.isEmpty else { throw ForwardError.sourceUnavailable }
            try await sendGif(cid: targetCid, url: gifUrl, width: m.width ?? 200, height: m.height ?? 200, clientId: clientId, forwarded: forwarded)
        } else if m.isFile {
            guard let s = m.fileUrl, let url = URL(string: s), let meta = m.enc,
                  let (cipher, _) = try? await MediaSession.shared.data(from: url),
                  let dec = await Crypto.shared.decryptBytes(sourceCid, cipher: cipher, meta: meta)
            else { throw ForwardError.sourceUnavailable }
            try await sendFile(cid: targetCid, data: dec, fileName: m.fileName ?? "File", clientId: clientId, forwarded: forwarded)
        } else {
            try await sendText(cid: targetCid, text: m.text, clientId: clientId, forwarded: forwarded)
        }
    }

    /// Recent image messages in a conversation (for the Shared Media section).
    /// Filters client-side to avoid needing a composite index.
    // Warm cache so the profile's "All Media" strip renders INSTANTLY on re-entry instead of popping
    // in after a fresh Firestore round-trip each time ("coming late / not stable").
    @MainActor private static var sharedMediaCache: [String: [Message]] = [:]
    @MainActor static func cachedSharedMedia(_ cid: String) -> [Message]? { sharedMediaCache[cid] }
    /// Sign-out: decrypted messages must not outlive the account in memory (2026-09-24 audit).
    @MainActor static func clearSharedMediaCache() { sharedMediaCache = [:] }

    /// HOW MUCH MEDIA THIS CHAT HAD LAST TIME, remembered on disk per conversation.
    ///
    /// The profile's "All Media" section used to appear only once the network answered, so opening a
    /// profile showed the page WITHOUT it and then shifted everything down a moment later (user
    /// screenshots, one frame before and one after). The in-memory cache only helped on re-entry
    /// within the same app run; a fresh launch always jumped.
    ///
    /// A count survives a relaunch and is enough to settle the layout on the FIRST frame: >0 means
    /// reserve the section and show placeholder tiles while the real thumbnails load; 0 means this
    /// chat has never had media, so nothing is drawn at all and there is nothing to shift. Exactly the
    /// two rules the user stated.
    enum SharedMediaPresence {
        private static let key = "sharedMediaCount.v1"
        static func count(_ cid: String) -> Int {
            (UserDefaults.standard.dictionary(forKey: key) as? [String: Int])?[cid] ?? 0
        }
        static func note(_ cid: String, _ count: Int) {
            var d = (UserDefaults.standard.dictionary(forKey: key) as? [String: Int]) ?? [:]
            guard d[cid] != count else { return }
            d[cid] = count
            UserDefaults.standard.set(d, forKey: key)
        }
    }

    /// Returns nil when the LOAD FAILED, which is a different thing from a chat that has no media —
    /// that is an empty array. The two were indistinguishable before, and the profile treated both as
    /// "no media": a failed load (offline, or a permission hiccup) emptied `mediaHint` and the All
    /// Media section vanished from a chat full of photos (user report + screenshots, build 400).
    static func sharedMedia(_ cid: String) async -> [Message]? {
        // ⚠️ AN EMPTY id IS NOT A DOCUMENT. `documentWithPath:` THROWS `invalid argument` for one —
        // an NSException, which `try?` cannot catch and which aborts the process. Guarded here rather
        // than only at the call sites so no future caller can crash the app by asking about a chat
        // that does not exist.
        guard !cid.isEmpty else { return nil }
        do {
            // 200 MESSAGES, not 60. This is a window over MESSAGES that is then filtered down to media,
            // so the number that matters is how much conversation can sit on top of the last photo
            // before it falls out of view. Sixty is one busy evening of texting: a chat with plenty of
            // photos showed an empty All Media section simply because they had been pushed out of the
            // window. (The proper form is a query on a media flag, which needs a composite index; this
            // is the honest interim, and the local pass in the profile covers the common case for free.)
            let snap = try await db.collection("conversations").document(cid).collection("messages")
                .order(by: "createdAt", descending: true)
                .limit(to: 200).getDocuments()
            // Albums COUNT as media (user report: a single photo showed here, a multi-photo album never
            // did — this filter dropped album messages before any view could see them) and are expanded
            // into their individual photos/videos.
            let out = snap.documents
                .map { Message(id: $0.documentID, data: $0.data(), cid: cid, crypto: Crypto.shared) }
                .filter { $0.isImage || $0.isVideo || $0.isAlbum }
                .flatMap { $0.expandedGalleryItems(cid: cid) }
            await MainActor.run {
                sharedMediaCache[cid] = out
                SharedMediaPresence.note(cid, out.count)   // settles the NEXT open's first frame
            }
            return out
        } catch {
            // The warm cache is a real answer; nothing at all is a failure, and says so.
            return await MainActor.run { sharedMediaCache[cid] }
        }
    }

    /// A larger recent window of decrypted messages for the Media Gallery to categorize into
    /// media / audio / links tabs (newest first). Client-side filtering avoids a composite index.
    /// Arrival prefetch, the list's half of "a voice note never spins": the newest voice notes of
    /// a chat, downloaded and decrypted into the AudioCache before the chat is opened. The last 8
    /// messages are fetched and filtered client-side — a `type ==` + `createdAt` query would need
    /// a composite index and fail silently without one. Idempotent: cached ids are skipped, and
    /// one-time notes are never cached anywhere, this path included.
    static func prefetchNewestVoice(cid: String) async {
        guard let snap = try? await db.collection("conversations").document(cid).collection("messages")
            .order(by: "createdAt", descending: true)
            .limit(to: 8).getDocuments() else { return }
        // 2026-10-23: through `MediaFetch.requestVoice`, so the same rules as inside a chat apply
        // here (the Audio row and the network, Low Data Mode, the size ceiling, one-time notes and
        // files sealed before I joined left alone), and the download is the shared job a tap would
        // join. It fetched on its own before, ignoring the Audio row altogether, with no retry, and
        // a tap during it downloaded the same note a second time.
        let notes = snap.documents
            .map { Message(id: $0.documentID, data: $0.data(), cid: cid, crypto: Crypto.shared) }
            .filter { $0.isAudio }
        guard !notes.isEmpty else { return }
        await MainActor.run {
            for m in notes { MediaFetch.requestVoice(m, cid: cid, priority: .auto) }
        }
    }

    /// Returns nil when the LOAD FAILED (2026-09-24 audit). It returned [] before, and the gallery
    /// wrote that empty answer over its cached copy, so one offline open wiped a full gallery.
    static func galleryContent(_ cid: String, limit: Int = 400) async -> [Message]? {
        guard !cid.isEmpty else { return nil }   // an empty id throws an NSException — see `sharedMedia`
        do {
            let snap = try await db.collection("conversations").document(cid).collection("messages")
                .order(by: "createdAt", descending: true)
                .limit(to: limit).getDocuments()
            return snap.documents
                .map { Message(id: $0.documentID, data: $0.data(), cid: cid, crypto: Crypto.shared) }
        } catch {
            return nil
        }
    }

    /// Delete all of MY messages in this conversation ("Clear chat" for me).
    static func clearMyMessages(_ cid: String) async {
        guard !cid.isEmpty else { return }   // an empty id throws, it does not return nil — see `sharedMedia`
        do {
            let snap = try await db.collection("conversations").document(cid).collection("messages")
                .whereField("authorId", isEqualTo: uid).getDocuments()
            // Firestore batches cap at 500 writes — chunk so a chat with >500 of my messages
            // doesn't throw and silently delete NOTHING (the old single-batch + swallowed catch).
            let docs = snap.documents
            var i = 0
            while i < docs.count {
                let batch = db.batch()
                for d in docs[i..<min(i + 450, docs.count)] { batch.deleteDocument(d.reference) }
                try await batch.commit()
                i += 450
            }
        } catch { /* ignore */ }
    }

    /// Set or clear my emoji reaction on a message. The emoji is E2E-encrypted
    /// (same as text) so the server never sees the reaction.
    /// False when the reaction did not land (2026-09-24 audit): the callers had no way to tell, so a
    /// refused reaction simply never appeared with nothing said. Offline is not false: the write
    /// waits and lands on reconnect.
    @discardableResult
    static func setReaction(cid: String, messageId: String, emoji: String?, toAuthor: String,
                            group: [String]? = nil, targetText: String? = nil,
                            targetImages: [(url: String, enc: EncMeta?)] = []) async -> Bool {
        let ref = db.collection("conversations").document(cid)
            .collection("messages").document(messageId)
        let convRef = db.collection("conversations").document(cid)
        guard let emoji else {
            guard (try? await ref.updateData(["reactions.\(uid)": FieldValue.delete()])) != nil else { return false }
            // If MY reaction was the one being previewed in the chat list, retract it.
            let cs = try? await convRef.getDocument()
            if (cs?.data()?["lastReactionBy"] as? String) == uid {
                try? await convRef.updateData([
                    "lastReactionEnc": FieldValue.delete(), "lastReactionBy": FieldValue.delete(),
                    "lastReactionToAuthor": FieldValue.delete(), "lastReactionAt": FieldValue.delete(),
                    "lastReactionToEnc": FieldValue.delete(),
                    "lastReactionToImages": FieldValue.delete(),
                ])
            }
            return true
        }
        // Group reactions are sealed for ALL members (so everyone sees the emoji); 1:1 to the other.
        var members = await freshGroupMembers(cid, group)   // 2026-09-24 fix-all #111
        if members == nil, !cid.contains("_") { members = (try? await groupDocMembers(cid)) ?? nil }
        let enc: String?
        if let members { enc = try? await Crypto.shared.sealForGroup(emoji, members: members, cid: cid) }
        else { enc = try? await Crypto.shared.encryptForConversation(cid, emoji) }
        // Dotted field update — only touches my own key, so concurrent reactions never clobber.
        guard let enc else { return false }
        do {
            // Preview only once the reaction itself landed (2026-09-24 audit): reacting to a message
            // deleted meanwhile failed here, and the chat list still said "Reacted 🙏" about nothing.
            guard (try? await ref.updateData(["reactions.\(uid)": enc])) != nil else { return false }
            // Surface it in the chat list ("Reacted 🙏") — a separate best-effort write, so the
            // reaction itself still lands even if this one is rejected. Deliberately does NOT
            // bump updatedAt: a reaction shouldn't reorder chats or re-arm unread; the list
            // preview just changes in place while the reaction is the newest event.
            // ⛔ AND WHAT IT WAS ON, SEALED THE SAME WAY — owner, 2026-09-26: 'You reacted 😎 to
            // "Voice message"', as the reference app's list says it. Sealed like the emoji, so the
            // server never has the words. Deleted when absent so a stale one never outlives it.
            var targetEnc: String?
            if let t = targetText?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
                let snippet = String(t.prefix(60))
                if let members { targetEnc = try? await Crypto.shared.sealForGroup(snippet, members: members, cid: cid) }
                else { targetEnc = try? await Crypto.shared.encryptForConversation(cid, snippet) }
            }
            // ⛔ THE PICTURES IT WAS ON — owner, 2026-10-03: the list shows the real photo, an album
            // as up to three overlapping. The same url + wrapped-key pair a photo message already
            // leaves on this document as `lastImageUrl`/`lastImageEnc`, so nothing new is exposed.
            // 1:1 only: the group rule is an allow-list without this key, and groups are off.
            let images: [[String: Any]] = (members == nil ? targetImages : []).prefix(3).map { t in
                var row: [String: Any] = ["url": t.url]
                if let e = t.enc { row["enc"] = e.asDict }
                return row
            }
            try? await convRef.updateData([
                "lastReactionEnc": enc, "lastReactionBy": uid,
                "lastReactionToAuthor": toAuthor,
                "lastReactionAt": FieldValue.serverTimestamp(),
                "lastReactionToEnc": targetEnc.map { $0 as Any } ?? FieldValue.delete(),
                "lastReactionToImages": images.isEmpty ? FieldValue.delete() : images,
            ])
        }
        return true
    }

    /// Write ONE call record into the shared chat, keyed by callId so the two ends converge on a single
    /// row rather than creating duplicates.
    ///
    /// The old doc comment claimed "whoever writes first wins; the other's create is a no-op". That was
    /// FALSE for a non-merging setData: BOTH ends reach here and the second write clobbered the first, so
    /// authorId and callDuration were whichever device happened to land last (the two sides compute
    /// duration from their own connectedDate, so they never agree). Now merged, and only the CALLER
    /// writes the duration — one authoritative source instead of a race. The callee's row still creates
    /// the record on its own if the caller never manages to write, so nothing is lost.
    /// Stores who the caller was, so each client renders outgoing/incoming for itself.
    /// The LIVE call row (owner's 2026-08-12 reference, both sides): written the moment the call doc
    /// exists, so the chat shows a "Ringing" bubble while the phone is still ringing. recordCall
    /// later merges the final outcome onto the SAME doc, so the row transforms in place. Only the
    /// CALLER writes it — one creator; the callee sees it arrive through the normal listener.
    static func recordCallRinging(cid: String, callId: String, callerUid: String, video: Bool) async {
        try? await db.collection("conversations").document(cid)
            .collection("messages").document("call_\(callId)").setData([
                "type": "call",
                "authorId": callerUid,
                "callerUid": callerUid,
                "callOutcome": "ringing",
                "callVideo": video,
                "text": "",
                "createdAt": FieldValue.serverTimestamp(),
            ], merge: true)
    }

    /// Flip the live row to "ongoing" once the call connects. updateData so a row that was never
    /// created (old-build caller) is a silent no-op rather than a half-made record.
    static func markCallOngoing(cid: String, callId: String) async {
        try? await db.collection("conversations").document(cid)
            .collection("messages").document("call_\(callId)")
            .updateData(["callOutcome": "ongoing"])
    }

    static func recordCall(cid: String, callId: String, callerUid: String, outcome: String, video: Bool, durationSec: Int) async {
        let convRef = db.collection("conversations").document(cid)
        let msgRef = convRef.collection("messages").document("call_\(callId)")
        var fields: [String: Any] = [
            "type": "call",
            "authorId": callerUid,             // deterministic: the caller, not whoever wrote last
            "callerUid": callerUid,            // viewer compares to itself for direction
            "callOutcome": outcome,            // answered | missed (live rows: ringing | ongoing)
            "callVideo": video,                // video call (log/preview label)
            "text": "",
        ]
        if uid == callerUid { fields["callDuration"] = durationSec }
        // The row's time is when the call STARTED RINGING (the live row wrote it — the standard apps stamp
        // it that way too). Re-stamping on the final merge shoved the row past messages sent DURING
        // the call once re-sorted from the server. Stamp only when this write is the creator (the
        // other side never wrote the live row, e.g. an old build placed the call).
        let existing = try? await msgRef.getDocument()
        // audit M-036, 2026-10-07: a late or repeated ring (a push APNs held until after the call,
        // or the callee's other device that lost the answered-elsewhere race) finished as "missed"
        // on THIS phone and merged that over the shared row, so a call somebody answered turned
        // into a red "Missed call" in the chat, the preview and the Calls tab. An answered call
        // stays answered: a "missed" from any device does not overwrite it, nor the preview.
        if outcome == "missed", existing?.data()?["callOutcome"] as? String == "answered" { return }
        if existing?.exists != true {
            fields["createdAt"] = FieldValue.serverTimestamp()
        }
        do {
            try await msgRef.setData(fields, merge: true)
        } catch _ where fields["createdAt"] != nil {
            // audit M-149, 2026-10-07: the read said "no row", and the other side's live row landed
            // before this write. The write was then an UPDATE that also changed `createdAt`, which
            // the rules refuse (only the outcome, duration and video keys may change), so this
            // side's outcome was lost silently. Write the outcome again without the stamp: the row
            // keeps the time the other side gave it.
            fields.removeValue(forKey: "createdAt")
            try? await msgRef.setData(fields, merge: true)
        } catch {}
        // Declines write NO marker of their own (owner's 2026-08-12 order): a rejected
        // call records as missed everywhere, so callers can never tell a decline from a ring-out.
        let marker: String = {
            if outcome == "missed" { return video ? "📹 Missed video call" : "📞 Missed call" }
            return video ? "📹 Video call" : "📞 Call"
        }()
        try? await convRef.setData([
            "lastMessage": marker,
            // ⛔ THE CALLER'S UID, AND THE CHAT LIST NEEDS IT TO TELL THE STORY STRAIGHT. His report,
            // 2026-08-29: he placed a call nobody answered and his own chat list said red "Missed
            // call", as though he had missed it.
            //
            // The marker above cannot carry the answer, because ONE conversation document is read by
            // BOTH phones and each of them has to draw the opposite thing. So the direction has to
            // travel as a uid the reader compares to itself, exactly as the call MESSAGE already
            // does with `callerUid`.
            //
            // ⚠️ THIS FIELD USED TO BE CLEARED ON PURPOSE and the reason was real: it named whoever
            // sent the previous message, so the row drew MY delivery ticks beside a call record,
            // which is not my message and has no sent/read state. The ticks are suppressed by the
            // row itself now (a call marker never draws them), so the field is free to mean what its
            // name says.
            //
            // ⚠️ OLD ROWS STAY AMBIGUOUS. Conversations whose last event is a call recorded before
            // today hold an empty `lastSender` and there is nothing anywhere that remembers who
            // called; those keep rendering as they did.
            "lastSender": callerUid,
            "updatedAt": FieldValue.serverTimestamp(),
        ], merge: true)
        // Keep the Calls tab (list + missed badge) live — the history repo has no listener.
        // audit M-150, 2026-10-07: only this chat's rows changed, so only this chat is re-read.
        await CallsRepository.shared.refreshAfterCall(cid: cid)
    }

    /// "0:53" — voice-note length for markers and previews.
    static func voiceDurationLabel(_ seconds: Double) -> String {
        let d = Int(seconds.rounded())
        return String(format: "%d:%02d", d / 60, d % 60)
    }

    /// Delete for Everyone. Returns false when the server refused, so the caller can say so.
    ///
    /// THIS WAS `try?`, AND THAT WAS THE BUG. A swallowed error on a user-initiated destructive action
    /// is indistinguishable from a dead button: the message stayed, no alert appeared, and there was
    /// nothing anywhere to say why. The tell was that "Delete for Me" worked from the SAME alert — same
    /// wiring, same dismissal, different one line — which rules out the UI and points at this call.
    ///
    /// The refusal itself is almost certainly the Firestore rules (the rules are not in this repo; fetch
    /// them with the Rules REST API before assuming otherwise). Surfacing the error is what makes that
    /// diagnosable at all, and a destructive action must never fail silently either way.
    @discardableResult
    static func deleteMessage(cid: String, messageId: String) async -> Bool {
        // A "<parentId>-<index>" id is a synthetic ALBUM CHILD (the viewer's album pages, the gallery's
        // expanded items). There is no such doc on the server — the whole album is ONE message — and
        // the delete rule's resource.data lookup on a nonexistent doc reads as a refusal, which is the
        // user's "couldn't delete for everyone" on an album photo. Deleting an album item means EDITING
        // the album: rewrite the parent's raw album array without that item; deleting the LAST item
        // deletes the message itself. Firestore auto-ids never contain "-". A pending message's id is a
        // UUID (which does contain dashes) — the Int() parse of everything after the FIRST dash rejects
        // those, since a UUID tail is never pure digits.
        if let dash = messageId.firstIndex(of: "-"),
           let index = Int(messageId[messageId.index(after: dash)...]) {
            return await deleteAlbumItem(cid: cid, parentId: String(messageId[..<dash]), index: index)
        }
        do {
            // Read the doc BEFORE deleting it: once it's gone there is no way to know which Storage
            // objects belonged to it, and nothing else in the app ever deletes chat media (audit).
            // "Delete for everyone" and the disappearing timer both promise the content is gone, so
            // the ciphertext should not outlive the message it belonged to.
            let ref = db.collection("conversations").document(cid).collection("messages").document(messageId)
            // `try`, NOT `try?`. With `try?` a failed READ came back nil, and the "already gone"
            // branch below treats nil exactly like a missing document: it returned SUCCESS, deleted
            // nothing, and showed no error. The owner deleted a forwarded gif and it simply stayed,
            // with no alert, because the app believed it had already been removed. A read we could
            // not perform is not proof of anything, so it now throws to the catch and is reported.
            let snap = try await ref.getDocument()
            // ALREADY GONE = SUCCESS. Deleting twice is not an error, the end state the caller asked
            // for is already true. The rule reads `resource.data` to decide who may delete, and on a
            // missing document that lookup is null, so a second delete comes back as a REFUSAL. The
            // user deletes a message, it vanishes, they are not sure it worked, they try again, and
            // the app tells them "the server refused, the message is still there for both of you"
            // about a message that is gone (owner screenshot). Still clean up below, in case the doc
            // went while its pin or summary did not.
            if !snap.exists {
                await removePinnedMessage(cid, messageId)
                await clearSummaryIfNewest(cid: cid, deletedId: messageId)
                return true
            }
            let blobs = mediaStorageURLs(in: snap.data())
            // 2026-09-24 feature-audit: read before the strip below removes them.
            let reactionsBefore = snap.data()?["reactions"] as? [String: Any]

            // TOMBSTONE, not a hole. The document survives carrying `deleted`, with every content
            // field stripped, so both sides see that something was here and was removed instead of a
            // message silently vanishing and leaving the other person wondering what they missed.
            // This is what the standard messengers do.
            //
            // Costs nothing to keep: the MEDIA is still deleted from Storage below, and Storage is
            // where the money is. What remains is a few bytes of marker in a document that already
            // existed.
            //
            // Falls back to the hard delete if the server refuses the update, so a rules setup that
            // only permits deletes still behaves exactly as it does today rather than failing.
            // SECOND delete on a tombstone removes it outright. The first leaves the marker so the
            // other person knows something was here; deleting that marker is the owner saying they
            // want the trace gone too, and there is no content left to protect by then.
            let alreadyTombstone = snap.data()?["deleted"] as? Bool == true

            var markedDeleted = false
            if !alreadyTombstone {
                do {
                    // TYPE GOES BACK TO TEXT, and that one field is what keeps the rest of the app
                    // honest. A tombstone that stayed type "image" still answered isImage, so it
                    // turned up in All Media as a broken tile with no photo behind it, and in the
                    // profile's media grid, and in the gallery expansion. Fixing those filters one
                    // by one would have missed the next one; a deleted message simply is not media.
                    var strip: [String: Any] = [
                        "deleted": true, "text": "", "type": "text", "enc": FieldValue.delete(),
                    ]
                    for k in ["imageUrl", "videoUrl", "thumbUrl", "audioUrl", "fileUrl", "album",
                              "fileName", "fileSize", "waveform", "duration", "blurhash", "linkPreview",
                              "poll", "locationCard", "contactCard", "replyTo", "reactions",
                              "videoEnc", "thumbEnc", "viewOnce", "mentions",
                              // The Forwarded tag sits ABOVE the bubble, so it survived the content
                              // being stripped and read "Forwarded / This message was deleted".
                              "forwarded",
                              // 2026-09-24 feature-audit: `thumb` (the sealed preview every photo,
                              // video and file send writes) and `edits` (the edit history) were
                              // missing here while the rule refuses a tombstone that keeps either.
                              // So every media or edited message had its tombstone REFUSED and fell
                              // to the hard delete below, losing the placeholder.
                              "thumb", "edits", "editedAt"] {
                        strip[k] = FieldValue.delete()
                    }
                    // 2026-09-24 feature-audit: a group admin (the "Delete messages" right) deleting
                    // someone else's message signs it, so the author's bubble does not claim "You
                    // deleted this message". Never written on my own message, so an own delete stays
                    // accepted by rules that predate this field.
                    if (snap.data()?["authorId"] as? String) != uid { strip["deletedBy"] = uid }
                    try await ref.updateData(strip)
                    markedDeleted = true
                } catch {
                    #if DEBUG
                    print("[deleteMessage] tombstone refused, falling back to hard delete: \(error)")
                    #endif
                }
            }
            // Nothing marked means either this WAS already a marker, or the server refused the flag.
            // Either way the document goes.
            // 2026-09-24 feature-audit: THE FILES GO WHILE THE DOC STILL EXISTS. The Storage delete
            // rule reads this message doc to see who wrote it; after a hard delete there is nothing
            // to read, so every file of a hard-deleted message was refused and stayed in the bucket.
            // Tombstone path: the marker is there now. Hard-delete path: sweep first, then delete.
            // Best-effort either way: a file that will not go never fails the delete.
            for u in blobs {
                try? await Storage.storage().safeReference(forURL: u)?.delete()
            }
            if !markedDeleted { try await ref.delete() }
            // ⛔ AND THE DECRYPTED COPIES ON THIS PHONE. The comment at the top of this method says
            // the ciphertext must not outlive the message — and until now that promise was kept on
            // the SERVER and broken on the DEVICE.
            //
            // The plaintext lives in three local stores, and `AudioCache.remove` / `VideoCache.remove`
            // had no callers anywhere in the app: the only removals were the wholesale `removeAll()`
            // at sign-out and in Settings. So a voice note, video or photo that was deleted for
            // everyone — or that expired on the disappearing timer, which routes here too — stayed
            // on both phones as a readable file, indefinitely. The one thing "delete for everyone"
            // exists to guarantee was the one thing it did not do.
            //
            // Best-effort and after the doc is gone, for the same reason the Storage loop above is:
            // a local file we cannot remove must not turn a successful delete into a reported one.
            await purgeLocalCopies(messageId: messageId, blobs: blobs, cid: cid)
            // Clean up what a bare doc delete leaves behind (audit):
            // • a PIN pointing at it — pinnedMessageIds is shared state and nothing else ever
            //   removes the id, so both people kept a dead "Tap to view" pin forever;
            // • the conversation SUMMARY, if this was the newest message — the deleted text (and a
            //   photo's thumbnail) stayed readable in BOTH chat lists indefinitely, which is exactly
            //   what "delete for everyone" promises it won't.
            await removePinnedMessage(cid, messageId)
            await clearSummaryIfNewest(cid: cid, deletedId: messageId)
            await clearReactionPreviewIfFrom(cid: cid, reactions: reactionsBefore)
            return true
        } catch {
            #if DEBUG
            print("[deleteMessage] refused for \(cid)/\(messageId): \(error)")
            #endif
            return false
        }
    }

    /// Every Storage object a message doc owns: photo, video + its poster, voice note, file, each
    /// album item (and each album video's own poster), and a sealed link-preview image. Reads the RAW
    /// doc so it covers types the client model may not expose.
    /// ⛔ THE OTHER HALF OF A DELETE: the decrypted copies this phone kept.
    ///
    /// `deleteMessage` removes the document and every Storage object it named. Until this existed
    /// that was the whole story, and it left the plaintext behind in three places:
    ///
    ///   · `AudioCache` — the decrypted voice note, keyed by message id.
    ///   · `VideoCache` — the decrypted video, keyed by message id.
    ///   · `DiskImageCache` — photos and thumbnails, keyed by their Storage URL, and written with
    ///     `owned: true`, which every other removal path in that file deliberately spares.
    ///
    /// Both per-message removals had no callers at all before this; the only thing that ever emptied
    /// those stores was the wholesale wipe at sign-out. So "delete for everyone" and the
    /// disappearing timer both destroyed the server's ciphertext and left a readable file on both
    /// devices for good.
    ///
    /// ⚠️ Also drops the chat's search corpus, which is a THIRD copy of the same content — decrypted
    /// message text in a process-lifetime static with a two-minute TTL. Without this the deleted
    /// words stayed findable, in the clear, after the app had reported them destroyed.
    ///
    /// Every step is best-effort and none of them can fail the delete: the message is already gone
    /// by the time this runs, and a file we could not remove is not a reason to tell the user the
    /// delete failed.
    @MainActor
    private static func purgeLocalCopies(messageId: String, blobs: [String], cid: String) {
        AudioCache.remove(messageId)
        VideoCache.remove(messageId)
        for u in blobs { DiskImageCache.shared.remove(url: u) }
        MessageSearch.invalidateChat(cid)
    }

    private static func mediaStorageURLs(in data: [String: Any]?) -> [String] {
        guard let d = data else { return [] }
        var out: [String] = []
        for key in ["imageUrl", "videoUrl", "thumbUrl", "audioUrl", "fileUrl"] {
            if let s = d[key] as? String, s.hasPrefix("http") { out.append(s) }
        }
        if let album = d["album"] as? [[String: Any]] {
            for it in album {
                for key in ["imageUrl", "videoUrl"] {
                    if let s = it[key] as? String, s.hasPrefix("http") { out.append(s) }
                }
            }
        }
        if let lp = d["linkPreview"] as? [String: Any], let s = lp["imageUrl"] as? String,
           s.hasPrefix("http") { out.append(s) }
        // A GIF is a public Giphy url we never uploaded — deleting it is not ours to do.
        if (d["type"] as? String) == "gif" { return [] }
        return out
    }

    /// 2026-09-24 feature-audit: the chat list's "Reacted …" preview came from a message that has
    /// just been deleted for everyone, so clear it; it outlived the message indefinitely. The
    /// conversation doc does not name the message, but `setReaction` writes the SAME ciphertext
    /// to the message's `reactions[uid]` and to `lastReactionEnc`, and each seal is unique, so an
    /// equal pair identifies the message. The server's expiry sweep does the same check.
    private static func clearReactionPreviewIfFrom(cid: String, reactions: [String: Any]?) async {
        guard let reactions, !reactions.isEmpty else { return }
        let convRef = db.collection("conversations").document(cid)
        guard let d = try? await convRef.getDocument().data(),
              let by = d["lastReactionBy"] as? String, let enc = d["lastReactionEnc"] as? String,
              (reactions[by] as? String) == enc else { return }
        try? await convRef.updateData([
            "lastReactionEnc": FieldValue.delete(), "lastReactionBy": FieldValue.delete(),
            "lastReactionToAuthor": FieldValue.delete(), "lastReactionAt": FieldValue.delete(),
            "lastReactionToEnc": FieldValue.delete(),
            // Deleting a key that is not there changes nothing, so a group's allow-list rule
            // never sees this one.
            "lastReactionToImages": FieldValue.delete(),
        ])
    }

    /// After the newest message is deleted, re-point the conversation summary at whatever is now
    /// newest (or clear it when nothing is left). Best-effort: a failure here never fails the delete.
    private static func clearSummaryIfNewest(cid: String, deletedId: String) async {
        let convRef = db.collection("conversations").document(cid)
        // 2026-09-24 audit: through `rewriteSummaryGuarded`, so a message sent while this was
        // reading is not overwritten by the summary of the one before it.
        await rewriteSummaryGuarded(convRef) { await summaryOfNewest(convRef) }
    }

    /// The summary fields for whatever message is newest right now. Split out of
    /// `clearSummaryIfNewest` on 2026-09-24 (audit) so the guarded writer can recompute it.
    private static func summaryOfNewest(_ convRef: DocumentReference) async -> [String: Any] {
        let newest = try? await convRef.collection("messages")
            .order(by: "createdAt", descending: true).limit(to: 1).getDocuments()
        guard let doc = newest?.documents.first else {
            // Nothing left at all.
            return [
                "lastMessage": "", "lastSender": "",
                "lastImageUrl": FieldValue.delete(), "lastImageEnc": FieldValue.delete(),
            ]
        }
        let d = doc.data()
        // The tombstone is still the newest message now that deleting keeps the document, and its
        // text is empty, which would leave the chat list showing a blank line. A plaintext marker
        // instead, the same way "GIF" and "📷 Photo" already ride this field un-encrypted.
        let deletedNewest = d["deleted"] as? Bool == true
        var update: [String: Any] = [
            "lastMessage": deletedNewest ? "This message was deleted" : summaryText(d),
            "lastSender": d["authorId"] as? String ?? "",
        ]
        // 2026-10-19 groups v2: a member's words in the clear keep their name in the list
        // (Conversation.lastPlainTag); a notice or a call row does not get one.
        let line = update["lastMessage"] as? String ?? ""
        let kind = d["type"] as? String ?? ""
        if !convRef.documentID.contains("_"), !deletedNewest, kind != "system", kind != "call",
           !line.isEmpty, !line.hasPrefix("enc") {
            update["lastPlainTag"] = Conversation.plainTag(line)
        }
        // Carry the new newest message's thumbnail, or drop the stale one.
        if let u = d["imageUrl"] as? String, let e = d["enc"] as? [String: Any],
           (d["viewOnce"] as? Bool) != true {
            update["lastImageUrl"] = u; update["lastImageEnc"] = e
        } else {
            update["lastImageUrl"] = FieldValue.delete()
            update["lastImageEnc"] = FieldValue.delete()
        }
        return update
    }

    /// ⛔ A MEDIA MESSAGE IS NEVER A BLANK SUMMARY — owner, 2026-10-04, a chat with an unread
    /// message reading "Say hello". A photo's `text` is its caption, usually empty, and the
    /// recompute copied that empty text, which the list reads as a brand-new chat. Media without a
    /// caption gets the same plaintext label its send path writes.
    private static func summaryText(_ d: [String: Any]) -> String {
        let text = d["text"] as? String ?? ""
        let type = d["type"] as? String ?? ""
        let viewOnce = d["viewOnce"] as? Bool == true
        // 2026-10-17 (owner, chat stickers): a sticker's `text` is only the old-build fallback
        // (StickerSend), never a caption, so the label wins.
        if type == "sticker" { return StickerSend.label(emoji: d["emoji"] as? String) }
        // A view-once caption is never shown, and a caption otherwise wins, as at send.
        if !text.isEmpty, !viewOnce || type == "text" || type.isEmpty { return text }
        switch type {
        case "image": return viewOnce ? "View-once photo" : "📷 Photo"
        case "album":
            let n = (d["album"] as? [Any])?.count ?? 0
            return n > 1 ? "📷 \(n) Photos" : "📷 Photo"
        case "video": return "🎥 Video"
        case "audio": return viewOnce ? "🎤 One-time voice message" : "🎤 Voice message"
        case "file": return "📄 File"
        case "gif": return "GIF"
        case "call":
            let video = d["callVideo"] as? Bool == true
            if d["callOutcome"] as? String == "missed" { return video ? "📹 Missed video call" : "📞 Missed call" }
            return video ? "📹 Video call" : "📞 Call"
        default: return text
        }
    }

    /// ⛔ REPAIR A SUMMARY THAT WAS ALREADY BLANKED — owner, 2026-10-04: "where is this Say hello
    /// coming from, it's not a message I sent or received". Chats whose summary an older build
    /// recomputed to "" (a captionless photo, a call) still read "Say hello" although they have
    /// messages; `summaryText` only stops new ones. The chat list calls this once per chat per
    /// launch for a blank summary that has a sender (a truly new chat has none), and it rewrites
    /// the summary from the newest message, guarded like every other summary rewrite.
    private static var repairedSummaries = Set<String>()
    @MainActor static func repairBlankSummary(_ cid: String) {
        guard repairedSummaries.insert(cid).inserted else { return }
        let convRef = db.collection("conversations").document(cid)
        Task {
            await rewriteSummaryGuarded(convRef) {
                let d = (try? await convRef.getDocument())?.data()
                guard (d?["lastMessage"] as? String ?? "").isEmpty else { return nil }
                return await summaryOfNewest(convRef)
            }
        }
    }

    /// Write a recomputed chat-list summary only if nothing newer landed while it was computed.
    ///
    /// 2026-09-24 audit: a delete or an edit read "the newest message" and then wrote its summary
    /// with a plain update. A message sent in between had already set the summary correctly, and
    /// this write then put the older text back, on both phones, until the next message. Now the
    /// conversation's `updatedAt` (every send stamps it) is read before the recompute and checked
    /// again inside a transaction; if it moved, the summary is recomputed against the new newest
    /// message instead of written. `compute` returning nil means there is nothing to write.
    ///
    /// Offline, or if the transaction itself fails, it falls back to the plain write it replaces,
    /// which still queues until the connection returns.
    private static func rewriteSummaryGuarded(_ convRef: DocumentReference,
                                              _ compute: () async -> [String: Any]?) async {
        func version(_ d: [String: Any]?) -> String {
            switch d?["updatedAt"] {
            case let t as Timestamp: return "\(t.seconds).\(t.nanoseconds)"
            case let n as NSNumber:  return n.stringValue
            default:                 return ""
            }
        }
        for _ in 0..<3 {
            guard let before = try? await convRef.getDocument(source: .server) else {
                if let update = await compute() { try? await convRef.updateData(update) }
                return
            }
            let seen = version(before.data())
            guard let update = await compute() else { return }
            let wrote: Bool? = await withCheckedContinuation { (cont: CheckedContinuation<Bool?, Never>) in
                convRef.firestore.runTransaction({ txn, errPtr -> Any? in
                    do {
                        let now = try txn.getDocument(convRef)
                        guard version(now.data()) == seen else { return false }
                    } catch {
                        errPtr?.pointee = error as NSError
                        return nil
                    }
                    txn.updateData(update, forDocument: convRef)
                    return true
                }, completion: { result, error in
                    cont.resume(returning: error == nil ? (result as? Bool) : nil)
                })
            }
            switch wrote {
            case true?:  return
            case false?: continue   // a newer message landed: recompute against it
            case nil:
                try? await convRef.updateData(update)
                return
            }
        }
        // Lost three times in a row: messages are still arriving, and each one set its own summary.
    }

    /// Remove ONE item from an album message, for everyone. Reads the RAW stored album array and
    /// writes it back minus the item — never re-serialized through the client model, so the per-item
    /// encryption dicts survive byte-for-byte. An album emptied by its last deletion deletes the whole
    /// message (the author may; same rule as any own-message delete).
    private static func deleteAlbumItem(cid: String, parentId: String, index: Int) async -> Bool {
        let ref = db.collection("conversations").document(cid).collection("messages").document(parentId)
        do {
            let snap = try await ref.getDocument()
            guard var album = snap.data()?["album"] as? [[String: Any]], album.indices.contains(index) else {
                return false
            }
            let removed = album.remove(at: index)
            if album.isEmpty {
                // Last item: the whole message goes, and with it the pin/summary cleanup and the
                // Storage sweep that deleteMessage owns.
                return await deleteMessage(cid: cid, messageId: parentId)
            }
            try await ref.updateData(["album": album])
            // The removed item's own objects (photo, or a video plus its poster) are now orphaned —
            // nothing else would ever delete them. Best effort, after the write lands.
            for key in ["imageUrl", "videoUrl"] {
                if let s = removed[key] as? String, s.hasPrefix("http") {
                    try? await Storage.storage().safeReference(forURL: s)?.delete()
                }
            }
            return true
        } catch {
            #if DEBUG
            print("[deleteAlbumItem] refused for \(cid)/\(parentId)[\(index)]: \(error)")
            #endif
            return false
        }
    }

    /// 2026-09-24 feature-audit: an edit refused before it is written (the message was deleted).
    enum EditRefused: Error { case deleted }

    /// 2026-09-24 feature-audit: a message's earlier versions, oldest first, opened on this phone.
    /// Each entry is the text that version said and when it was written. A version sealed for a
    /// group roster this phone cannot open reads as the crypto layer's own "🔒" / "…" sentinels,
    /// which the sheet shows as unavailable rather than as garbage.
    static func editHistory(cid: String, messageId: String) async throws -> [(text: String, at: Date)] {
        let snap = try await db.collection("conversations").document(cid)
            .collection("messages").document(messageId).getDocument()
        let data = snap.data() ?? [:]
        guard data["deleted"] as? Bool != true else { return [] }
        let author = data["authorId"] as? String ?? ""
        return ((data["edits"] as? [[String: Any]]) ?? []).map { e in
            let clear = Crypto.shared.decrypt(e["t"] as? String ?? "", cid: cid, authorId: author)
            return (clear, (e["at"] as? Timestamp)?.dateValue() ?? Date.distantPast)
        }
    }

    /// Edit a text message in place: re-encrypt the new text and flag it edited.
    /// Server still never sees plaintext (same E2EE path as sendText).
    static func editMessage(cid: String, messageId: String, newText: String, group: [String]? = nil) async throws {
        let t = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        var members = await freshGroupMembers(cid, group)   // 2026-09-24 fix-all #111
        if members == nil, !cid.contains("_") { members = try await groupDocMembers(cid) }
        // Re-seal for the group (author = me, since only the author may edit) or the 1:1 pair.
        let cipher = members != nil
            ? try await Crypto.shared.sealForGroup(t, members: members!, cid: cid)
            : try await Crypto.shared.encryptForConversation(cid, t)
        let convRef = db.collection("conversations").document(cid)
        let msgRef = convRef.collection("messages").document(messageId)
        // 2026-09-24 feature-audit: EDIT HISTORY, like the reference app. The sealed text being
        // replaced is appended to `edits` (oldest first, at most 10, each {t, at}); the rules accept
        // only an append of the CURRENT stored text, so it is read from the document itself (the
        // local cache answers when offline). A tombstone is refused here as well as by the server.
        let snap = try await msgRef.getDocument()
        let data = snap.data() ?? [:]
        if data["deleted"] as? Bool == true { throw EditRefused.deleted }
        var edits = (data["edits"] as? [[String: Any]]) ?? []
        if let current = data["text"] as? String {
            let at = (data["editedAt"] as? Timestamp) ?? (data["createdAt"] as? Timestamp) ?? Timestamp(date: Date())
            edits.append(["t": current, "at": at])
        }
        // Oldest go first: the cap, then the document's 1 MiB ceiling (a long text edited often).
        func size(_ e: [[String: Any]]) -> Int { e.reduce(cipher.utf8.count) { $0 + (($1["t"] as? String)?.utf8.count ?? 0) } }
        while edits.count > 10 || (edits.count > 1 && size(edits) > 700_000) { edits.removeFirst() }
        var update: [String: Any] = ["text": cipher, "edited": true, "editedAt": FieldValue.serverTimestamp()]
        if size(edits) <= 700_000 { update["edits"] = edits }
        try await msgRef.updateData(update)
        // If this WAS the newest message, the chat list still shows the pre-edit text on both
        // phones until something else arrives (audit) — re-point the summary at the new wording.
        // 2026-09-24 audit: guarded, so a message that arrives mid-edit keeps its own summary.
        await rewriteSummaryGuarded(convRef) {
            let newest = try? await convRef.collection("messages")
                .order(by: "createdAt", descending: true).limit(to: 1).getDocuments()
            guard newest?.documents.first?.documentID == messageId else { return nil }
            // 2026-10-19 groups v2: an edit in the clear keeps its sender's name in the list.
            if !cid.contains("_"), !cipher.hasPrefix("enc") {
                return ["lastMessage": cipher, "lastPlainTag": Conversation.plainTag(cipher)]
            }
            return ["lastMessage": cipher]
        }
    }

    /// A privacy pref (defaults ON when never set).
    static func pref(_ key: String) -> Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }

    static func setTyping(_ cid: String, _ typing: Bool) async {
        guard pref("typingIndicators") else { return }   // privacy: don't broadcast typing
        // ON is a CHANGING string ("text-<seconds>") like recording's, not `true`: receivers
        // self-clear after 15s and only a value that changes the doc produces a snapshot, so a
        // >15s composing burst went silent on the other side (audit). Receivers accept Bool true
        // (older builds' writes) OR the "text" prefix.
        let v: Any = typing ? ("text-\(Int(Date().timeIntervalSince1970))" as Any) : (false as Any)
        try? await db.collection("conversations").document(cid)
            .setData(["typing": [uid: v]], merge: true)
    }

    /// Voice-note recording indicator — SAME field and privacy pref as typing, so the rules and
    /// reciprocity carry over unchanged. The ON value is a CHANGING string ("audio-<seconds>"):
    /// receivers self-clear after 15s and a voice note outlives that, so the sender refreshes
    /// every 10s — and only a value that actually changes the doc produces a snapshot.
    static func setRecording(_ cid: String, _ on: Bool) async {
        guard pref("typingIndicators") else { return }
        let v: Any = on ? ("audio-\(Int(Date().timeIntervalSince1970))" as Any) : (false as Any)
        try? await db.collection("conversations").document(cid)
            .setData(["typing": [uid: v]], merge: true)
    }

    /// My unread count for this conversation — read once on open (before reset) to
    /// anchor the "Unread Messages" divider.
    static func myUnread(_ cid: String) async -> Int {
        let snap = try? await db.collection("conversations").document(cid).getDocument()
        let m = snap?.data()?["unreadCount"] as? [String: Any]
        return (m?[uid] as? NSNumber)?.intValue ?? 0
    }

    static func resetUnread(_ cid: String) async {
        if OfficialChannel.isOfficial(cid) { OfficialChannelStore.shared.markRead(); return }
        let me = uid
        var update: [String: Any] = ["unreadCount.\(me)": 0]
        // 2026-09-24 decision D13: opening the chat also clears my Mark as Unread flag. Only when the
        // list shows it set, so the many resets a chat does while open stay the one-field write
        // they were. Writing the count to 0 also retires an old -1 flag.
        let marked = await MainActor.run {
            ConversationsRepository.shared.conversations.first { $0.id == cid }?.markedUnread[me] ?? false
        }
        if marked { update["markedUnread.\(me)"] = FieldValue.delete() }
        try? await db.collection("conversations").document(cid).updateData(update)
    }

    /// Manually flag a chat as unread — shows a plain DOT until reopened, never a number.
    ///
    /// It used to write `1`, and a `1` is a count: the chat list drew "1 unread message" for a
    /// conversation you had just read to the end. Marking something unread is a reminder to yourself,
    /// not a claim that somebody sent you something.
    ///
    /// 2026-09-24 decision D13: ITS OWN FLAG NOW, `markedUnread.<me> = true`. Minus one on
    /// `unreadCount` was the flag before this, and it shared arithmetic with the real counter: the
    /// other person's next message did -1 + 1 = 0 and wiped both the reminder and the new message.
    /// The count stays a real number; the rules let a member write only their own key of this map
    /// (needs the rules deploy first). An old -1 still reads as marked (see
    /// `Conversation.manuallyUnread`) until the chat is next opened.
    static func markUnread(_ cid: String) async {
        if OfficialChannel.isOfficial(cid) { OfficialChannelStore.shared.markUnread(); return }
        try? await db.collection("conversations").document(cid)
            .updateData(["markedUnread.\(uid)": true])
    }

    /// Mark this conversation read up to now (drives the other person's read receipts).
    static func markRead(_ cid: String) async {
        // Nobody to send a receipt to. The channel's own read state is the watermark in the person's
        // private state document, which `resetUnread` already moved.
        if OfficialChannel.isOfficial(cid) { return }
        guard pref("readReceipts") else { return }   // privacy: don't send read receipts
        try? await db.collection("conversations").document(cid)
            .setData(["lastRead": [uid: FieldValue.serverTimestamp()]], merge: true)
    }

    // Read receipts on the reference model, read from its source 2026-08-12 (owner's "our ticks
    // feel slow" report — the old shape here was a 2s cooldown TIMER, and fast two-phone chatting
    // lives entirely inside a 2s window, so the sender's ✓✓ ran seconds behind):
    //
    // NO TIMER. The first receipt is written IMMEDIATELY; while one write is IN FLIGHT, newer
    // reads collapse into a single trailing write sent the moment it completes. Read state is
    // monotonic — the newest write covers every earlier message — so a 20-message burst is still
    // only a couple of writes, but the FIRST tick-flip has zero added latency and a burst's last
    // is at most one round trip behind. Coalesce on flight, never on a clock.
    private static var readInFlight: Set<String> = []
    private static var readTrailing: Set<String> = []

    /// 2026-10-20 (owner): called by `SendQueue` on `FirestoreHub.swapped`. A read receipt or a send
    /// turn waiting on the stuck client never finishes, and `readInFlight` would hold that chat's
    /// receipts back for the rest of the process. Both start over on the fresh client.
    @MainActor
    static func releaseAfterSwap() {
        let owed = readInFlight.union(readTrailing)
        readInFlight.removeAll()
        readTrailing.removeAll()
        SendTurn.releaseAll()
        owed.forEach { markReadThrottled($0) }
    }
    @MainActor
    static func markReadThrottled(_ cid: String) {
        if readInFlight.contains(cid) { readTrailing.insert(cid); return }
        readInFlight.insert(cid)
        Task {
            await markRead(cid)
            await MainActor.run {
                readInFlight.remove(cid)
                if readTrailing.remove(cid) != nil { markReadThrottled(cid) }
            }
        }
    }

    // MARK: - Voice-note played receipts

    /// Tell the sender their voice note was actually heard. Another mainstream messenger turns the mic
    /// icon blue for this, and it was the one voice signal we sent nothing for.
    ///
    /// ⚠️ GATED ON `readReceipts`, WHICH IS DELIBERATELY *UNLIKE* THAT APP. Theirs fires even with read
    /// receipts switched off — there is no setting that hides a voice-note play receipt over there. Ours
    /// is a receipt like any other, and somebody who has told us not to send receipts has told us not to
    /// send this one. Privacy lives on the WRITE here, exactly as it does in `markRead`.
    ///
    /// A WATERMARK, not a per-message flag: one small field on the conversation document the chat is
    /// already listening to, instead of a write against every note. Same shape as `lastRead`.
    ///
    /// Throttled on the same 2s shape as `markReadThrottled` and for the same reason — a run of four
    /// notes played back to back would otherwise be four billed writes, and the value is monotonic so
    /// the newest one covers them all.
    private static var playedCooldownUntil: [String: Date] = [:]
    private static var playedPending: [String: Double] = [:]
    @MainActor
    static func markVoicePlayedThrottled(_ cid: String, createdAtMillis: Double) {
        guard pref("readReceipts") else { return }
        if OfficialChannel.isOfficial(cid) { return }   // no conversation document to write to
        // Never move the mark backwards: playing an OLD note after a new one must not un-hear the new one.
        playedPending[cid] = max(playedPending[cid] ?? 0, createdAtMillis)
        let now = Date()
        if let until = playedCooldownUntil[cid], until > now { return }
        playedCooldownUntil[cid] = now.addingTimeInterval(2)
        flushVoicePlayed(cid)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.05) {
            if playedPending[cid] != nil { markVoicePlayedThrottled(cid, createdAtMillis: 0) }
        }
    }

    @MainActor
    private static func flushVoicePlayed(_ cid: String) {
        guard let ms = playedPending.removeValue(forKey: cid), ms > 0 else { return }
        let me = uid
        Task {
            try? await db.collection("conversations").document(cid)
                .setData(["lastPlayedVoice": [me: ms]], merge: true)
        }
    }

    // THE OFFICIAL CHANNEL HAS NO CONVERSATION DOCUMENT. Its per-person state (muted, pinned,
    // archived, cleared) lives in one small document the person owns, so these five actions are
    // routed here rather than at every call site. Doing it at the call sites would have meant an
    // `if official` in the chat list, the archive screen, the context menu, the swipe actions and the
    // mute sheet — five chances to miss one and leave a button that looks alive and does nothing.
    /// Owner, 2026-10-08: archive / mute / pin used `try?`, so a refused write snapped back with no
    /// word and never woke the recovery. Now the error is logged, handed to SessionRecovery, and the
    /// caller gets false. Callers that ignore the result behave as before.
    private static func settingWrite(_ what: String, _ cid: String, _ data: [String: Any]) async -> Bool {
        do {
            try await db.collection("conversations").document(cid).setData(data, merge: true)
            return true
        } catch {
            print("[Recovery] \(what) write failed: \(error)")
            await MainActor.run { SessionRecovery.noteRefusal(error, what) }
            return false
        }
    }

    /// Chats unpinned on this phone this session, so the limit sees the unpin before the server
    /// echo does (`setPinned`). A later pin of the same chat takes it out again.
    @MainActor static var justUnpinned = Set<String>()

    @discardableResult
    static func setPinned(_ cid: String, _ value: Bool) async -> Bool {
        // ⛔ AT MOST `pinned_chats_max` PINNED CHATS (owner 2026-10-19: 3, set from the admin panel).
        // Counted on this phone: the pins are per-chat fields, which no rule can count across chats.
        if value {
            let full: Bool = await MainActor.run {
                let me = uid
                let max = AppLimits.shared.pinnedChatsMax
                // ⛔ ONLY THE PINS HE CAN SEE, AND AN UNPIN COUNTS AT ONCE — owner 2026-10-21: "I
                // unpinned one, it still says up to 3". Archived, cleared and request chats keep their
                // pin flag but are not in the Pinned section, and an unpin only reached this list when
                // the server echoed it; both were counted against him.
                let all = ConversationsRepository.shared.conversations
                // An unpin the server has now echoed no longer needs remembering.
                Self.justUnpinned = Self.justUnpinned.filter { id in all.first { $0.id == id }?.isPinned(me) == true }
                let pinned = all
                    .filter { c in
                        !OfficialChannel.isOfficial(c.id) && c.id != cid && c.isPinned(me)
                            && !c.isArchived(me) && !c.isCleared(me)
                            && !Self.justUnpinned.contains(c.id)
                            && MessageRequests.stance(c, myUid: me) != .incoming
                    }.count
                    // The Fariin channel only when it is actually in the list.
                    + (OfficialChannelStore.shared.state.pinned && OfficialChannelStore.shared.listEntry != nil
                       && !OfficialChannel.isOfficial(cid) ? 1 : 0)
                guard pinned >= max else { return false }
                let alert = UIAlertController(title: nil,
                                              message: "You can pin up to \(max) chats. Unpin one to pin this chat.",
                                              preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "OK", style: .cancel))
                WebLink.topViewController()?.present(alert, animated: true)
                return true
            }
            if full { return false }
        }
        if OfficialChannel.isOfficial(cid) { OfficialChannelStore.shared.setPinned(value); return true }
        await MainActor.run {
            if value { Self.justUnpinned.remove(cid) } else { Self.justUnpinned.insert(cid) }
        }
        guard value else { return await settingWrite("pin", cid, ["pinnedBy": [uid: value]]) }
        // ⛔ A NEW PIN GOES TO THE TOP (owner 2026-10-19: it landed 4th). Without a `pinOrder` the
        // rank was the chat's last-message time, so an older chat sank below the pins already there.
        // It now takes a rank above every other pin's (`Conversation.pinRank`, higher = higher up).
        let rank: Double = await MainActor.run {
            let me = uid
            let top = ConversationsRepository.shared.conversations
                .filter { $0.id != cid && $0.isPinned(me) }
                .map { $0.pinRank(me) }.max() ?? 0
            return max(top + 1, Date().timeIntervalSince1970 * 1000)
        }
        return await settingWrite("pin", cid, ["pinnedBy": [uid: true], "pinOrder": [uid: rank]])
    }

    /// Per-user manual order value for a pinned chat (fractional indexing).
    static func setPinOrder(_ cid: String, _ value: Double) async {
        try? await db.collection("conversations").document(cid)
            .setData(["pinOrder": [uid: value]], merge: true)
    }

    /// Pin (or clear, with nil) a message in a conversation — shared by both members.
    static func setPinnedMessage(_ cid: String, _ messageId: String?) async {
        try? await db.collection("conversations").document(cid)
            .setData(["pinnedMessageId": messageId ?? ""], merge: true)
    }
    /// Up to 5 pinned messages (array). Add/remove individually.
    static func addPinnedMessage(_ cid: String, _ messageId: String) async {
        try? await db.collection("conversations").document(cid)
            .setData(["pinnedMessageIds": FieldValue.arrayUnion([messageId])], merge: true)
    }
    static func removePinnedMessage(_ cid: String, _ messageId: String) async {
        try? await unpin(cid, messageId)
    }
    /// The same write, with its error: the pinned bar's Unpin says why a refused unpin came back
    /// (owner 2026-10-13: "unpin is not working", and the `try?` above had been throwing the reason away).
    static func unpin(_ cid: String, _ messageId: String) async throws {
        try await db.collection("conversations").document(cid)
            .setData(["pinnedMessageIds": FieldValue.arrayRemove([messageId])], merge: true)
    }

    @discardableResult
    static func setArchived(_ cid: String, _ value: Bool) async -> Bool {
        if OfficialChannel.isOfficial(cid) { OfficialChannelStore.shared.setArchived(value); return true }
        return await settingWrite("archive", cid, ["archivedBy": [uid: value]])
    }

    @discardableResult
    static func setMuted(_ cid: String, _ value: Bool) async -> Bool {
        if OfficialChannel.isOfficial(cid) { OfficialChannelStore.shared.setMuted(value); return true }
        let until: Double = value ? 9_999_999_999_999 : 0
        return await settingWrite("mute", cid, ["mutedBy": [uid: until]])
    }

    /// Mute until a specific epoch-ms time (0 = unmute, far-future = always).
    @discardableResult
    static func setMute(_ cid: String, until: Double) async -> Bool {
        if OfficialChannel.isOfficial(cid) {
            // ⛔ TIMED NOW — owner, 2026-09-29: the channel's Mute offers the same 1 hour … Always as
            // any chat. It used to be a plain on/off. The channel still STARTS muted (Always); only
            // a mute its reader chose with an end runs out.
            let on = until > Date().timeIntervalSince1970 * 1000
            await MainActor.run { OfficialChannelStore.shared.setMuted(on, until: on ? until : nil) }
            return true
        }
        return await settingWrite("mute", cid, ["mutedBy": [uid: until]])
    }

    /// Shared mute-duration options. Pass nil for "Always".
    static func muteUntil(_ hours: Double?) -> Double {
        guard let hours else { return 9_999_999_999_999 }
        return Date().timeIntervalSince1970 * 1000 + hours * 3_600_000
    }

    /// Human label for a disappearing timer (shared by the info screens + system notice).
    // Compact form for tight rows: 30s · 5m · 8h · 1d · 4w.
    static func disappearShortLabel(_ seconds: Int) -> String {
        guard seconds > 0 else { return "Off" }
        let units: [(Int, String)] = [(604_800, "w"), (86_400, "d"), (3_600, "h"), (60, "m"), (1, "s")]
        for (size, suffix) in units where seconds % size == 0 { return "\(seconds / size)\(suffix)" }
        for (size, suffix) in units where seconds >= size { return "\(seconds / size)\(suffix)" }
        return "\(seconds)s"
    }

    static func disappearLabel(_ seconds: Int) -> String {
        guard seconds > 0 else { return "Off" }
        let units: [(Int, String)] = [(604_800, "week"), (86_400, "day"),
                                      (3_600, "hour"), (60, "minute"), (1, "second")]
        // Prefer a unit the value divides into evenly (clean label like "8 hours"); otherwise fall back
        // to the largest unit that fits. Handles every preset AND any custom value.
        for (size, name) in units where seconds % size == 0 {
            let n = seconds / size
            return "\(n) \(name)\(n == 1 ? "" : "s")"
        }
        for (size, name) in units where seconds >= size {
            let n = seconds / size
            return "\(n) \(name)\(n == 1 ? "" : "s")"
        }
        return "\(seconds) seconds"
    }

    /// Set the per-chat disappearing-message timer (seconds; 0 = off). Shared by both.
    /// NEVER silent (the standard rule): both sides get a centered system notice in the chat
    /// saying who changed it — one member must not be able to flip it secretly.
    /// 2026-10-19: answers whether the timer is now `seconds`. A refused write (a member without
    /// the right, no connection) returns false and posts NO notice, so the chat never claims a
    /// change that did not happen; the caller shows the alert.
    @discardableResult
    static func setDisappear(_ cid: String, seconds: Int) async -> Bool {
        let ref = db.collection("conversations").document(cid)
        let current = ((try? await ref.getDocument())?.data()?["disappearSeconds"] as? NSNumber)?.intValue ?? 0
        guard current != seconds else { return true }   // no change → no write, no duplicate notice
        do {
            try await ref.setData(["disappearSeconds": seconds], merge: true)
        } catch {
            return false
        }
        let name = await MainActor.run { ProfileStore.shared.me?.name ?? "Someone" }
        // ⛔ "<name> set disappearing message time to 1 week." — owner, 2026-08-25, replacing
        // "turned on disappearing messages (8 hours)". This string is what the chat LIST shows and
        // what an older build renders; the chat itself re-words it per reader from
        // `disappearSeconds` (see `ThreadView.systemRow`), which is why the value travels too.
        let text = seconds > 0
            ? "\(name) set disappearing message time to \(disappearLabel(seconds))."
            : "\(name) turned off disappearing messages."
        try? await writeSystemMessage(cid: cid, text: text, extra: ["disappearSeconds": seconds])
        return true
    }

    /// Restricted chat (owner, 2026-10-03): ONE switch for BOTH members that sets every restriction
    /// together (his second ruling the same day: one switch, not three). Never silent, for the
    /// timer's reason above: both sides get a notice naming who changed it.
    ///
    /// ⛔ EACH PERSON'S OWN SWITCH — owner, 2026-10-03, the reference app's private-chat rule, read
    /// from its API and client: `restrictedBy[me]` is mine alone (the rules refuse a write to the
    /// other key), and the chat is restricted while either is on. Turning MINE off is immediate;
    /// theirs can only be asked for (`requestUnrestrict`). The three older shared fields are cleared
    /// on the way, so an older build's switch does not outlive this one.
    static func setMyRestriction(_ cid: String, on: Bool) async {
        let ref = db.collection("conversations").document(cid)
        let data = (try? await ref.getDocument())?.data() ?? [:]
        let mine = ((data["restrictedBy"] as? [String: Any])?[uid] as? Bool) ?? false
        guard mine != on else { return }
        var fields: [String: Any] = ["restrictedBy.\(uid)": on ? true : FieldValue.delete()]
        for r in ChatRestriction.allCases where data[r.rawValue] != nil { fields[r.rawValue] = false }
        // Turning mine on answers any request I had made of them: it is moot now.
        if on, (data["restrictRequest"] as? [String: Any])?["by"] as? String == uid {
            fields["restrictRequest"] = FieldValue.delete()
        }
        guard (try? await ref.updateData(fields)) != nil else { return }
        let name = await MainActor.run { ProfileStore.shared.me?.name ?? "Someone" }
        try? await writeSystemMessage(cid: cid, text: "\(name) turned \(on ? "on" : "off") Restricted chat.")
    }

    /// ⛔ ROLE — owner 2026-10-18: an admin gives a member a short tag in the group ("🎨 Designer").
    /// Replaces the self-set Member Label of the same day: members never set their own. The owner
    /// may set anyone's; an admin needs Change group info and never touches the owner's
    /// (`Conversation.canSetRole`, firestore.rules `roleWriteOK`). nil or empty text removes it.
    /// `roleEdit` names the one person the write is about, as `adminEdit` does for the admin team:
    /// the rules cannot pick the changed key out of the map on their own.
    static func setRole(cid: String, uid member: String, text: String, emoji: String?,
                        color: String? = nil) async throws {
        let clean = GroupRole.clean(text)
        let mark = emoji.map { GroupRole.fit($0, max: GroupRole.maxEmoji) } ?? ""
        var role: [String: Any] = ["text": clean]
        if !mark.isEmpty { role["emoji"] = mark }
        if let color, GroupRole.rgb(color) != nil { role["color"] = color }
        try await db.collection("conversations").document(cid).updateData([
            "roles.\(member)": clean.isEmpty ? FieldValue.delete() : role,
            "roleEdit": ["uid": member, "by": uid],
        ])
    }

    /// ⛔ RESTRICTED GROUP — owner 2026-10-18, Group Settings. The same restriction a 1:1 has (no
    /// forwarding, copying, saving or screenshots), but a GROUP rule: an admin with the change-info
    /// right switches it for everyone (firestore.rules), there is no per-person switch and no request
    /// step. On writes the admin's own key; off clears every key, so it is off whoever turned it on.
    /// Never silent, as the 1:1 switch is not.
    static func setGroupRestricted(_ cid: String, on: Bool) async throws {
        let ref = db.collection("conversations").document(cid)
        var fields: [String: Any] = [
            "restrictedBy": on ? [uid: true] : FieldValue.delete(),
            "restrictRequest": FieldValue.delete(),
            "updatedAt": FieldValue.serverTimestamp(),
        ]
        for r in ChatRestriction.allCases { fields[r.rawValue] = false }
        try await ref.updateData(fields)
        try? await writeSystemMessage(cid: cid, text: "\(myName()) turned \(on ? "on" : "off") Restricted group.")
    }

    /// The reference app's consent step: they switched it on, so I can only ASK them to turn it off.
    /// One pending request per chat, which they accept or decline (`answerUnrestrict`); it lapses
    /// after `ChatRestrictions.requestLifetime` if they do neither.
    static func requestUnrestrict(_ cid: String) async {
        let ref = db.collection("conversations").document(cid)
        let request: [String: Any] = ["by": uid, "at": FieldValue.serverTimestamp()]
        guard (try? await ref.updateData(["restrictRequest": request])) != nil else { return }
        let name = await MainActor.run { ProfileStore.shared.me?.name ?? "Someone" }
        try? await writeSystemMessage(cid: cid, text: "\(name) asked to turn off Restricted chat.",
                                      extra: ["restrictRequest": true])
    }

    /// Their request, answered by me. Accepting turns MY switch off (theirs, if any, stays theirs);
    /// declining keeps it on. Either way the request is closed and the chat says what happened.
    static func answerUnrestrict(_ cid: String, accept: Bool) async {
        let ref = db.collection("conversations").document(cid)
        var fields: [String: Any] = ["restrictRequest": FieldValue.delete()]
        if accept { fields["restrictedBy.\(uid)"] = FieldValue.delete() }
        guard (try? await ref.updateData(fields)) != nil else { return }
        let name = await MainActor.run { ProfileStore.shared.me?.name ?? "Someone" }
        try? await writeSystemMessage(cid: cid, text: accept ? "\(name) turned off Restricted chat."
                                                             : "\(name) kept Restricted chat on.")
    }

    /// Returns false when the write was refused, so a caller can say so (2026-09-24 audit).
    /// ⚠️ Blocking someone you never chatted with was a silent no-op: there is no conversation doc,
    /// this merge write would CREATE one without `users`, the create rule refuses it, and `try?`
    /// hid that. Creating the chat here is not the fix — every new 1:1 is born a request to the
    /// other person. Where a block should live when no chat exists is a backend decision.
    ///
    /// 2026-09-24 decision D8: THAT DECISION. A block lives on my ACCOUNT, `users/{me}/blocked/{them}`,
    /// so anyone can be blocked, chat or no chat; the rules read it to refuse their calls. Their new
    /// chat and messages still land (silent block): `ConversationsRepository` hides them and
    /// `onNewMessage` skips the push. When a chat exists its `blockedBy`/`blockedAt` are written too, as
    /// before (the chat list, the thread and the push all read those). `cid` is still the pair id,
    /// `convId(me, them)`, whether or not that chat exists. The conversation write is an UPDATE now,
    /// so a missing chat is "not found" (fine) instead of a create the rules refuse.
    ///
    /// 2026-09-26 block rebuild: ONE write, to my private list, done by `BlockList.setBlocked`
    /// (serialised per person, history recorded on unblock, stories revoked on block). The chat's
    /// copy of the block is gone: the other person could read it.
    @discardableResult
    static func setBlocked(_ cid: String, _ value: Bool) async -> Bool {
        let me = uid
        let other = cid.contains("_") ? (cid.split(separator: "_").map(String.init).first { $0 != me } ?? "") : ""
        guard !other.isEmpty else { return false }
        return await BlockList.shared.setBlocked(other, value)
    }

    /// File an abuse report. App Store Guideline 1.2 requires users to be able to
    /// flag objectionable content and report abusive users. Stored server-side in
    /// `reports` for the operator to review and act on within 24h; the reported
    /// person is never notified. `reason` is "message" or "user".
    static func report(reportedUid: String, cid: String,
                       messageId: String? = nil, messageText: String? = nil,
                       reason: String) async {
        var data: [String: Any] = [
            "reporterUid": uid,
            "reportedUid": reportedUid,
            "cid": cid,
            "reason": reason,
            "createdAt": Date().timeIntervalSince1970 * 1000,
            "handled": false,
        ]
        if let messageId { data["messageId"] = messageId }
        if let messageText, !messageText.isEmpty { data["messageText"] = messageText }
        // 2026-09-24 fix-all: counted for the rules' daily report limit, only once it has landed.
        if (try? await db.collection("reports").addDocument(data: data)) != nil {
            await MessageRequests.countDaily("reports")
        }
    }

    /// "Delete for me" — hides the thread until a newer message arrives (clearedAt).
    static func deleteForMe(_ cid: String) async {
        if OfficialChannel.isOfficial(cid) { OfficialChannelStore.shared.clearHistory(); return }
        try? await db.collection("conversations").document(cid).setData([
            "clearedAt": [uid: Date().timeIntervalSince1970 * 1000],
            "unreadCount": [uid: 0],
        ], merge: true)
    }

    // MARK: - Discovery

    /// THE EXACT NAME, OR NOTHING. There is no directory to browse behind this.
    ///
    /// It used to QUERY the users collection for `handleLower == h`, which needed `list` permission
    /// on every profile in Fariin — and `list` in Firestore is not "read a few", it is "run any query
    /// you like", so granting it for this one lookup published the whole user base to anybody with an
    /// account. `searchUsers` below then used exactly that to return twenty people for two typed
    /// letters, which is a directory you can walk alphabetically.
    ///
    /// Now it reads ONE document, `usernames/{name}`, whose rule allows `get` and never `list`. You
    /// must already know the whole name; there is no way to ask what names exist. That is another
    /// mainstream messenger's model, in their words: "strangers must type your exact, full username."
    ///
    /// Two reads instead of one query, and the second one is a plain document fetch the app makes
    /// everywhere else, so it is cached like any other profile.
    /// `allowSelf` is for the PROFILE LINK PREVIEW and nothing else. Sharing your own link has to
    /// draw your own card; every other caller is trying to start a chat, where finding yourself is
    /// the bug this guard exists to stop.
    static func findByHandle(_ handle: String, allowSelf: Bool = false) async -> UserProfile? {
        var h = handle.trimmingCharacters(in: .whitespaces).lowercased()
        if h.hasPrefix("@") { h.removeFirst() }   // users type "@ayaan"
        guard !h.isEmpty else { return nil }
        // Typed text goes straight into `document(_:)`, which RAISES an ObjC exception `try?` cannot
        // catch for an id with "/", ".", "..", "__x__" or over the length limit: typing one in
        // @search crashed the app (2026-09-24 audit). None of those can be a handle.
        guard !h.contains("/"), h != ".", h != "..", !(h.hasPrefix("__") && h.hasSuffix("__")),
              h.utf8.count <= 128 else { return nil }
        do {
            let nameDoc = try await db.collection("usernames").document(h).getDocument()
            guard let nd = nameDoc.data(), let owner = nd["uid"] as? String, !owner.isEmpty else { return nil }
            // A RELEASED NAME STILL NAMES ITS OLD OWNER. `claimUsername` keeps the record with a
            // `releasedAt` stamp so nobody can snatch the name during the grace period — it is a
            // hold, not a pointer. Following it would let somebody reach you by a name you gave up.
            if let released = nd["releasedAt"], !(released is NSNull) { return nil }
            let d = try await db.collection("users").document(owner).getDocument()
            guard let data = d.data() else { return nil }
            let u = UserProfile(id: d.documentID, data: data)
            // An account scheduled for deletion is invisible: it must not be findable or startable a
            // chat with while it sits in its grace period. Filtered HERE rather than in a security
            // rule because Firestore rules are not filters - a data-dependent read rule would make
            // this whole read fail instead of skipping the row.
            if u.isAwaitingDeletion { return nil }
            // Banned from the admin panel: not findable by strangers (the server's search agrees).
            if u.banned, u.id != uid { return nil }
            if !allowSelf { guard u.id != uid else { return nil } }   // never "find" yourself
            return ProfileStore.indexed(u, fresh: !d.metadata.isFromCache)   // warms photo / call-privacy / verification
        } catch {
            print("findByHandle failed:", error)
            return nil
        }
    }

    /// ⛔ PREFIX SEARCH IS BACK, ON THE SERVER — owner, 2026-10-04: "global search like the reference
    /// app". The reference sends every query to its server's people search (20 results) and shows
    /// them under the local ones.
    ///
    /// ⚠️ WHY IT WAS REMOVED STILL HOLDS, AND THIS IS HOW IT IS ANSWERED. The old version was a
    /// CLIENT prefix query over profiles: two letters, twenty accounts, walk the alphabet at Firestore
    /// speed, and it needed `list` on every profile. Now `usernames` stays `list: false`, and the
    /// server's `searchUsernames` answers one prefix at a time: 3 characters at least, 20 names at
    /// most, 30 searches a minute per account, uids and handles only. Each profile is then read
    /// through the normal `users/{uid}` get, with the same deletion filter `findByHandle` applies.
    /// Do not move the query back onto the client.
    ///
    /// Server unreachable or refusing (old functions, rate limit): falls back to the exact lookup.
    /// First of `op` and a `seconds` timer; nil when the timer wins (the slow read is cancelled).
    private static func firstOf(_ seconds: Double, _ op: @escaping () async -> Any?) async -> Any? {
        await withTaskGroup(of: Any?.self) { g in
            g.addTask { await op() }
            g.addTask { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)); return nil }
            let first = await g.next() ?? nil
            g.cancelAll()
            return first
        }
    }

    static func searchUsers(prefix: String) async -> [UserProfile] {
        var q = prefix.trimmingCharacters(in: .whitespaces).lowercased()
        if q.hasPrefix("@") { q.removeFirst() }
        guard !q.isEmpty else { return [] }
        // ⛔ A SHORT USERNAME IS STILL FINDABLE — owner, 2026-10-11: typing "V" never found @V,
        // because under the server's 3-character prefix minimum this returned nothing at all. Below
        // it the answer is the EXACT handle only (one `usernames/{q}` get, the lookup that already
        // exists), so a short name is reachable without opening prefix browsing of short strings.
        guard q.count >= 3 else {
            guard let u = await findByHandle(q), u.id != uid else { return [] }
            return [u]
        }
        // ⛔ BOUNDED — owner 2026-10-15: "search user loading takes a long time". The callable had
        // Firebase's 70s default, so a slow or stuck connection held the skeleton for over a minute.
        // 8s, then the exact-handle fallback below; the profile reads after it get 5s each, and a
        // read that misses its deadline uses the copy already on the phone.
        let callable = Functions.functions(region: "me-central1").httpsCallable("searchUsernames")
        callable.timeoutInterval = 8
        guard let res = try? await callable.call(["query": q]),
              let rows = (res.data as? [String: Any])?["results"] as? [[String: Any]] else {
            return (await findByHandle(q)).map { [$0] } ?? []
        }
        let uids = rows.compactMap { $0["uid"] as? String }.filter { $0 != uid }
        // In the server's order (exact handle first), fetched together.
        let found = await withTaskGroup(of: (Int, UserProfile?, Bool).self) { group in
            for (i, owner) in uids.enumerated() {
                group.addTask {
                    let ref = db.collection("users").document(owner)
                    let read = await Self.firstOf(5) { try? await ref.getDocument() } as? DocumentSnapshot
                    let snap: DocumentSnapshot?
                    if let read { snap = read } else { snap = try? await ref.getDocument(source: .cache) }
                    guard let d = snap, let data = d.data() else { return (i, nil, false) }
                    let u = UserProfile(id: d.documentID, data: data)
                    return (i, u.isAwaitingDeletion || u.banned ? nil : u, !d.metadata.isFromCache)
                }
            }
            var out = [(Int, UserProfile, Bool)]()
            for await (i, u, fresh) in group { if let u { out.append((i, u, fresh)) } }
            return out.sorted { $0.0 < $1.0 }.map { ($0.1, $0.2) }
        }
        // warms photo / privacy / verification, as findByHandle does; a cached copy never overrules
        return found.map { ProfileStore.indexed($0.0, fresh: $0.1) }
    }
}

extension Array {
    /// Bounds-checked read. Used where a DISPLAY slot is mapped back to a real album index and the
    /// two lists can differ in length (an item hidden by "Delete for Me").
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

/// An album is ONE message holding N media items. Anywhere media is listed ITEM BY ITEM (the All Media
/// grid, the profile strip) an album must be EXPANDED into per-item synthetic Messages - with the SAME
/// "<messageId>-<index>" ids the chat's album tiles register in MediaOpenRects, so tapping an item
/// flies from its tile and a drag-close lands back on it. Mirrors ThreadView.openAlbumItem's synthetic
/// construction exactly; do not let the two drift. Non-album messages pass through unchanged, so
/// callers can flatMap unconditionally.
extension Message {
    func expandedGalleryItems(cid: String) -> [Message] {
        guard isAlbum else { return [self] }
        return album.enumerated().compactMap { i, it -> Message? in
            // "Delete for Me" on ONE album photo stores this synthetic id, but nothing consulted
            // HiddenMessages per item, so the photo stayed everywhere and came back on relaunch —
            // a destructive button that silently did nothing (audit). Honored here covers the All
            // Media grid, the profile strip and the group media page in one place; the chat's own
            // album grid applies the same test where it builds its tiles.
            if HiddenMessages.isHidden("\(id)-\(i)") { return nil }
            if it.isVideo {
                guard let vurl = it.videoUrl, let venc = it.videoEnc else { return nil }
                let d: [String: Any] = ["type": "video", "videoUrl": vurl, "enc": venc.asDict,
                                        "thumbUrl": it.imageUrl, "thumbEnc": it.enc.asDict,
                                        "authorId": authorId, "width": it.width, "height": it.height,
                                        "duration": it.duration]
                return Message(id: "\(id)-\(i)", data: d, cid: cid, crypto: Crypto.shared)
            }
            let d: [String: Any] = ["type": "image", "imageUrl": it.imageUrl, "enc": it.enc.asDict,
                                    "authorId": authorId, "width": it.width, "height": it.height]
            return Message(id: "\(id)-\(i)", data: d, cid: cid, crypto: Crypto.shared)
        }
    }
}

// ⛔ BUILD 965 CRASH (owner's .ips, 2026-10-17 22:00): deleting a message ran `reference(forURL:)` on
// one of its links, and that call does not throw on a link it cannot parse, it ASSERTS and kills the
// app. A message can carry links that are not ours (a GIF from the GIF service, a sticker, a link
// preview). Every Storage lookup by URL goes through this: our bucket's https link or gs://, else nil.
extension Storage {
    func safeReference(forURL url: String) -> StorageReference? {
        guard let u = URL(string: url), let scheme = u.scheme?.lowercased() else { return nil }
        if scheme == "gs" { return u.host?.isEmpty == false ? reference(forURL: url) : nil }
        guard scheme == "https", u.host?.lowercased() == "firebasestorage.googleapis.com",
              u.path.hasPrefix("/v0/b/"), u.path.contains("/o/") else { return nil }
        return reference(forURL: url)
    }
}
