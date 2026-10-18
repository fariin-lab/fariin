import UIKit
import ImageIO
import FirebaseFirestore

// ⛔ SENDING A CHAT STICKER — owner 2026-10-17 ("go build"). The keyboard calls `send`; this file
// owns the message shape, the optimistic bubble, the send gates and the old-build fallback.
//
// THE MESSAGE (`type: "sticker"`):
//   • built-in: `stickerPack` + `stickerId` + `emoji` + `animated`, 512 × 512. Every phone draws its
//     own copy of the pack, so nothing is uploaded. `imageUrl` is the public copy of the same art on
//     fariin.com, read only by a phone whose pack lacks the file. Public art, so not sealed.
//   • mine: the transparent PNG, sealed and uploaded on the photo path (`uploadEncrypted`) but never
//     re-encoded to JPEG, which would drop the alpha. `imageUrl` + `enc` as a photo carries them.
//     The file is already final when it is saved (StickerCreator: 512 px max side, scale 1), so a
//     send never decodes, resizes or re-encodes it: read, seal, put.
//
// ⚠️ WHY EACH SEND OF ONE OF MINE UPLOADS AGAIN (owner 2026-10-18, speed pass). Reusing one sealed
// file for every send is what the reference app does, and the crypto would allow it (the file key
// is random and wrapped per message). Storage does not: every chat file is named after ITS message
// (`chat/{cid}/{messageId}.enc`), and delete-for-everyone, disappearing messages and the server's
// `purgeMessages` delete by that name. A second message pointing at the first one's file would go
// blank the moment the first is deleted or expires. Doing it properly needs a sticker path of its
// own in storage.rules plus a server clean-up that knows when the last message using it is gone,
// which is a deploy, so it waits for the owner. Until then: one put of a 512 px PNG.
//
// OLDER BUILDS do not know the type. They fall through to drawing `text`, so `text` carries what
// they should show: the sealed emoji for a built-in sticker (they draw it big, which is the same
// picture), and for one I made the reserved "fariin-sticker:" marker, which they turn into the
// "sent with a newer version" notice. This build drops that `text` on read (Message init).
enum StickerSend {
    /// "😂 Sticker", or "Sticker". Chat list, reply quote, forward label, push text.
    static func label(emoji: String?) -> String {
        if let e = emoji?.trimmingCharacters(in: .whitespaces), !e.isEmpty { return "\(e) Sticker" }
        return "Sticker"
    }

    /// The public copy of a built-in sticker, published with the art (owner 2026-10-17).
    static func publicURL(_ s: Sticker) -> String {
        "https://fariin.com/stickers/\(s.packId)/\(s.stickerId).webp"
    }

    /// What an older build reads instead of the sticker (see the note at the top).
    static let oldBuildMarker = "fariin-sticker:1"

