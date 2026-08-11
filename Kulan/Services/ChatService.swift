import Foundation
import UIKit
import ImageIO       // stripping metadata from an image UIKit could not decode
import PDFKit
import FirebaseAuth
import FirebaseFirestore
import FirebaseStorage
import FirebaseFunctions

/// Write-side operations (port of the RN Db writes). All E2EE goes through Crypto.
enum ChatService {
    static var db: Firestore { Firestore.firestore() }
    // Falls back to AuthService.shared.uid so this is NEVER empty when signed in (incl. the
    // Firebase-free demo, where currentUser is nil but AuthService holds "demo-me"). An empty uid
    // built dotted field paths like "unreadCount." — an INVALID Firestore path that raises an ObjC
    // NSException (which `try?` can't catch) → crash on chat open.
    static var uid: String { Auth.auth().currentUser?.uid ?? AuthService.shared.uid ?? "" }

    static func convId(_ a: String, _ b: String) -> String {
        [a, b].sorted().joined(separator: "_")
    }

    // MARK: - Username (handle) policy: lowercase a-z, 0-9, underscore; 3-30 chars.
    static let handleAllowed = Set("abcdefghijklmnopqrstuvwxyz0123456789_")
    /// Strip anything not allowed as the user types (no spaces, dashes, emojis…).
    static func sanitizeHandle(_ raw: String) -> String {
        String(raw.lowercased().filter { handleAllowed.contains($0) }.prefix(Limits.usernameMaxChars))
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
        h.count >= Limits.usernameMinChars && h.count <= Limits.usernameMaxChars && h.allSatisfy { handleAllowed.contains($0) }
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
            if answered {
                seed["startedBy"] = uid
                seed["accepted"] = false
            }
        }
        try await ref.setData(seed, merge: true)
        return cid
    }

    /// Create a GROUP conversation: random doc id, N members, creator is the sole admin.
    /// Returns the new conversation id.
    @discardableResult
    static func createGroup(title: String, memberIds: [String], avatarUrl: String? = nil) async throws -> String {
        var memberSet = Set(memberIds); memberSet.insert(uid)
        let users = Array(memberSet)

        var names: [String: String] = [:]
        var photos: [String: String] = [:]
        for u in users {
            if let p = await ProfileStore.shared.fetch(u) {
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
            "title": title.trimmingCharacters(in: .whitespaces),
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
        try await ref.setData(data)
        // Greet the new group with a system event (also gives the chat list a real preview).
        try? await writeSystemMessage(cid: ref.documentID, text: "\(myName()) created the group")
        return ref.documentID
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
                                progressId: String? = nil) async throws -> String {
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
                    try await putFileReportingProgress(ref, from: tmp, metadata: meta, progressId: progressId)
                    return try await ref.downloadURL().absoluteString
                } catch {
                    attempt += 1
                    guard attempt < 4, !Task.isCancelled, isRetryableUpload(error) else { throw error }
                    await Backoff.sleep(attempt: attempt, base: 2, cap: 30)
                }
            }
        }
    }

    /// `putFileAsync` is the reason the bubble could only ever show a spinner: the async wrapper
    /// throws the task away, and the task is the only thing that reports bytes. The observable form
    /// gives the same result and hands back progress on the way.
    private static func putFileReportingProgress(_ ref: StorageReference, from tmp: URL,
                                                 metadata: StorageMetadata,
                                                 progressId: String?) async throws {
        let task = ref.putFile(from: tmp, metadata: metadata)
        // Exactly one resume: success and failure are mutually exclusive, and observers are torn
        // down in both so a retry's task cannot report into a continuation that has already returned.
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                if let progressId {
                    task.observe(.progress) { snap in
                        guard let p = snap.progress, p.totalUnitCount > 0 else { return }
                        let fraction = Double(p.completedUnitCount) / Double(p.totalUnitCount)
                        Task { @MainActor in UploadProgress.shared.report(progressId, fraction) }
                    }
                }
                task.observe(.success) { _ in
                    task.removeAllObservers()
                    cont.resume()
                }
                task.observe(.failure) { snap in
                    task.removeAllObservers()
                    cont.resume(throwing: snap.error ?? NSError(domain: StorageErrorDomain, code: -1))
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

    /// A refusal is not a network problem. Retrying an unauthorized or over-quota upload only burns
    /// the user's data and delays the error they actually need to see, so those fail immediately.
    /// Anything we cannot identify is treated as transport and retried.
    private static func isRetryableUpload(_ error: Error) -> Bool {
        let ns = error as NSError
        guard ns.domain == StorageErrorDomain else { return true }
        switch StorageErrorCode(rawValue: ns.code) {
        case .unauthorized, .unauthenticated, .quotaExceeded, .cancelled, .objectNotFound: return false
        default: return true
        }
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

    // MARK: - Group management (each writes a system event message + updates the conv)

    /// Add members + a "X added Y" system message. New members can't read prior history
    /// (their per-message wraps don't exist) — honest and expected, like sender keys.
    /// Returns the display names of added members who have NO published key yet (they won't see
    /// messages until they open Fariin) so the UI can warn the adder honestly.
    @discardableResult
    static func addGroupMembers(cid: String, add: [String]) async throws -> [String] {
        let newOnes = add.filter { !$0.isEmpty }
        guard !newOnes.isEmpty else { return [] }
        let convRef = db.collection("conversations").document(cid)
        // Enforce the 30-member cap on growth (the rules only cap it at create time).
        var currentCount = ConversationsRepository.shared.conversations.first(where: { $0.id == cid })?.users.count ?? 0
        if currentCount == 0 {
            currentCount = ((try? await convRef.getDocument())?.data()?["users"] as? [String])?.count ?? 0
        }
        if currentCount + newOnes.count > 30 {
            throw NSError(domain: "ChatService", code: 30,
                          userInfo: [NSLocalizedDescriptionKey: "A group can have at most 30 members."])
        }
        var update: [String: Any] = [
            "users": FieldValue.arrayUnion(newOnes),
            "updatedAt": FieldValue.serverTimestamp(),
        ]
        // Re-adding a removed member lifts their ban — but ONLY when an ADMIN adds. A non-admin member
        // (membersCanAdd) writes through a field-whitelisted rule branch that forbids `bannedUids`, so
        // touching it would reject the whole add. Admins write through the any-field admin branch.
        let iAmGroupAdmin = ConversationsRepository.shared.conversations.first(where: { $0.id == cid })?.isAdmin(uid) ?? false
        if iAmGroupAdmin { update["bannedUids"] = FieldValue.arrayRemove(newOnes) }
        var addedNames: [String] = []
        var keyless: [String] = []
        for u in newOnes {
            if let p = await ProfileStore.shared.fetch(u) {
                let nm = p.name.isEmpty ? p.handle : p.name
                update["names.\(u)"] = nm
                addedNames.append(nm)
                if let ph = p.photoUrl, !ph.isEmpty { update["photos.\(u)"] = ph }
                if (p.publicKeyB64 ?? "").isEmpty { keyless.append(nm) }   // hasn't opened Fariin
            } else {
                addedNames.append("New member")   // fallback so the event isn't blank
                keyless.append("New member")
            }
            update["unreadCount.\(u)"] = 0
        }
        try await convRef.updateData(update)
        if !addedNames.isEmpty {
            try await writeSystemMessage(cid: cid, text: "\(myName()) added \(addedNames.joined(separator: ", "))")
        }
        return keyless
    }

    /// Remove a member (admin) + system message.
    static func removeGroupMember(cid: String, uid removed: String, name: String) async throws {
        let convRef = db.collection("conversations").document(cid)
        try await writeSystemMessage(cid: cid, text: "\(myName()) removed \(name)")
        try await convRef.updateData([
            "users": FieldValue.arrayRemove([removed]),
            "admins": FieldValue.arrayRemove([removed]),
            // Ban the removed user so they can't rejoin via an invite link (a "kick" must stick). Re-adding
            // them (Add Members) or approving a join request lifts the ban. Clear their admin/restriction state.
            "bannedUids": FieldValue.arrayUnion([removed]),
            "adminRights.\(removed)": FieldValue.delete(),
            "restrictedFlags.\(removed)": FieldValue.delete(),
            "restrictedUntil.\(removed)": FieldValue.delete(),
            "updatedAt": FieldValue.serverTimestamp(),
        ])
    }

    /// Leave a group (remove self). Writes the system message FIRST (while still a member,
    /// so the message-create rule passes), then removes self.
    static func leaveGroup(cid: String) async throws {
        let convRef = db.collection("conversations").document(cid)
        // If I'm the LAST admin, promote a remaining member first (while I'm still an admin)
        // so the group never ends up with no one who can manage it.
        if let conv = ConversationsRepository.shared.conversations.first(where: { $0.id == cid }),
           conv.admins.filter({ $0 != uid }).isEmpty,
           let heir = conv.users.first(where: { $0 != uid }) {
            try? await convRef.updateData(["admins": FieldValue.arrayUnion([heir])])
            // Tell everyone who inherited admin (otherwise the heir never learns).
            try? await writeSystemMessage(cid: cid, text: "\(conv.names[heir] ?? "A member") is now an admin")
        }
        try await writeSystemMessage(cid: cid, text: "\(myName()) left")
        try await convRef.updateData([
            "users": FieldValue.arrayRemove([uid]),
            "admins": FieldValue.arrayRemove([uid]),
            "updatedAt": FieldValue.serverTimestamp(),
        ])
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

    /// Toggle a member permission (admin): "membersCanAdd" or "membersCanEditInfo".
    static func setGroupPermission(cid: String, key: String, _ value: Bool) async throws {
        try await db.collection("conversations").document(cid).updateData([
            key: value,
            "updatedAt": FieldValue.serverTimestamp(),
        ])
    }

    /// Set the group description / "about" (admin). No system message (low-signal change).
    static func setGroupDescription(cid: String, text: String) async throws {
        let desc = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500))
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
        try await writeSystemMessage(cid: cid, text: "\(myName()) renamed the group to “\(t)”")
    }

    /// Promote a member to admin (admin) + system message.
    static func promoteGroupAdmin(cid: String, uid promoted: String, name: String) async throws {
        let convRef = db.collection("conversations").document(cid)
        try await convRef.updateData([
            "admins": FieldValue.arrayUnion([promoted]),
            // An admin is never restricted — clear any lingering mute so a later demote can't silently
            // re-apply a stale "forever" restriction.
            "restrictedFlags.\(promoted)": FieldValue.delete(),
            "restrictedUntil.\(promoted)": FieldValue.delete(),
            "updatedAt": FieldValue.serverTimestamp(),
        ])
        try await writeSystemMessage(cid: cid, text: "\(myName()) made \(name) an admin")
    }

    /// Demote an admin back to a regular member (admin) + system message. Clears any per-flag grant.
    static func demoteGroupAdmin(cid: String, uid demoted: String, name: String) async throws {
        let convRef = db.collection("conversations").document(cid)
        try await convRef.updateData([
            "admins": FieldValue.arrayRemove([demoted]),
            "adminRights.\(demoted)": FieldValue.delete(),
            "updatedAt": FieldValue.serverTimestamp(),
        ])
        try await writeSystemMessage(cid: cid, text: "\(myName()) removed \(name) as admin")
    }

    /// Set an admin's granted per-flag rights (owner-only in the UI). `rights` is a subset of
    /// Conversation.Right raw values; an empty/omitted map means the admin has ALL rights (legacy).
    static func setAdminRights(cid: String, uid: String, rights: [String]) async throws {
        try await db.collection("conversations").document(cid).updateData([
            "admins": FieldValue.arrayUnion([uid]),   // granting rights implies admin
            "adminRights.\(uid)": rights,
            "updatedAt": FieldValue.serverTimestamp(),
        ])
    }

    /// Restrict a member with an auto-expiring timeout (the reference app bannedRights model). `flags` is a
    /// subset of Conversation.Restrict raw values; `until` is an absolute ms timestamp (0 = clear).
    static func restrictMember(cid: String, uid: String, name: String, flags: [String], until: Double) async throws {
        let convRef = db.collection("conversations").document(cid)
        if flags.isEmpty || until <= Date().timeIntervalSince1970 * 1000 {
            try await convRef.updateData([
                "restrictedFlags.\(uid)": FieldValue.delete(),
                "restrictedUntil.\(uid)": FieldValue.delete(),
                "updatedAt": FieldValue.serverTimestamp(),
            ])
            try await writeSystemMessage(cid: cid, text: "\(myName()) lifted the restrictions on \(name)")
        } else {
            try await convRef.updateData([
                "restrictedFlags.\(uid)": flags,
                "restrictedUntil.\(uid)": until,
                "updatedAt": FieldValue.serverTimestamp(),
            ])
            try await writeSystemMessage(cid: cid, text: "\(myName()) restricted \(name)")
        }
    }

    /// Convenience: fully mute a member (block all sending) for `seconds` (0 = forever).
    static func muteMember(cid: String, uid: String, name: String, seconds: Double) async throws {
        let forever = 60.0 * 60 * 24 * 365 * 50   // ~50y sentinel = "forever"
        let until = (Date().timeIntervalSince1970 + (seconds > 0 ? seconds : forever)) * 1000
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
    private static func writeSystemMessage(cid: String, text: String) async throws {
        let convRef = db.collection("conversations").document(cid)
        let msgRef = convRef.collection("messages").document()
        let batch = db.batch()
        batch.setData([
            "text": text,
            "authorId": uid,
            "type": "system",
            "createdAt": FieldValue.serverTimestamp(),
        ], forDocument: msgRef)
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
            if let members { return try? await Crypto.shared.encryptForGroup(s, members: members) }
            return try? await Crypto.shared.encryptForConversation(cid, s)
        }
        guard let cu = await seal(p.url) else { return nil }
        var d: [String: Any] = ["url": cu]
        if let ct = await seal(p.title) { d["title"] = ct }
        if let cd = await seal(p.desc) { d["desc"] = cd }
        if let jpeg = p.imageJPEG {
            do {
                let cipher: Data, meta: EncMeta
                if let members { (cipher, meta) = try await Crypto.shared.encryptBytesForGroup(jpeg, members: members) }
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

    static func sendText(cid: String, text: String, replyTo: ReplyRef? = nil, clientId: String? = nil, group: [String]? = nil, mentions: [String] = [], preview: OutgoingLinkPreview? = nil, forwarded: Bool = false) async throws {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        // Group path: per-member encryption + unread fan-out. 1:1 path below is untouched.
        // Resolve members even if the caller didn't pass them (e.g. the very first message
        // right after creation, before the conversations listener has the doc). A group cid
        // is a random id with no "_", so that distinguishes it from a 1:1 "uidA_uidB" cid.
        var members = group
        if members == nil, !cid.contains("_") {
            let snap = try? await db.collection("conversations").document(cid).getDocument()
            members = snap?.data()?["users"] as? [String]
        }
        if let members {
            try await sendGroupText(cid: cid, members: members, text: t, replyTo: replyTo, clientId: clientId, mentions: mentions, preview: preview, forwarded: forwarded)
            return
        }

        let cipher = try await Crypto.shared.encryptForConversation(cid, t)
        var replyEnc: [String: Any]?
        if let r = replyTo {
            let rc = try await Crypto.shared.encryptForConversation(cid, r.text)
            var e: [String: Any] = ["id": r.id, "authorId": r.authorId, "text": rc]
            if r.isStatus { e["isStatus"] = true }
            if let thumb = r.storyThumbUrl, !thumb.isEmpty { e["storyThumb"] = thumb }   // plaintext story URL (not E2EE)
            replyEnc = e
        }

        let other = cid.split(separator: "_").map(String.init).first { $0 != uid } ?? ""
        let convRef = db.collection("conversations").document(cid)

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
        }
        try await convRef.setData(convSeed, merge: true)

        let msgRef = convRef.collection("messages").document()
        let batch = db.batch()
        var msg: [String: Any] = [
            "text": cipher,
            "authorId": uid,
            "createdAt": FieldValue.serverTimestamp(),
            "clientTs": Date().timeIntervalSince1970 * 1000,   // tap time — display order is send order
        ]
        if let clientId { msg["clientId"] = clientId }   // lets the client reconcile its optimistic copy
        if let replyEnc { msg["replyTo"] = replyEnc }
        if !mentions.isEmpty { msg["mentions"] = mentions }
        if forwarded { msg["forwarded"] = true }
        if let preview, let lp = await sealLinkPreview(preview, cid: cid, members: nil, msgId: msgRef.documentID) {
            msg["linkPreview"] = lp
        }
        batch.setData(msg, forDocument: msgRef)
        batch.updateData([
            "lastMessage": cipher,
            "lastSender": uid,                 // drives the read-receipt ticks in the chat list
            "updatedAt": FieldValue.serverTimestamp(),
            "unreadCount.\(other)": FieldValue.increment(Int64(1)),
        ], forDocument: convRef)
        try await batch.commit()
    }

    /// Group text send: encrypt once per member, fan out the unread increment to everyone
    /// but me. The conversation already exists (created by createGroup), so no users write.
    private static func sendGroupText(cid: String, members: [String], text t: String,
                                      replyTo: ReplyRef?, clientId: String?, mentions: [String] = [],
                                      preview: OutgoingLinkPreview? = nil, forwarded: Bool = false) async throws {
        let cipher = try await Crypto.shared.encryptForGroup(t, members: members)
        var replyEnc: [String: Any]?
        if let r = replyTo {
            let rc = try await Crypto.shared.encryptForGroup(r.text, members: members)
            var e: [String: Any] = ["id": r.id, "authorId": r.authorId, "text": rc]
            if r.isStatus { e["isStatus"] = true }
            if let thumb = r.storyThumbUrl, !thumb.isEmpty { e["storyThumb"] = thumb }
            replyEnc = e
        }
        let convRef = db.collection("conversations").document(cid)
        let msgRef = convRef.collection("messages").document()
        let batch = db.batch()
        var msg: [String: Any] = [
            "text": cipher,
            "authorId": uid,
            "createdAt": FieldValue.serverTimestamp(),
            "clientTs": Date().timeIntervalSince1970 * 1000,   // tap time — display order is send order
        ]
        if let clientId { msg["clientId"] = clientId }
        if let replyEnc { msg["replyTo"] = replyEnc }
        if !mentions.isEmpty { msg["mentions"] = mentions }
        if forwarded { msg["forwarded"] = true }
        if let preview, let lp = await sealLinkPreview(preview, cid: cid, members: members, msgId: msgRef.documentID) {
            msg["linkPreview"] = lp
        }
        batch.setData(msg, forDocument: msgRef)
        var convUpdate: [String: Any] = [
            "lastMessage": cipher,
            "lastSender": uid,
            "updatedAt": FieldValue.serverTimestamp(),
        ]
        for m in members where m != uid {
            convUpdate["unreadCount.\(m)"] = FieldValue.increment(Int64(1))
        }
        batch.updateData(convUpdate, forDocument: convRef)
        try await batch.commit()
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
        let newSize = CGSize(width: img.size.width * scale, height: img.size.height * scale)
        let resized = UIGraphicsImageRenderer(size: newSize).image { _ in
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

    static func sendImage(cid: String, data rawData: Data, replyTo: ReplyRef? = nil, clientId: String? = nil, group: [String]? = nil, viewOnce: Bool = false, caption: String = "", forwarded: Bool = false) async throws {
        let clientTs = Date().timeIntervalSince1970 * 1000   // captured BEFORE the upload — order is when send was tapped
        let data = sendJPEG(rawData)
        var members = group
        if members == nil, !cid.contains("_") {
            let snap = try? await db.collection("conversations").document(cid).getDocument()
            members = snap?.data()?["users"] as? [String]
        }
        let convRef = db.collection("conversations").document(cid)
        let cipher: Data, meta: EncMeta
        // THE CONVERSATION TOUCH IS NOT A PREREQUISITE OF THE UPLOAD. It only ensures the 1:1 doc
        // carries `users` + `updatedAt`, which the message write needs — not the Storage put. It was
        // awaited inline, so a full round trip stood between the finished ciphertext and the first
        // byte leaving the phone. Started here, awaited just before the batch that actually needs it.
        var ensureConv: Task<Void, Error>?
        if let members {
            (cipher, meta) = try await Crypto.shared.encryptBytesForGroup(data, members: members)
        } else {
            (cipher, meta) = try await Crypto.shared.encryptBytes(cid, data)
            let other = cid.split(separator: "_").map(String.init).first { $0 != uid } ?? ""
            ensureConv = Task {
                try await convRef.setData(["users": [uid, other],
                                           "updatedAt": FieldValue.serverTimestamp()], merge: true)
            }
        }

        let msgRef = convRef.collection("messages").document()

        // THE BYTES GO NOW. Everything below this line — the caption seal, the reply seal, the
        // BlurHash — was computed AFTER the upload returned, and none of it has ever depended on the
        // upload. On a photo with a caption and a reply that is three more seals plus a BlurHash
        // encode (which decodes and downsamples the image again) added onto the end of the slowest
        // step, instead of hidden underneath it. They run together now, so the send costs the upload
        // and not the upload plus the paperwork.
        async let uploadedURL = uploadEncrypted(cipher,
                                                to: "chat/\(cid)/\(msgRef.documentID).enc",
                                                progressId: clientId)

        // Caption travels INSIDE the image message (the caption is the message body) — sealed
        // exactly like a text message.
        var captionCipher = ""
        let trimmedCaption = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedCaption.isEmpty {
            if let members {
                captionCipher = (try? await Crypto.shared.encryptForGroup(trimmedCaption, members: members)) ?? ""
            } else {
                captionCipher = (try? await Crypto.shared.encryptForConversation(cid, trimmedCaption)) ?? ""
            }
        }

        // Encrypt the reply snippet the same way as the conversation (group vs 1:1) —
        // replying to a message WITH a photo, like every standard messenger.
        var replyEnc: [String: Any]?
        if let r = replyTo {
            let rc: Any
            if let members { rc = try await Crypto.shared.encryptForGroup(r.text, members: members) }
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
                ? (try? await Crypto.shared.encryptForGroup(hash, members: members!))
                : (try? await Crypto.shared.encryptForConversation(cid, hash))
        }

        // Now collect the upload, and the conversation touch the message write depends on.
        let url = try await uploadedURL
        try await ensureConv?.value
        // Seed the cache with the plaintext image under its URL so when the optimistic bubble
        // reconciles to the server message, SecureImageView renders instantly (no shimmer / re-download).
        if let ui = UIImage(data: rawData) { DiskImageCache.shared.store(ui, for: url, owned: true) }

        let batch = db.batch()
        var imgMsg: [String: Any] = [
            "type": "image", "imageUrl": url, "enc": meta.asDict, "text": captionCipher,
            "authorId": uid, "createdAt": FieldValue.serverTimestamp(), "clientTs": clientTs,
        ]
        if let replyEnc { imgMsg["replyTo"] = replyEnc }
        if let clientId { imgMsg["clientId"] = clientId }   // reconcile the optimistic bubble
        if viewOnce { imgMsg["viewOnce"] = true }           // view-once photo
        if forwarded { imgMsg["forwarded"] = true }
        if let ui = sized {                                 // natural aspect ratio
            imgMsg["width"] = Double(ui.size.width); imgMsg["height"] = Double(ui.size.height)
        }
        // Sealed above, while the upload was in flight.
        if let blurSealed, !blurSealed.isEmpty { imgMsg["blurhash"] = blurSealed }
        batch.setData(imgMsg, forDocument: msgRef)
        // A VIEW-ONCE photo publishes NO thumbnail to the conversation doc (audit): lastImageUrl +
        // lastImageEnc are a decryptable copy both sides keep forever, and the chat list rendered it
        // as the row thumbnail before the recipient ever opened it and long after the single view was
        // spent — which is the whole promise of view-once, broken. The blurhash on the line above was
        // already exempt for exactly this reason; this path was missed.
        var convUpdate: [String: Any] = [
            "lastMessage": viewOnce ? "View-once photo" : "📷 Photo",
            "lastSender": uid,
            "updatedAt": FieldValue.serverTimestamp(),
        ]
        if !viewOnce {
            convUpdate["lastImageUrl"] = url
            convUpdate["lastImageEnc"] = meta.asDict
        }
        if let members {
            for m in members where m != uid { convUpdate["unreadCount.\(m)"] = FieldValue.increment(Int64(1)) }
        } else {
            let other = cid.split(separator: "_").map(String.init).first { $0 != uid } ?? ""
            convUpdate["unreadCount.\(other)"] = FieldValue.increment(Int64(1))
        }
        batch.updateData(convUpdate, forDocument: convRef)
        try await batch.commit()
    }

    /// Send 2+ photos as ONE album message (grid + one caption), as standard messengers do. Each photo is
    /// E2EE'd + uploaded separately; a single message doc carries the array of {imageUrl, enc, w, h}.
    static func sendAlbum(cid: String, images: [Data], caption: String, clientId: String? = nil, group: [String]? = nil) async throws {
        let clientTs = Date().timeIntervalSince1970 * 1000   // captured BEFORE the uploads
        var members = group
        if members == nil, !cid.contains("_") {
            let snap = try? await db.collection("conversations").document(cid).getDocument()
            members = snap?.data()?["users"] as? [String]
        }
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
        // watch" (owner). Signal's own ceiling is twelve concurrent uploads and our album caps at
        // ten, so releasing them together sits inside their number.
        //
        // Re-sorted by index afterwards: a task group finishes in whatever order the network feels
        // like, and an album that arrives shuffled is worse than a slow one.
        let tiles: [AlbumTile] = try await withThrowingTaskGroup(of: AlbumTile?.self) { group in
            for (i, raw) in images.enumerated() {
                group.addTask {
                    // A whole-message Cancel cancels the group; each tile lands on it here.
                    try Task.checkCancellation()
                    let itemKey = clientId.map { MediaSend.itemKey($0, i) }
                    if let itemKey, await MediaSend.shared.isItemCancelled(itemKey) { return nil }
                    let data = sendJPEG(raw)
                    let cipher: Data, meta: EncMeta
                    if let sealMembers { (cipher, meta) = try await Crypto.shared.encryptBytesForGroup(data, members: sealMembers) }
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
            }
            var acc: [AlbumTile] = []
            for try await tile in group { if let tile { acc.append(tile) } }
            return acc
        }
        .sorted { $0.index < $1.index }

        // NO "kind" KEY, deliberately. This path predates mixed albums and the reader treats a tile
        // without one as a photo; adding it here would be a silent format change.
        let items: [[String: Any]] = tiles.map {
            ["imageUrl": $0.imageUrl, "enc": $0.imageEnc.asDict, "width": $0.width, "height": $0.height]
        }
        // Every tile was X'd → there is no album left to send.
        guard !items.isEmpty else { throw CancellationError() }

        // Caption sealed like a text body (one body for the album).
        var captionCipher = ""
        let trimmed = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            if let members { captionCipher = (try? await Crypto.shared.encryptForGroup(trimmed, members: members)) ?? "" }
            else { captionCipher = (try? await Crypto.shared.encryptForConversation(cid, trimmed)) ?? "" }
        }

        let batch = db.batch()
        var msg: [String: Any] = [
            "type": "album", "album": items, "text": captionCipher,
            "authorId": uid, "createdAt": FieldValue.serverTimestamp(), "clientTs": clientTs,
        ]
        // The album's FIRST tile, blurred, for the same reason a photo and now a video carry one:
        // without it the grid falls through to the grey shimmer while its bytes arrive. One hash for
        // the message, matching the model, which holds a single `blurhash` per message.
        if let firstData = images.first, let ui = UIImage(data: firstData), let hash = BlurHash.encode(ui) {
            let sealed = members != nil
                ? (try? await Crypto.shared.encryptForGroup(hash, members: members!))
                : (try? await Crypto.shared.encryptForConversation(cid, hash))
            if let sealed, !sealed.isEmpty { msg["blurhash"] = sealed }
        }
        if let clientId { msg["clientId"] = clientId }
        // The LAST moment Cancel can win. Without this, a Cancel that lands while the caption is
        // being sealed still commits, and the album he cancelled appears a minute later anyway.
        try Task.checkCancellation()
        batch.setData(msg, forDocument: msgRef)
        var convUpdate: [String: Any] = [
            "lastMessage": "📷 \(items.count) Photos", "lastSender": uid,
            "updatedAt": FieldValue.serverTimestamp(),
        ]
        // Refresh the chat-list thumbnail (photo parity with sendImage) — without this the list
        // kept showing a PREVIOUS photo's thumb next to "N Photos".
        if let first = items.first, let u = first["imageUrl"], let e = first["enc"] {
            convUpdate["lastImageUrl"] = u
            convUpdate["lastImageEnc"] = e
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
        var members = group
        if members == nil, !cid.contains("_") {
            let snap = try? await db.collection("conversations").document(cid).getDocument()
            members = snap?.data()?["users"] as? [String]
        }
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
            if let sealMembers { return try await Crypto.shared.encryptBytesForGroup(data, members: sealMembers) }
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
                        VideoCache.store(mp4, for: "\(msgId)-\(i)")
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
            if let members { captionCipher = (try? await Crypto.shared.encryptForGroup(trimmed, members: members)) ?? "" }
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
                ? (try? await Crypto.shared.encryptForGroup(hash, members: members!))
                : (try? await Crypto.shared.encryptForConversation(cid, hash))
            if let sealed, !sealed.isEmpty { msg["blurhash"] = sealed }
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
        var members = group
        if members == nil, !cid.contains("_") {
            let snap = try? await db.collection("conversations").document(cid).getDocument()
            members = snap?.data()?["users"] as? [String]
        }
        let convRef = db.collection("conversations").document(cid)
        let cipher: Data, meta: EncMeta
        if let members {
            (cipher, meta) = try await Crypto.shared.encryptBytesForGroup(data, members: members)
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
        let url = try await uploadEncrypted(cipher, to: "chat/\(cid)/\(msgRef.documentID).m4a.enc")

        // Encrypt the reply snippet the same way as the conversation (group vs 1:1).
        var replyEnc: [String: Any]?
        if let r = replyTo {
            let rc: Any
            if let members { rc = try await Crypto.shared.encryptForGroup(r.text, members: members) }
            else { rc = try await Crypto.shared.encryptForConversation(cid, r.text) }
            replyEnc = ["id": r.id, "authorId": r.authorId, "text": rc]
        }

        let batch = db.batch()
        var msg: [String: Any] = [
            // A one-time note carries NO waveform, the same instinct as the view-once photo
            // skipping its blurhash: the preview machinery must not keep a shape of something
            // meant to exist for one listen.
            "type": "audio", "audioUrl": url, "duration": duration, "waveform": viewOnce ? [] : waveform,
            "enc": meta.asDict, "text": "", "authorId": uid, "createdAt": FieldValue.serverTimestamp(),
            "clientTs": clientTs,
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
    }

    /// Encrypt + send a VIDEO message. Same E2EE pipeline as photos: the transcoded mp4
    /// AND its thumbnail are sealed separately; the server stores only ciphertext. The
    /// thumbnail rides on the message (and the chat-list preview) so bubbles render
    /// instantly without downloading the video.
    static func sendVideo(cid: String, video: Data, thumbnail: Data, duration: Double,
                          width: Double, height: Double, caption: String = "", clientId: String? = nil, group: [String]? = nil, forwarded: Bool = false) async throws {
        let clientTs = Date().timeIntervalSince1970 * 1000   // captured BEFORE the upload
        var members = group
        if members == nil, !cid.contains("_") {
            let snap = try? await db.collection("conversations").document(cid).getDocument()
            members = snap?.data()?["users"] as? [String]
        }
        // Caption travels INSIDE the video message (sealed like a text message), same as images.
        var captionCipher = ""
        let trimmedCaption = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedCaption.isEmpty {
            if let m = members { captionCipher = (try? await Crypto.shared.encryptForGroup(trimmedCaption, members: m)) ?? "" }
            else { captionCipher = (try? await Crypto.shared.encryptForConversation(cid, trimmedCaption)) ?? "" }
        }
        let convRef = db.collection("conversations").document(cid)
        let vidCipher: Data, vidMeta: EncMeta, thCipher: Data, thMeta: EncMeta
        // Same as sendImage: the conversation touch is a prerequisite of the MESSAGE write, not of
        // the uploads, so it no longer stands in front of them.
        var ensureConv: Task<Void, Error>?
        if let members {
            (vidCipher, vidMeta) = try await Crypto.shared.encryptBytesForGroup(video, members: members)
            (thCipher, thMeta) = try await Crypto.shared.encryptBytesForGroup(thumbnail, members: members)
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
        async let videoUp = uploadEncrypted(vidCipher, to: "chat/\(cid)/\(msgRef.documentID).mp4.enc", progressId: clientId)
        async let thumbUp = uploadEncrypted(thCipher, to: "chat/\(cid)/\(msgRef.documentID).thumb.enc")
        let videoUrl = try await videoUp
        let thumbUrl = try await thumbUp
        try await ensureConv?.value
        // Seed the cache so the optimistic bubble reconciles with no shimmer (photo parity).
        if let ui = UIImage(data: thumbnail) { DiskImageCache.shared.store(ui, for: thumbUrl, owned: true) }

        let batch = db.batch()
        var msg: [String: Any] = [
            "type": "video", "videoUrl": videoUrl, "enc": vidMeta.asDict,
            "thumbUrl": thumbUrl, "thumbEnc": thMeta.asDict,
            "duration": duration, "width": width, "height": height,
            "text": captionCipher, "authorId": uid, "createdAt": FieldValue.serverTimestamp(),
            "clientTs": clientTs,
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
                ? (try? await Crypto.shared.encryptForGroup(hash, members: members!))
                : (try? await Crypto.shared.encryptForConversation(cid, hash))
            if let sealed, !sealed.isEmpty { msg["blurhash"] = sealed }
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
        try await batch.commit()
        // Mailman model: the SENDER's copy lives on their own device from day one — the
        // server object exists only to deliver, and the recipient deletes it on pickup.
        VideoCache.store(video, for: msgRef.documentID)
    }

    /// Encrypt + send a document/file. Contents are E2EE (same pipeline as photos); the file
    /// NAME is metadata stored in the clear (like image dimensions) so the bubble can label it.
    static func sendFile(cid: String, data rawData: Data, fileName: String, clientId: String? = nil, group: [String]? = nil, forwarded: Bool = false) async throws {
        let clientTs = Date().timeIntervalSince1970 * 1000   // captured BEFORE the upload
        var members = group
        if members == nil, !cid.contains("_") {
            let snap = try? await db.collection("conversations").document(cid).getDocument()
            members = snap?.data()?["users"] as? [String]
        }
        let convRef = db.collection("conversations").document(cid)
        let cipher: Data, meta: EncMeta
        if let members {
            (cipher, meta) = try await Crypto.shared.encryptBytesForGroup(rawData, members: members)
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
                (tCipher, tMeta) = (try? await Crypto.shared.encryptBytesForGroup(preview, members: members)) ?? (nil, nil)
            } else {
                (tCipher, tMeta) = (try? await Crypto.shared.encryptBytes(cid, preview)) ?? (nil, nil)
            }
            guard let tCipher, let tMeta,
                  let tUrl = try? await uploadEncrypted(
                      tCipher, to: "chat/\(cid)/\(msgRef.documentID).filethumb.enc") else { return [:] }
            return ["thumbUrl": tUrl, "thumbEnc": tMeta.asDict]
        }()
        let url = try await uploadEncrypted(cipher, to: "chat/\(cid)/\(msgRef.documentID).file.enc", progressId: clientId)
        let thumbFields: [String: Any] = await thumbTask
        let batch = db.batch()
        var msg: [String: Any] = [
            "type": "file", "fileUrl": url, "fileName": fileName, "fileSize": rawData.count,
            "enc": meta.asDict, "text": "", "authorId": uid, "createdAt": FieldValue.serverTimestamp(),
            "clientTs": clientTs,
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
    static func sendGif(cid: String, url: String, width: Double, height: Double, clientId: String? = nil, group: [String]? = nil, forwarded: Bool = false) async throws {
        var members = group
        if members == nil, !cid.contains("_") {
            let snap = try? await db.collection("conversations").document(cid).getDocument()
            members = snap?.data()?["users"] as? [String]
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

    /// `clientId` matches the optimistic bubble ForwardPicker parked in PendingOutbox, so the echo
    /// REPLACES that bubble rather than landing beside it as a duplicate.
    static func forwardMessage(_ m: Message, from sourceCid: String, to targetCid: String,
                               clientId: String? = nil) async throws {
        if m.isImage {
            let bytes: Data
            if let local = m.localImageData {
                bytes = local
            } else if let s = m.imageUrl, let url = URL(string: s), let meta = m.enc,
                      let (cipher, _) = try? await MediaSession.shared.data(from: url),
                      let dec = await Crypto.shared.decryptBytes(sourceCid, cipher: cipher, meta: meta) {
                bytes = dec
            } else { throw ForwardError.sourceUnavailable }
            try await sendImage(cid: targetCid, data: bytes, clientId: clientId, caption: m.text, forwarded: true)
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
            try await sendMixedAlbum(cid: targetCid, items: items, caption: m.text, clientId: clientId, forwarded: true)
        } else if m.isAudio {
            guard let s = m.audioUrl, let url = URL(string: s), let meta = m.enc,
                  let (cipher, _) = try? await MediaSession.shared.data(from: url),
                  let dec = await Crypto.shared.decryptBytes(sourceCid, cipher: cipher, meta: meta)
            else { throw ForwardError.sourceUnavailable }
            try await sendAudio(cid: targetCid, data: dec, duration: m.duration ?? 0, waveform: m.waveform, clientId: clientId, forwarded: true)
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
                                width: m.width ?? 720, height: m.height ?? 720, caption: m.text, clientId: clientId, forwarded: true)
        } else if m.isGif {
            guard let gifUrl = m.imageUrl, !gifUrl.isEmpty else { throw ForwardError.sourceUnavailable }
            try await sendGif(cid: targetCid, url: gifUrl, width: m.width ?? 200, height: m.height ?? 200, clientId: clientId, forwarded: true)
        } else if m.isFile {
            guard let s = m.fileUrl, let url = URL(string: s), let meta = m.enc,
                  let (cipher, _) = try? await MediaSession.shared.data(from: url),
                  let dec = await Crypto.shared.decryptBytes(sourceCid, cipher: cipher, meta: meta)
            else { throw ForwardError.sourceUnavailable }
            try await sendFile(cid: targetCid, data: dec, fileName: m.fileName ?? "File", clientId: clientId, forwarded: true)
        } else {
            try await sendText(cid: targetCid, text: m.text, clientId: clientId, forwarded: true)
        }
    }

    /// Recent image messages in a conversation (for the Shared Media section).
    /// Filters client-side to avoid needing a composite index.
    // Warm cache so the profile's "All Media" strip renders INSTANTLY on re-entry instead of popping
    // in after a fresh Firestore round-trip each time ("coming late / not stable").
    @MainActor private static var sharedMediaCache: [String: [Message]] = [:]
    @MainActor static func cachedSharedMedia(_ cid: String) -> [Message]? { sharedMediaCache[cid] }

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
        for doc in snap.documents {
            let m = Message(id: doc.documentID, data: doc.data(), cid: cid, crypto: Crypto.shared)
            guard m.isAudio, !m.viewOnce, !m.deleted else { continue }
            guard AudioCache.url(for: m.id) == nil else { continue }
            guard let urlStr = m.audioUrl, let url = URL(string: urlStr), let meta = m.enc else { continue }
            guard let (cipher, _) = try? await MediaSession.shared.data(from: url),
                  let data = await Crypto.shared.decryptBytes(cid, cipher: cipher, meta: meta) else { continue }
            AudioCache.store(data, for: m.id)
        }
    }

    static func galleryContent(_ cid: String, limit: Int = 400) async -> [Message] {
        do {
            let snap = try await db.collection("conversations").document(cid).collection("messages")
                .order(by: "createdAt", descending: true)
                .limit(to: limit).getDocuments()
            return snap.documents
                .map { Message(id: $0.documentID, data: $0.data(), cid: cid, crypto: Crypto.shared) }
        } catch {
            return []
        }
    }

    /// Delete all of MY messages in this conversation ("Clear chat" for me).
    static func clearMyMessages(_ cid: String) async {
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
    static func setReaction(cid: String, messageId: String, emoji: String?, toAuthor: String, group: [String]? = nil) async {
        let ref = db.collection("conversations").document(cid)
            .collection("messages").document(messageId)
        let convRef = db.collection("conversations").document(cid)
        guard let emoji else {
            try? await ref.updateData(["reactions.\(uid)": FieldValue.delete()])
            // If MY reaction was the one being previewed in the chat list, retract it.
            let cs = try? await convRef.getDocument()
            if (cs?.data()?["lastReactionBy"] as? String) == uid {
                try? await convRef.updateData([
                    "lastReactionEnc": FieldValue.delete(), "lastReactionBy": FieldValue.delete(),
                    "lastReactionToAuthor": FieldValue.delete(), "lastReactionAt": FieldValue.delete(),
                ])
            }
            return
        }
        // Group reactions are sealed for ALL members (so everyone sees the emoji); 1:1 to the other.
        var members = group
        if members == nil, !cid.contains("_") {
            let snap = try? await db.collection("conversations").document(cid).getDocument()
            members = snap?.data()?["users"] as? [String]
        }
        let enc: String?
        if let members { enc = try? await Crypto.shared.encryptForGroup(emoji, members: members) }
        else { enc = try? await Crypto.shared.encryptForConversation(cid, emoji) }
        // Dotted field update — only touches my own key, so concurrent reactions never clobber.
        if let enc {
            try? await ref.updateData(["reactions.\(uid)": enc])
            // Surface it in the chat list ("Reacted 🙏") — a separate best-effort write, so the
            // reaction itself still lands even if this one is rejected. Deliberately does NOT
            // bump updatedAt: a reaction shouldn't reorder chats or re-arm unread; the list
            // preview just changes in place while the reaction is the newest event.
            try? await convRef.updateData([
                "lastReactionEnc": enc, "lastReactionBy": uid,
                "lastReactionToAuthor": toAuthor,
                "lastReactionAt": FieldValue.serverTimestamp(),
            ])
        }
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
    static func recordCall(cid: String, callId: String, callerUid: String, outcome: String, video: Bool, durationSec: Int) async {
        let convRef = db.collection("conversations").document(cid)
        let msgRef = convRef.collection("messages").document("call_\(callId)")
        var fields: [String: Any] = [
            "type": "call",
            "authorId": callerUid,             // deterministic: the caller, not whoever wrote last
            "callerUid": callerUid,            // viewer compares to itself for direction
            "callOutcome": outcome,            // answered | missed | declined
            "callVideo": video,                // placed as a video call (log/preview label)
            "text": "",
            "createdAt": FieldValue.serverTimestamp(),
        ]
        if uid == callerUid { fields["callDuration"] = durationSec }
        try? await msgRef.setData(fields, merge: true)
        // "declined" is its own outcome now, so it must not fall through to the plain "Call" label.
        let marker: String = {
            if outcome == "declined" { return video ? "📹 Declined video call" : "📞 Declined call" }
            if outcome == "missed"   { return video ? "📹 Missed video call"   : "📞 Missed call" }
            return video ? "📹 Video call" : "📞 Call"
        }()
        try? await convRef.setData([
            "lastMessage": marker,
            // Clear lastSender (audit): it kept naming whoever sent the previous real message, so if
            // that was me the chat row drew MY delivery ticks beside "Missed call" — a call record
            // is not my message and has no sent/read state. Empty suppresses them via lastIsMine.
            "lastSender": "",
            "updatedAt": FieldValue.serverTimestamp(),
        ], merge: true)
        // Keep the Calls tab (list + missed badge) live — the history repo has no listener.
        await CallsRepository.shared.load(force: true)
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

            // TOMBSTONE, not a hole. The document survives carrying `deleted`, with every content
            // field stripped, so both sides see that something was here and was removed instead of a
            // message silently vanishing and leaving the other person wondering what they missed.
            // This is what the reference app and the reference app both do.
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
                              "forwarded"] {
                        strip[k] = FieldValue.delete()
                    }
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
            if !markedDeleted { try await ref.delete() }
            // Best-effort, AFTER the doc is gone: a failure here must never turn a successful delete
            // into a reported failure, and an already-missing object is not an error worth surfacing.
            for u in blobs {
                try? await Storage.storage().reference(forURL: u).delete()
            }
            // Clean up what a bare doc delete leaves behind (audit):
            // • a PIN pointing at it — pinnedMessageIds is shared state and nothing else ever
            //   removes the id, so both people kept a dead "Tap to view" pin forever;
            // • the conversation SUMMARY, if this was the newest message — the deleted text (and a
            //   photo's thumbnail) stayed readable in BOTH chat lists indefinitely, which is exactly
            //   what "delete for everyone" promises it won't.
            await removePinnedMessage(cid, messageId)
            await clearSummaryIfNewest(cid: cid, deletedId: messageId)
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

    /// After the newest message is deleted, re-point the conversation summary at whatever is now
    /// newest (or clear it when nothing is left). Best-effort: a failure here never fails the delete.
    private static func clearSummaryIfNewest(cid: String, deletedId: String) async {
        let convRef = db.collection("conversations").document(cid)
        let newest = try? await convRef.collection("messages")
            .order(by: "createdAt", descending: true).limit(to: 1).getDocuments()
        guard let doc = newest?.documents.first else {
            // Nothing left at all.
            try? await convRef.updateData([
                "lastMessage": "", "lastSender": "",
                "lastImageUrl": FieldValue.delete(), "lastImageEnc": FieldValue.delete(),
            ])
            return
        }
        let d = doc.data()
        // The tombstone is still the newest message now that deleting keeps the document, and its
        // text is empty, which would leave the chat list showing a blank line. A plaintext marker
        // instead, the same way "GIF" and "📷 Photo" already ride this field un-encrypted.
        let deletedNewest = d["deleted"] as? Bool == true
        var update: [String: Any] = [
            "lastMessage": deletedNewest ? "This message was deleted" : (d["text"] as? String ?? ""),
            "lastSender": d["authorId"] as? String ?? "",
        ]
        // Carry the new newest message's thumbnail, or drop the stale one.
        if let u = d["imageUrl"] as? String, let e = d["enc"] as? [String: Any],
           (d["viewOnce"] as? Bool) != true {
            update["lastImageUrl"] = u; update["lastImageEnc"] = e
        } else {
            update["lastImageUrl"] = FieldValue.delete()
            update["lastImageEnc"] = FieldValue.delete()
        }
        try? await convRef.updateData(update)
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
                    try? await Storage.storage().reference(forURL: s).delete()
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

    /// Edit a text message in place: re-encrypt the new text and flag it edited.
    /// Server still never sees plaintext (same E2EE path as sendText).
    static func editMessage(cid: String, messageId: String, newText: String, group: [String]? = nil) async throws {
        let t = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        var members = group
        if members == nil, !cid.contains("_") {
            let snap = try? await db.collection("conversations").document(cid).getDocument()
            members = snap?.data()?["users"] as? [String]
        }
        // Re-seal for the group (author = me, since only the author may edit) or the 1:1 pair.
        let cipher = members != nil
            ? try await Crypto.shared.encryptForGroup(t, members: members!)
            : try await Crypto.shared.encryptForConversation(cid, t)
        let convRef = db.collection("conversations").document(cid)
        try await convRef.collection("messages").document(messageId)
            .updateData(["text": cipher, "edited": true])
        // If this WAS the newest message, the chat list still shows the pre-edit text on both
        // phones until something else arrives (audit) — re-point the summary at the new wording.
        let newest = try? await convRef.collection("messages")
            .order(by: "createdAt", descending: true).limit(to: 1).getDocuments()
        if newest?.documents.first?.documentID == messageId {
            try? await convRef.updateData(["lastMessage": cipher])
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
        try? await db.collection("conversations").document(cid)
            .updateData(["unreadCount.\(uid)": 0])
    }

    /// Manually flag a chat as unread — shows a plain DOT until reopened, never a number.
    ///
    /// It used to write `1`, and a `1` is a count: the chat list drew "1 unread message" for a
    /// conversation you had just read to the end. Marking something unread is a reminder to yourself,
    /// not a claim that somebody sent you something.
    ///
    /// MINUS ONE IS THE FLAG, rather than a new field, and deliberately: `conversations` is field-
    /// whitelisted in the rules, so a new key would need a rules deploy to be writable at all, and
    /// this needs none. Everything that reads a count already treats "how many" as `max(0, …)` (see
    /// `Conversation.unread`), so the number this shows is zero and the dot comes from the sign.
    static func markUnread(_ cid: String) async {
        if OfficialChannel.isOfficial(cid) { OfficialChannelStore.shared.markUnread(); return }
        try? await db.collection("conversations").document(cid)
            .updateData(["unreadCount.\(uid)": -1])
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

    // Throttled read receipts (a debounced receipt sender): the per-received-message call in an
    // open chat was one Firestore write PER message — a 20-message burst = 20 billed writes. This fires
    // immediately when idle, then suppresses further writes for 2s and sends ONE trailing write if more
    // messages arrived during the window (read state is monotonic, so the newest write covers them all).
    private static var readCooldownUntil: [String: Date] = [:]
    private static var readTrailing: Set<String> = []
    @MainActor
    static func markReadThrottled(_ cid: String) {
        let now = Date()
        if let until = readCooldownUntil[cid], until > now {
            readTrailing.insert(cid)
            return
        }
        readCooldownUntil[cid] = now.addingTimeInterval(2)
        Task { await markRead(cid) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.05) {
            if readTrailing.remove(cid) != nil { markReadThrottled(cid) }
        }
    }

    // MARK: - Voice-note played receipts

    /// Tell the sender their voice note was actually heard. WhatsApp turns the mic icon blue for this,
    /// and it was the one voice signal we sent nothing for.
    ///
    /// ⚠️ GATED ON `readReceipts`, WHICH IS DELIBERATELY *UNLIKE* WHATSAPP. Theirs fires even with read
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
    static func setPinned(_ cid: String, _ value: Bool) async {
        if OfficialChannel.isOfficial(cid) { OfficialChannelStore.shared.setPinned(value); return }
        try? await db.collection("conversations").document(cid)
            .setData(["pinnedBy": [uid: value]], merge: true)
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
        try? await db.collection("conversations").document(cid)
            .setData(["pinnedMessageIds": FieldValue.arrayRemove([messageId])], merge: true)
    }

    static func setArchived(_ cid: String, _ value: Bool) async {
        if OfficialChannel.isOfficial(cid) { OfficialChannelStore.shared.setArchived(value); return }
        try? await db.collection("conversations").document(cid)
            .setData(["archivedBy": [uid: value]], merge: true)
    }

    static func setMuted(_ cid: String, _ value: Bool) async {
        if OfficialChannel.isOfficial(cid) { OfficialChannelStore.shared.setMuted(value); return }
        let until: Double = value ? 9_999_999_999_999 : 0
        try? await db.collection("conversations").document(cid)
            .setData(["mutedBy": [uid: until]], merge: true)
    }

    /// Mute until a specific epoch-ms time (0 = unmute, far-future = always).
    static func setMute(_ cid: String, until: Double) async {
        if OfficialChannel.isOfficial(cid) {
            // The official channel's mute is a plain on/off. A timed mute would expire and start
            // making noise on its own, which is the opposite of the promise the welcome message makes.
            OfficialChannelStore.shared.setMuted(until > Date().timeIntervalSince1970 * 1000)
            return
        }
        try? await db.collection("conversations").document(cid)
            .setData(["mutedBy": [uid: until]], merge: true)
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
    static func setDisappear(_ cid: String, seconds: Int) async {
        let ref = db.collection("conversations").document(cid)
        let current = ((try? await ref.getDocument())?.data()?["disappearSeconds"] as? NSNumber)?.intValue ?? 0
        guard current != seconds else { return }   // no change → no write, no duplicate notice
        try? await ref.setData(["disappearSeconds": seconds], merge: true)
        let name = await MainActor.run { ProfileStore.shared.me?.name ?? "Someone" }
        let text = seconds > 0
            ? "\(name) turned on disappearing messages (\(disappearLabel(seconds)))"
            : "\(name) turned off disappearing messages"
        try? await writeSystemMessage(cid: cid, text: text)
    }

    static func setBlocked(_ cid: String, _ value: Bool) async {
        var data: [String: Any] = ["blockedBy": [uid: value]]
        let now = Date().timeIntervalSince1970 * 1000
        // Stamp block start / unblock time so the blocker hides exactly the messages
        // that arrived DURING the block — and keeps hiding them after unblock
        // (never delivered, as standard messengers do). Older history stays visible.
        if value { data["blockedAt"] = [uid: now] } else { data["blockClearedAt"] = [uid: now] }
        try? await db.collection("conversations").document(cid).setData(data, merge: true)
        // REVOKE MY ACTIVE STORIES FROM THEM (audit). The audience is frozen into recipientUids at
        // post time and nothing ever rewrote it, so blocking someone only affected FUTURE stories:
        // for up to 24h they kept the ring, kept watching, and kept landing in my Seen-by. Blocking
        // is the strongest "stop seeing me" action there is, so it has to reach back.
        if value {
            let other = cid.split(separator: "_").map(String.init).first { $0 != uid } ?? ""
            if !other.isEmpty { await StoriesRepository.shared.revokeAudience(for: other) }
        }
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
        try? await db.collection("reports").addDocument(data: data)
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
    /// must already know the whole name; there is no way to ask what names exist. That is WhatsApp's
    /// model, in their words: "strangers must type your exact, full username."
    ///
    /// Two reads instead of one query, and the second one is a plain document fetch the app makes
    /// everywhere else, so it is cached like any other profile.
    static func findByHandle(_ handle: String) async -> UserProfile? {
        var h = handle.trimmingCharacters(in: .whitespaces).lowercased()
        if h.hasPrefix("@") { h.removeFirst() }   // users type "@ayaan"
        guard !h.isEmpty else { return nil }
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
            guard u.id != uid else { return nil }   // never "find" yourself
            return ProfileStore.indexed(u)          // warms photo / call-privacy / verification
        } catch {
            print("findByHandle failed:", error)
            return nil
        }
    }

    /// ⚠️ NO PREFIX SEARCH. THIS IS DELIBERATE AND IT MUST NOT BE PUT BACK.
    ///
    /// This used to take two letters and return twenty accounts ordered by username. That is a public
    /// directory: type `ab`, get twenty people, walk the alphabet, and you have everybody. It is the
    /// exact thing WhatsApp describes when they say spammers cannot "search random words or scrape a
    /// public directory to find you" — and we had it switched on.
    ///
    /// It is now an exact lookup that returns at most one person, so the search screen still works
    /// for somebody who was given a full username. Kept as a list-returning function rather than
    /// deleted so its callers do not change shape, and so this comment sits where anybody restoring
    /// "search suggestions" will read it first. Restoring the prefix query also means restoring
    /// `list` permission on every profile; the two are the same decision.
    static func searchUsers(prefix: String) async -> [UserProfile] {
        guard let one = await findByHandle(prefix) else { return [] }
        return [one]
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
