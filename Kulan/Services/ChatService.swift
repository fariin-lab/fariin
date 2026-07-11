import Foundation
import UIKit
import FirebaseAuth
import FirebaseFirestore
import FirebaseStorage

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

        try await db.collection("conversations").document(cid).setData([
            "users": [uid, other.id],
            "names": [uid: me?.name ?? "Me", other.id: other.name.isEmpty ? other.handle : other.name],
            "photos": photos,
            "unreadCount": [uid: 0, other.id: 0],
            "typing": [uid: false, other.id: false],
            "updatedAt": FieldValue.serverTimestamp(),
        ], merge: true)
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
    /// messages until they open Kulan) so the UI can warn the adder honestly.
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
        var addedNames: [String] = []
        var keyless: [String] = []
        for u in newOnes {
            if let p = await ProfileStore.shared.fetch(u) {
                let nm = p.name.isEmpty ? p.handle : p.name
                update["names.\(u)"] = nm
                addedNames.append(nm)
                if let ph = p.photoUrl, !ph.isEmpty { update["photos.\(u)"] = ph }
                if (p.publicKeyB64 ?? "").isEmpty { keyless.append(nm) }   // hasn't opened Kulan
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
            "updatedAt": FieldValue.serverTimestamp(),
        ])
        try await writeSystemMessage(cid: cid, text: "\(myName()) made \(name) an admin")
    }

    /// Demote an admin back to a regular member (admin) + system message.
    static func demoteGroupAdmin(cid: String, uid demoted: String, name: String) async throws {
        let convRef = db.collection("conversations").document(cid)
        try await convRef.updateData([
            "admins": FieldValue.arrayRemove([demoted]),
            "updatedAt": FieldValue.serverTimestamp(),
        ])
        try await writeSystemMessage(cid: cid, text: "\(myName()) removed \(name) as admin")
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
    static func sendText(cid: String, text: String, replyTo: ReplyRef? = nil, clientId: String? = nil, group: [String]? = nil, mentions: [String] = []) async throws {
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
            try await sendGroupText(cid: cid, members: members, text: t, replyTo: replyTo, clientId: clientId, mentions: mentions)
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

        // Ensure the conversation exists BEFORE the message. The rules require
        // convData().users to authorize a message create; on a brand-new chat the
        // create otherwise loses the race and is rolled back server-side (message
        // "sends" locally then silently vanishes). Awaiting this first send keeps
        // the writes ordered so the conv is committed before the message.
        try await convRef.setData([
            "users": [uid, other],
            "updatedAt": FieldValue.serverTimestamp(),
        ], merge: true)

        let msgRef = convRef.collection("messages").document()
        let batch = db.batch()
        var msg: [String: Any] = [
            "text": cipher,
            "authorId": uid,
            "createdAt": FieldValue.serverTimestamp(),
        ]
        if let clientId { msg["clientId"] = clientId }   // lets the client reconcile its optimistic copy
        if let replyEnc { msg["replyTo"] = replyEnc }
        if !mentions.isEmpty { msg["mentions"] = mentions }
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
                                      replyTo: ReplyRef?, clientId: String?, mentions: [String] = []) async throws {
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
        ]
        if let clientId { msg["clientId"] = clientId }
        if let replyEnc { msg["replyTo"] = replyEnc }
        if !mentions.isEmpty { msg["mentions"] = mentions }
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
    static func downscaledJPEG(_ data: Data, maxDimension: CGFloat = 1600, quality: CGFloat = 0.72) -> Data {
        guard let img = UIImage(data: data) else { return data }
        let longEdge = max(img.size.width, img.size.height)
        let scale = min(1, maxDimension / longEdge)
        if scale >= 1 { return img.jpegData(compressionQuality: quality) ?? data }
        let newSize = CGSize(width: img.size.width * scale, height: img.size.height * scale)
        let resized = UIGraphicsImageRenderer(size: newSize).image { _ in
            img.draw(in: CGRect(origin: .zero, size: newSize))
        }
        return resized.jpegData(compressionQuality: quality) ?? data
    }

    static func sendImage(cid: String, data rawData: Data, clientId: String? = nil, group: [String]? = nil, viewOnce: Bool = false, caption: String = "") async throws {
        let data = downscaledJPEG(rawData)
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
        let ref = Storage.storage().reference().child("chat/\(cid)/\(msgRef.documentID).enc")
        let sm = StorageMetadata(); sm.contentType = "application/octet-stream"
        _ = try await ref.putDataAsync(cipher, metadata: sm)
        let url = try await ref.downloadURL().absoluteString
        // Seed the cache with the plaintext image under its URL so when the optimistic bubble
        // reconciles to the server message, SecureImageView renders instantly (no shimmer / re-download).
        if let ui = UIImage(data: rawData) { DiskImageCache.shared.store(ui, for: url) }

        // Caption travels INSIDE the image message (Signal: the caption is the message body) — sealed
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

        let batch = db.batch()
        var imgMsg: [String: Any] = [
            "type": "image", "imageUrl": url, "enc": meta.asDict, "text": captionCipher,
            "authorId": uid, "createdAt": FieldValue.serverTimestamp(),
        ]
        if let clientId { imgMsg["clientId"] = clientId }   // reconcile the optimistic bubble
        if viewOnce { imgMsg["viewOnce"] = true }           // Signal-style view-once photo
        if let ui = UIImage(data: data) {                   // natural aspect ratio
            imgMsg["width"] = Double(ui.size.width); imgMsg["height"] = Double(ui.size.height)
            // BlurHash (Signal): a ~28-char sketch of the photo, sealed like the caption, so the
            // recipient's bubble shows a real blurred preview before any bytes download.
            if !viewOnce, let hash = BlurHash.encode(ui) {
                let sealed = members != nil
                    ? (try? await Crypto.shared.encryptForGroup(hash, members: members!))
                    : (try? await Crypto.shared.encryptForConversation(cid, hash))
                if let sealed, !sealed.isEmpty { imgMsg["blurhash"] = sealed }
            }
        }
        batch.setData(imgMsg, forDocument: msgRef)
        var convUpdate: [String: Any] = [
            "lastMessage": "📷 Photo",
            "lastImageUrl": url,
            "lastImageEnc": meta.asDict,
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

    /// Send 2+ photos as ONE album message (grid + one caption), like Signal/Telegram. Each photo is
    /// E2EE'd + uploaded separately; a single message doc carries the array of {imageUrl, enc, w, h}.
    static func sendAlbum(cid: String, images: [Data], caption: String, clientId: String? = nil, group: [String]? = nil) async throws {
        var members = group
        if members == nil, !cid.contains("_") {
            let snap = try? await db.collection("conversations").document(cid).getDocument()
            members = snap?.data()?["users"] as? [String]
        }
        let convRef = db.collection("conversations").document(cid)
        let msgRef = convRef.collection("messages").document()

        // Upload + seal every photo (natural aspect kept for the grid).
        var items: [[String: Any]] = []
        for (i, raw) in images.enumerated() {
            let data = downscaledJPEG(raw)
            let cipher: Data, meta: EncMeta
            if let members { (cipher, meta) = try await Crypto.shared.encryptBytesForGroup(data, members: members) }
            else {
                (cipher, meta) = try await Crypto.shared.encryptBytes(cid, data)
                let other = cid.split(separator: "_").map(String.init).first { $0 != uid } ?? ""
                try await convRef.setData(["users": [uid, other], "updatedAt": FieldValue.serverTimestamp()], merge: true)
            }
            let ref = Storage.storage().reference().child("chat/\(cid)/\(msgRef.documentID)-\(i).enc")
            let sm = StorageMetadata(); sm.contentType = "application/octet-stream"
            _ = try await ref.putDataAsync(cipher, metadata: sm)
            let url = try await ref.downloadURL().absoluteString
            if let ui = UIImage(data: raw) { DiskImageCache.shared.store(ui, for: url) }   // instant reconcile
            let sz = UIImage(data: data)?.size ?? CGSize(width: 1, height: 1)
            items.append(["imageUrl": url, "enc": meta.asDict, "width": Double(sz.width), "height": Double(sz.height)])
        }

        // Caption sealed like a text body (Signal: one body for the album).
        var captionCipher = ""
        let trimmed = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            if let members { captionCipher = (try? await Crypto.shared.encryptForGroup(trimmed, members: members)) ?? "" }
            else { captionCipher = (try? await Crypto.shared.encryptForConversation(cid, trimmed)) ?? "" }
        }

        let batch = db.batch()
        var msg: [String: Any] = [
            "type": "album", "album": items, "text": captionCipher,
            "authorId": uid, "createdAt": FieldValue.serverTimestamp(),
        ]
        if let clientId { msg["clientId"] = clientId }
        batch.setData(msg, forDocument: msgRef)
        var convUpdate: [String: Any] = [
            "lastMessage": "📷 \(images.count) Photos", "lastSender": uid,
            "updatedAt": FieldValue.serverTimestamp(),
        ]
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
    static func sendAudio(cid: String, data: Data, duration: Double, waveform: [Int] = [], replyTo: ReplyRef? = nil, clientId: String? = nil, group: [String]? = nil) async throws {
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
        let ref = Storage.storage().reference().child("chat/\(cid)/\(msgRef.documentID).m4a.enc")
        let sm = StorageMetadata(); sm.contentType = "application/octet-stream"
        _ = try await ref.putDataAsync(cipher, metadata: sm)
        let url = try await ref.downloadURL().absoluteString

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
            "type": "audio", "audioUrl": url, "duration": duration, "waveform": waveform,
            "enc": meta.asDict, "text": "", "authorId": uid, "createdAt": FieldValue.serverTimestamp(),
        ]
        if let clientId { msg["clientId"] = clientId }   // reconcile the optimistic bubble in place
        if let replyEnc { msg["replyTo"] = replyEnc }    // voice notes can be replies too (Bug 1)
        batch.setData(msg, forDocument: msgRef)
        var convUpdate: [String: Any] = [
            // Length rides inside the marker ("🎤 Voice message · 0:53") so the chat list
            // can show it without a schema change; old plain markers still parse (prefix match).
            "lastMessage": "🎤 Voice message · " + voiceDurationLabel(duration),
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
                          width: Double, height: Double, caption: String = "", clientId: String? = nil, group: [String]? = nil) async throws {
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
        if let members {
            (vidCipher, vidMeta) = try await Crypto.shared.encryptBytesForGroup(video, members: members)
            (thCipher, thMeta) = try await Crypto.shared.encryptBytesForGroup(thumbnail, members: members)
        } else {
            (vidCipher, vidMeta) = try await Crypto.shared.encryptBytes(cid, video)
            (thCipher, thMeta) = try await Crypto.shared.encryptBytes(cid, thumbnail)
            let other = cid.split(separator: "_").map(String.init).first { $0 != uid } ?? ""
            try await convRef.setData(["users": [uid, other], "updatedAt": FieldValue.serverTimestamp()], merge: true)
        }
        let msgRef = convRef.collection("messages").document()
        let vRef = Storage.storage().reference().child("chat/\(cid)/\(msgRef.documentID).mp4.enc")
        let tRef = Storage.storage().reference().child("chat/\(cid)/\(msgRef.documentID).thumb.enc")
        let sm = StorageMetadata(); sm.contentType = "application/octet-stream"
        _ = try await vRef.putDataAsync(vidCipher, metadata: sm)
        _ = try await tRef.putDataAsync(thCipher, metadata: sm)
        let videoUrl = try await vRef.downloadURL().absoluteString
        let thumbUrl = try await tRef.downloadURL().absoluteString
        // Seed the cache so the optimistic bubble reconciles with no shimmer (photo parity).
        if let ui = UIImage(data: thumbnail) { DiskImageCache.shared.store(ui, for: thumbUrl) }

        let batch = db.batch()
        var msg: [String: Any] = [
            "type": "video", "videoUrl": videoUrl, "enc": vidMeta.asDict,
            "thumbUrl": thumbUrl, "thumbEnc": thMeta.asDict,
            "duration": duration, "width": width, "height": height,
            "text": captionCipher, "authorId": uid, "createdAt": FieldValue.serverTimestamp(),
        ]
        if let clientId { msg["clientId"] = clientId }
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
    static func sendFile(cid: String, data rawData: Data, fileName: String, clientId: String? = nil, group: [String]? = nil) async throws {
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
        let ref = Storage.storage().reference().child("chat/\(cid)/\(msgRef.documentID).file.enc")
        let sm = StorageMetadata(); sm.contentType = "application/octet-stream"
        _ = try await ref.putDataAsync(cipher, metadata: sm)
        let url = try await ref.downloadURL().absoluteString
        let batch = db.batch()
        var msg: [String: Any] = [
            "type": "file", "fileUrl": url, "fileName": fileName, "fileSize": rawData.count,
            "enc": meta.asDict, "text": "", "authorId": uid, "createdAt": FieldValue.serverTimestamp(),
        ]
        if let clientId { msg["clientId"] = clientId }
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

    /// Send a GIF (a public Giphy URL — public content, so NOT E2EE; we store the url directly).
    static func sendGif(cid: String, url: String, width: Double, height: Double, group: [String]? = nil) async throws {
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
        batch.setData([
            "type": "gif", "imageUrl": url, "width": width, "height": height,
            "text": "", "authorId": uid, "createdAt": FieldValue.serverTimestamp(),
        ], forDocument: msgRef)
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

    static func forwardMessage(_ m: Message, from sourceCid: String, to targetCid: String) async throws {
        if m.isImage {
            let bytes: Data
            if let local = m.localImageData {
                bytes = local
            } else if let s = m.imageUrl, let url = URL(string: s), let meta = m.enc,
                      let (cipher, _) = try? await URLSession.shared.data(from: url),
                      let dec = await Crypto.shared.decryptBytes(sourceCid, cipher: cipher, meta: meta) {
                bytes = dec
            } else { throw ForwardError.sourceUnavailable }
            try await sendImage(cid: targetCid, data: bytes)
        } else if m.isAudio {
            guard let s = m.audioUrl, let url = URL(string: s), let meta = m.enc,
                  let (cipher, _) = try? await URLSession.shared.data(from: url),
                  let dec = await Crypto.shared.decryptBytes(sourceCid, cipher: cipher, meta: meta)
            else { throw ForwardError.sourceUnavailable }
            try await sendAudio(cid: targetCid, data: dec, duration: m.duration ?? 0, waveform: m.waveform)
        } else if m.isVideo {
            // Prefer this device's copy (the server object may already be delivered+deleted).
            var bytes = VideoCache.data(for: m.id)
            if bytes == nil, let s = m.videoUrl, let url = URL(string: s), let meta = m.enc,
               let (cipher, _) = try? await URLSession.shared.data(from: url),
               let dec = await Crypto.shared.decryptBytes(sourceCid, cipher: cipher, meta: meta) {
                bytes = dec
            }
            guard let bytes else { throw ForwardError.sourceUnavailable }
            var thumb: Data? = nil
            if let s = m.thumbUrl, let url = URL(string: s), let meta = m.thumbEnc,
               let (cipher, _) = try? await URLSession.shared.data(from: url) {
                thumb = await Crypto.shared.decryptBytes(sourceCid, cipher: cipher, meta: meta)
            }
            guard let thumb else { throw ForwardError.sourceUnavailable }
            try await sendVideo(cid: targetCid, video: bytes, thumbnail: thumb, duration: m.duration ?? 0,
                                width: m.width ?? 720, height: m.height ?? 720)
        } else if m.isGif {
            guard let gifUrl = m.imageUrl, !gifUrl.isEmpty else { throw ForwardError.sourceUnavailable }
            try await sendGif(cid: targetCid, url: gifUrl, width: m.width ?? 200, height: m.height ?? 200)
        } else if m.isFile {
            guard let s = m.fileUrl, let url = URL(string: s), let meta = m.enc,
                  let (cipher, _) = try? await URLSession.shared.data(from: url),
                  let dec = await Crypto.shared.decryptBytes(sourceCid, cipher: cipher, meta: meta)
            else { throw ForwardError.sourceUnavailable }
            try await sendFile(cid: targetCid, data: dec, fileName: m.fileName ?? "File")
        } else {
            try await sendText(cid: targetCid, text: m.text)
        }
    }

    /// Recent image messages in a conversation (for the Shared Media section).
    /// Filters client-side to avoid needing a composite index.
    static func sharedMedia(_ cid: String) async -> [Message] {
        do {
            let snap = try await db.collection("conversations").document(cid).collection("messages")
                .order(by: "createdAt", descending: true)
                .limit(to: 60).getDocuments()
            return snap.documents
                .map { Message(id: $0.documentID, data: $0.data(), cid: cid, crypto: Crypto.shared) }
                .filter { $0.isImage }
        } catch {
            return []
        }
    }

    /// A larger recent window of decrypted messages for the Media Gallery to categorize into
    /// media / audio / links tabs (newest first). Client-side filtering avoids a composite index.
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

    /// Write ONE call record into the shared chat, keyed by callId so both ends can't
    /// create duplicates (whoever writes first wins; the other's create is a no-op).
    /// Stores who the caller was, so each client renders outgoing/incoming for itself.
    static func recordCall(cid: String, callId: String, callerUid: String, outcome: String, video: Bool, durationSec: Int) async {
        let convRef = db.collection("conversations").document(cid)
        let msgRef = convRef.collection("messages").document("call_\(callId)")
        try? await msgRef.setData([
            "type": "call",
            "authorId": uid,
            "callerUid": callerUid,            // viewer compares to itself for direction
            "callOutcome": outcome,            // answered | missed
            "callVideo": video,                // placed as a video call (log/preview label)
            "callDuration": durationSec,
            "text": "",
            "createdAt": FieldValue.serverTimestamp(),
        ])
        let marker = video
            ? (outcome == "missed" ? "📹 Missed video call" : "📹 Video call")
            : (outcome == "missed" ? "📞 Missed call" : "📞 Call")
        try? await convRef.setData([
            "lastMessage": marker,
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

    static func deleteMessage(cid: String, messageId: String) async {
        try? await db.collection("conversations").document(cid)
            .collection("messages").document(messageId).delete()
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
        try await db.collection("conversations").document(cid)
            .collection("messages").document(messageId)
            .updateData(["text": cipher, "edited": true])
    }

    /// A privacy pref (defaults ON when never set).
    static func pref(_ key: String) -> Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }

    static func setTyping(_ cid: String, _ typing: Bool) async {
        guard pref("typingIndicators") else { return }   // privacy: don't broadcast typing
        try? await db.collection("conversations").document(cid)
            .setData(["typing": [uid: typing]], merge: true)
    }

    /// My unread count for this conversation — read once on open (before reset) to
    /// anchor the "Unread Messages" divider.
    static func myUnread(_ cid: String) async -> Int {
        let snap = try? await db.collection("conversations").document(cid).getDocument()
        let m = snap?.data()?["unreadCount"] as? [String: Any]
        return (m?[uid] as? NSNumber)?.intValue ?? 0
    }

    static func resetUnread(_ cid: String) async {
        try? await db.collection("conversations").document(cid)
            .updateData(["unreadCount.\(uid)": 0])
    }

    /// Manually flag a chat as unread (Telegram-style) — shows a badge until reopened.
    static func markUnread(_ cid: String) async {
        try? await db.collection("conversations").document(cid)
            .updateData(["unreadCount.\(uid)": 1])
    }

    /// Mark this conversation read up to now (drives the other person's read receipts).
    static func markRead(_ cid: String) async {
        guard pref("readReceipts") else { return }   // privacy: don't send read receipts
        try? await db.collection("conversations").document(cid)
            .setData(["lastRead": [uid: FieldValue.serverTimestamp()]], merge: true)
    }

    // Throttled read receipts (Signal's ReceiptSender debounce): the per-received-message call in an
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

    static func setPinned(_ cid: String, _ value: Bool) async {
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
        try? await db.collection("conversations").document(cid)
            .setData(["archivedBy": [uid: value]], merge: true)
    }

    static func setMuted(_ cid: String, _ value: Bool) async {
        let until: Double = value ? 9_999_999_999_999 : 0
        try? await db.collection("conversations").document(cid)
            .setData(["mutedBy": [uid: until]], merge: true)
    }

    /// Mute until a specific epoch-ms time (0 = unmute, far-future = always).
    static func setMute(_ cid: String, until: Double) async {
        try? await db.collection("conversations").document(cid)
            .setData(["mutedBy": [uid: until]], merge: true)
    }

    /// Shared mute-duration options (Signal-style). Pass nil for "Always".
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
    /// NEVER silent (WhatsApp rule): both sides get a centered system notice in the chat
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
        // (never delivered, like WhatsApp). Older history stays visible.
        if value { data["blockedAt"] = [uid: now] } else { data["blockClearedAt"] = [uid: now] }
        try? await db.collection("conversations").document(cid).setData(data, merge: true)
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
        try? await db.collection("conversations").document(cid).setData([
            "clearedAt": [uid: Date().timeIntervalSince1970 * 1000],
            "unreadCount": [uid: 0],
        ], merge: true)
    }

    // MARK: - Discovery

    static func findByHandle(_ handle: String) async -> UserProfile? {
        var h = handle.trimmingCharacters(in: .whitespaces).lowercased()
        if h.hasPrefix("@") { h.removeFirst() }   // users type "@ayaan"
        guard !h.isEmpty else { return nil }
        do {
            let snap = try await db.collection("users")
                .whereField("handleLower", isEqualTo: h)
                .limit(to: 1).getDocuments()
            guard let d = snap.documents.first else { return nil }
            let u = UserProfile(id: d.documentID, data: d.data())
            return u.id == uid ? nil : u   // never "find" yourself
        } catch {
            print("findByHandle failed:", error)
            return nil
        }
    }

    static func searchUsers(prefix: String) async -> [UserProfile] {
        var q = prefix.trimmingCharacters(in: .whitespaces).lowercased()
        if q.hasPrefix("@") { q.removeFirst() }
        guard q.count >= 2 else { return [] }   // min length: don't hammer Firestore on 1 char
        do {
            let snap = try await db.collection("users")
                .order(by: "handleLower")
                .start(at: [q]).end(at: [q + "\u{f8ff}"])
                .limit(to: 20).getDocuments()
            return snap.documents.compactMap { d -> UserProfile? in
                let u = UserProfile(id: d.documentID, data: d.data())
                return u.id == uid ? nil : u
            }
        } catch {
            print("searchUsers failed:", error)
            return []
        }
    }
}