    @MainActor static func send(_ sticker: Sticker, cid: String, replyTo: String?) {
        if DemoMode.isDemoConversation(cid) { return }
        let me = ChatService.uid
        guard !me.isEmpty else { return }

        // THE SAME GATES THE COMPOSER HONOURS, asked again here because the keyboard can be open
        // when a restriction lands. The rules refuse each of these anyway; this is the honest message.
        let conv = ConversationsRepository.shared.conversations.first { $0.id == cid }
        let now = Date().timeIntervalSince1970 * 1000
        if cid.contains("_") {
            let other = cid.split(separator: "_").map(String.init).first { $0 != me } ?? ""
            if BlockList.snapshot.contains(other) {
                alert("You blocked this person. Unblock them to send stickers."); return
            }
        }
        if let conv {
            if !conv.canSend(me, now: now) {
                alert("You can't send messages in this group right now."); return
            }
            if conv.isRestricted(me, .sendStickers, now: now) {
                alert("An admin has turned off stickers for you in this group."); return
            }
        }

        // A sticker I made has to be on this phone to be sent at all.
        var mineBytes: Data?
        if sticker.source == .mine {
            guard let u = StickerStore.shared.fileURL(for: sticker), let d = try? Data(contentsOf: u) else {
                alert("This sticker is no longer on this phone."); return
            }
            mineBytes = d
        }
        let png = mineBytes   // a constant: the send Task below may not capture a var
        let size = png.flatMap(pixelSize) ?? CGSize(width: 512, height: 512)
        let clientId = UUID().uuidString
        let group: [String]? = (conv?.isGroup == true) ? conv?.users : nil
        // STICKER# (owner 2026-10-18, "custom stickers take too long"): ms since the tap for each
        // step, so a slow send can be read off the phone. Sizes and times only, never content.
        let trace = Trace()
        let kind = sticker.source == .mine ? "mine" : "pack"
        DiagLog.add("STICKER# start kind=\(kind) bytes=\(png?.count ?? 0) "
                    + "px=\(Int(size.width))x\(Int(size.height)) group=\(group != nil)")

        Task { @MainActor in
            let reply = await replyRef(replyTo, cid: cid)
            var pending = Message(localSticker: sticker, png: png,
                                  width: Double(size.width), height: Double(size.height),
                                  authorId: me, clientId: clientId, sendState: .sending)
            pending.replyTo = reply
            // The open chat claims it at once (`PendingOutbox.didAdd`), which is also what glides
            // the list to the newest message, as every other send does.
            PendingOutbox.add(pending, to: cid)
            trace.mark("bubble")
            do {
                try await write(sticker, png: png, size: size, cid: cid, reply: reply,
                                clientId: clientId, group: group, trace: trace)
                StickerStore.shared.noteUsed(sticker)
                trace.mark("commit")
                DiagLog.add("STICKER# done kind=\(kind) \(trace.line) ok=1")
            } catch {
                // The red (!) on the bubble is the failure; the retry path is the resend from the keyboard.
                PendingOutbox.markFailed(clientId: clientId)
                DiagLog.add("STICKER# done kind=\(kind) \(trace.line) ok=0 err=\((error as NSError).domain)/\((error as NSError).code)")
            }
        }
    }

    /// Timestamps for the STICKER# line. Times only.
    final class Trace: @unchecked Sendable {
        private let tap = Date()
        private let lock = NSLock()
        private var marks: [String: Int] = [:]
        private var sentBytes = 0
        func mark(_ step: String) {
            let ms = Int(Date().timeIntervalSince(tap) * 1000)
            lock.lock(); marks[step] = ms; lock.unlock()
        }
        func sent(_ n: Int) { lock.lock(); sentBytes = n; lock.unlock() }
        /// -1 = the step did not happen (a pack sticker never uploads).
        var line: String {
            lock.lock(); defer { lock.unlock() }
            let order = ["bubble", "members", "sealed", "upload", "commit"]
            return order.map { "\($0)=\(marks[$0] ?? -1)" }.joined(separator: " ") + " sent=\(sentBytes)"
        }
    }

    // MARK: - The write

