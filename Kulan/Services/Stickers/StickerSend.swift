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

        Task { @MainActor in
            let reply = await replyRef(replyTo, cid: cid)
            var pending = Message(localSticker: sticker, png: png,
                                  width: Double(size.width), height: Double(size.height),
                                  authorId: me, clientId: clientId, sendState: .sending)
            pending.replyTo = reply
            // The open chat claims it at once (`PendingOutbox.didAdd`), which is also what glides
            // the list to the newest message, as every other send does.
            PendingOutbox.add(pending, to: cid)
            do {
                try await write(sticker, png: png, size: size, cid: cid, reply: reply,
                                clientId: clientId, group: group)
                StickerStore.shared.noteUsed(sticker)
            } catch {
                // The red (!) on the bubble is the failure; the retry path is the resend from the keyboard.
                PendingOutbox.markFailed(clientId: clientId)
            }
        }
    }

    // MARK: - The write

    private static func write(_ s: Sticker, png: Data?, size: CGSize, cid: String, reply: ReplyRef?,
                              clientId: String, group: [String]?, forwarded: Bool = false) async throws {
        let clientTs = Date().timeIntervalSince1970 * 1000   // the tap, before any upload
        let db = ChatService.db, uid = ChatService.uid
        var found = await ChatService.freshGroupMembers(cid, group)
        if found == nil, !cid.contains("_") {
            let snap = try? await db.collection("conversations").document(cid).getDocument()
            found = snap?.data()?["users"] as? [String]
        }
        let members = found
        func seal(_ t: String) async throws -> String {
            if let members { return try await Crypto.shared.encryptForGroup(t, members: members) }
            return try await Crypto.shared.encryptForConversation(cid, t)
        }

        let convRef = db.collection("conversations").document(cid)
        if members == nil {
            let other = cid.split(separator: "_").map(String.init).first { $0 != uid } ?? ""
            try await convRef.setData(["users": [uid, other], "updatedAt": FieldValue.serverTimestamp()], merge: true)
        }
        let msgRef = convRef.collection("messages").document()

        var msg: [String: Any] = [
            "type": "sticker", "stickerPack": s.packId, "stickerId": s.stickerId,
            "animated": s.animated,
            "width": Double(size.width), "height": Double(size.height),
            "authorId": uid, "createdAt": FieldValue.serverTimestamp(), "clientTs": clientTs,
            "clientId": clientId,
        ]
        if !s.emoji.isEmpty { msg["emoji"] = s.emoji }
        if forwarded { msg["forwarded"] = true }

        switch s.source {
        case .bundled:
            msg["imageUrl"] = publicURL(s)
            msg["text"] = try await seal(s.emoji.isEmpty ? oldBuildMarker : s.emoji)
        case .mine:
            guard let png else { throw ChatService.ForwardError.sourceUnavailable }
            let cipher: Data, meta: EncMeta
            if let members { (cipher, meta) = try await Crypto.shared.encryptBytesForGroup(png, members: members) }
            else { (cipher, meta) = try await Crypto.shared.encryptBytes(cid, png) }
            let url = try await ChatService.uploadEncrypted(cipher, to: "chat/\(cid)/\(msgRef.documentID).enc",
                                                            progressId: clientId)
            // The plaintext PNG under its url, so the confirmed bubble draws at once, alpha intact.
            if let ui = UIImage(data: png) { DiskImageCache.shared.store(ui, data: png, for: url, owned: true) }
            msg["imageUrl"] = url
            msg["enc"] = meta.asDict
            msg["text"] = try await seal(oldBuildMarker)
        }

        if let r = reply {
            let quote = try await seal(r.text)
            var e: [String: Any] = ["id": r.id, "authorId": r.authorId, "text": quote]
            if r.isStatus { e["isStatus"] = true }
            msg["replyTo"] = e
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