    private static func write(_ s: Sticker, png: Data?, size: CGSize, cid: String, reply: ReplyRef?,
                              clientId: String, group: [String]?, forwarded: Bool = false,
                              trace: Trace? = nil) async throws {
        let clientTs = Date().timeIntervalSince1970 * 1000   // the tap, before any upload
        let db = ChatService.db, uid = ChatService.uid
        var found = await ChatService.freshGroupMembers(cid, group)
        if found == nil, !cid.contains("_") {
            let snap = try? await db.collection("conversations").document(cid).getDocument()
            found = snap?.data()?["users"] as? [String]
        }
        let members = found
        trace?.mark("members")
        func seal(_ t: String) async throws -> String {
            if let members { return try await Crypto.shared.encryptForGroup(t, members: members) }
            return try await Crypto.shared.encryptForConversation(cid, t)
        }

        let convRef = db.collection("conversations").document(cid)
        let msgRef = convRef.collection("messages").document()

        // ⛔ NOTHING WAITS IN LINE BEHIND ANYTHING ELSE (owner 2026-10-18, "custom stickers take too
        // long"). The old order was: the 1:1 conversation write, a full server round trip, THEN the
        // seal, THEN the upload, THEN the two text seals, THEN the message. Now the file is sealed
        // and its upload starts first; the conversation write and the text seals run underneath
        // it, and the message waits only for the slowest of them. Same order the photo path uses
        // (ChatService `ensureConv`). A built-in sticker has no file, so nothing is uploaded at all.
        var sealedFile: (cipher: Data, meta: EncMeta)?
        if s.source == .mine {
            guard let png else { throw ChatService.ForwardError.sourceUnavailable }
            if let members { sealedFile = try await Crypto.shared.encryptBytesForGroup(png, members: members) }
            else { sealedFile = try await Crypto.shared.encryptBytes(cid, png) }
            trace?.sent(sealedFile?.cipher.count ?? 0)
        }
        trace?.mark("sealed")
        let fileCipher = sealedFile?.cipher, fileMeta = sealedFile?.meta   // constants: the child tasks below
        let filePath = "chat/\(cid)/\(msgRef.documentID).enc"
        async let uploaded = uploadIfAny(fileCipher, to: filePath, progressId: clientId)
        // The 1:1 conversation doc carries `users`, which the message write needs; the Storage put
        // does not (its rule reads the members from the 1:1 id itself).
        async let convReady: Void = ensureOneToOne(convRef, cid: cid, uid: uid, isGroup: members != nil)

        var msg: [String: Any] = [
            "type": "sticker", "stickerPack": s.packId, "stickerId": s.stickerId,
            "animated": s.animated,
            "width": Double(size.width), "height": Double(size.height),
            "authorId": uid, "createdAt": FieldValue.serverTimestamp(), "clientTs": clientTs,
            "clientId": clientId,
        ]
        if !s.emoji.isEmpty { msg["emoji"] = s.emoji }
        if forwarded { msg["forwarded"] = true }

        // The text seals, under the upload.
        switch s.source {
        case .bundled:
            msg["imageUrl"] = publicURL(s)
            msg["text"] = try await seal(s.emoji.isEmpty ? oldBuildMarker : s.emoji)
        case .mine:
            msg["text"] = try await seal(oldBuildMarker)
        }

        if let r = reply {
            let quote = try await seal(r.text)
            var e: [String: Any] = ["id": r.id, "authorId": r.authorId, "text": quote]
            if r.isStatus { e["isStatus"] = true }
            msg["replyTo"] = e
        }

        try await convReady
        if s.source == .mine {
            guard let url = try await uploaded, let fileMeta, let png else {
                throw ChatService.ForwardError.sourceUnavailable
            }
            trace?.mark("upload")
            // The plaintext PNG under its url, so the confirmed bubble draws at once, alpha intact.
            if let ui = UIImage(data: png) { DiskImageCache.shared.store(ui, data: png, for: url, owned: true) }
            msg["imageUrl"] = url
            msg["enc"] = fileMeta.asDict
        }

        try Task.checkCancellation()
        let batch = db.batch()
        batch.setData(msg, forDocument: msgRef)
        var convUpdate: [String: Any] = [
            "lastMessage": label(emoji: s.emoji), "lastSender": uid, "updatedAt": FieldValue.serverTimestamp(),
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

    /// The sealed file's upload, or nil with no network at all (a built-in sticker has no file).
    private static func uploadIfAny(_ cipher: Data?, to path: String, progressId: String) async throws -> String? {
        guard let cipher else { return nil }
        return try await ChatService.uploadEncrypted(cipher, to: path, progressId: progressId)
    }

    /// A 1:1 chat's conversation doc (`users` + `updatedAt`), which the message write needs. A group's
    /// doc exists from the moment the group is made, so there is nothing to write.
    private static func ensureOneToOne(_ convRef: DocumentReference, cid: String, uid: String,
                                       isGroup: Bool) async throws {
        guard !isGroup else { return }
        let other = cid.split(separator: "_").map(String.init).first { $0 != uid } ?? ""
        try await convRef.setData(["users": [uid, other], "updatedAt": FieldValue.serverTimestamp()], merge: true)
    }

    /// Forward (ChatService.forwardMessage). A built-in sticker is re-sent by name; one I made is
    /// decrypted from the source chat and sealed again for the target, like a forwarded photo.
    static func forward(_ m: Message, from sourceCid: String, to targetCid: String,
                        clientId: String?, forwarded: Bool) async throws {
        guard let s = m.sticker else { throw ChatService.ForwardError.sourceUnavailable }
        var png: Data?
        if s.source == .mine {
            png = await minePNG(m, cid: sourceCid)
            guard png != nil else { throw ChatService.ForwardError.sourceUnavailable }
        }
        let size = CGSize(width: m.width ?? 512, height: m.height ?? 512)
        try await write(s, png: png, size: size, cid: targetCid, reply: nil,
                        clientId: clientId ?? UUID().uuidString, group: nil, forwarded: forwarded)
    }

    /// The plaintext PNG of a sticker somebody made: the pending bytes, the row's decrypted copy in
    /// `DiskImageCache`, or (last) the sealed file fetched and opened like a photo.
    static func minePNG(_ m: Message, cid: String) async -> Data? {
        if let local = m.localImageData { return local }
        guard let u = m.imageUrl, !u.isEmpty else { return nil }
        if let cached = await DiskImageCache.shared.rawData(for: u) { return cached }
        guard let url = URL(string: u), let meta = m.enc,
              let (cipher, _) = try? await MediaSession.shared.data(from: url) else { return nil }
        return await Crypto.shared.decryptBytes(cid, cipher: cipher, meta: meta)
    }

    // MARK: - Save to Favorites (owner 2026-10-17)

    /// The menu row's title for this message, or nil when it is not a sticker that can be saved
    /// yet (one of mine still sending has no server copy to keep, but its file is already mine).
    @MainActor static func favoriteTitle(_ m: Message) -> String? {
        guard let s = m.sticker, !m.deleted else { return nil }
        return StickerStore.shared.isFavorite(s) ? "Remove from Favorites" : "Save to Favorites"
    }

    /// Saves or removes, and returns the confirmation to show. A built-in sticker is kept by name;
    /// one somebody else made is kept as its own PNG copy (`addMine`), so it lands in Favorites
    /// whatever happens to the message.
    @MainActor static func toggleFavorite(_ m: Message, cid: String) async -> String {
        guard let s = m.sticker else { return "Couldn't save this sticker" }
        let store = StickerStore.shared
        if store.isFavorite(s) {
            store.removeFavorites([s.id])
            return "Removed from Favorites"
        }
        switch s.source {
        case .bundled:
            store.addFavorite(s)
            return "Saved to Favorites"
        case .mine:
            guard let png = await minePNG(m, cid: cid), UIImage(data: png) != nil else {
                return "Couldn't save this sticker"
            }
            do {
                _ = try store.addMine(png: png, emoji: s.emoji.isEmpty ? "🙂" : s.emoji)
                return "Saved to Favorites"
            } catch {
                return "Couldn't save this sticker"
            }
        }
    }

    // MARK: - Helpers

    /// The quote for a reply, read from the message itself (the local cache first, so it costs no
    /// round trip in the usual case). Nil when it cannot be read: the sticker then goes without it.
    @MainActor private static func replyRef(_ id: String?, cid: String) async -> ReplyRef? {
        guard let id, !id.isEmpty else { return nil }
        let ref = ChatService.db.collection("conversations").document(cid).collection("messages").document(id)
        var snap = try? await ref.getDocument(source: .cache)
        if snap?.exists != true { snap = try? await ref.getDocument() }
        guard let snap, snap.exists, let data = snap.data() else { return nil }
        let m = Message(id: snap.documentID, data: data, cid: cid, crypto: Crypto.shared)
        return ReplyRef(id: m.id, authorId: m.authorId, text: replyQuoteText(m))
    }

    /// Pixel size from the header only, no decode.
    private static func pixelSize(_ data: Data) -> CGSize? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = (p[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let h = (p[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue, w > 0, h > 0
        else { return nil }
        return CGSize(width: w, height: h)
    }

    @MainActor private static func alert(_ text: String) {
        guard let top = WebLink.topViewController() else { return }
        let a = UIAlertController(title: nil, message: text, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "OK", style: .default))
        top.present(a, animated: true)
    }
}
