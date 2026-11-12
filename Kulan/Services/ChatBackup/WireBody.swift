import Foundation

/// THE SHARED "WIRE" MESSAGE BODY (agreed with Android 2026-11-12, device-storage plan, section
/// 'Shared "wire" message body'). The local database keeps this app's own `Message` JSON; a chat
/// backup carries this body instead, so a backup made on one phone opens on the other.
///
/// Wire = the Firestore message document's keys as they are stored today, plus `id` and `cid`, with:
/// - `createdAt`, `expiresAt`, `clientTs` as whole milliseconds since 1970;
/// - every sealed value OPEN: `text` (the caption for media, "" when none), `fileName` (`fileNameEnc`
///   is not carried), `fmt`, `thumb`, `blurhash`, `linkPreview` url/title/desc, `replyTo.text`,
///   `reactions` emoji, and `fwd` always as its map, never the sealed JSON string;
/// - `uploading` dropped (in flight only).
/// A key whose value is the default (false, 0, empty, none) is left out; a reader treats a missing
/// key as that default, as it does for a Firestore document.
///
/// ⚠️ Keys this app never holds in `Message` (`rk`, `fwdChannel`, `pollCounts`, `pollTallyAt`,
/// `pollVoters`) are never written from here and are ignored when read; `consumed`, `held`,
/// `disappearSeconds`, `restrictRequest` and `pollClosed` are not in the database body, so a body read
/// back from the database carries them only when it was built from a live message.
enum WireBody {

    // MARK: - Message -> wire

    static func encode(_ m: Message, cid: String) -> [String: Any] {
        var w: [String: Any] = [
            "id": m.id,
            "cid": cid,
            "authorId": m.authorId,
            "createdAt": ms(m.createdAt),
            "text": m.text,
        ]
        func put(_ key: String, _ value: String?) { if let value, !value.isEmpty { w[key] = value } }
        func flag(_ key: String, _ value: Bool) { if value { w[key] = true } }

        put("type", m.type)
        put("clientId", m.clientId)
        if let t = m.clientTs { w["clientTs"] = ms(t) }
        if let e = m.expiresAt { w["expiresAt"] = ms(e) }

        // Content
        if let fmt = TextFormat.json(m.boldRanges) { w["fmt"] = fmt }
        if !m.mentions.isEmpty { w["mentions"] = m.mentions }
        if let lp = m.linkPreview {
            var d: [String: Any] = ["url": lp.url, "title": lp.title, "desc": lp.desc]
            if let u = lp.imageUrl { d["imageUrl"] = u }
            if let e = lp.imageEnc { d["imageEnc"] = e.asDict }
            w["linkPreview"] = d
        }
        put("stickerPack", m.stickerPack)
        put("stickerId", m.stickerId)
        put("emoji", m.stickerEmoji)
        if let a = m.stickerAnimated { w["animated"] = a }
        if let q = m.quoteId { w["quote"] = ["qid": q] }
        if let s = m.storyMention { w["storyMention"] = ["id": s.id, "thumb": s.thumbUrl] }

        // Media
        put("imageUrl", m.imageUrl)
        put("videoUrl", m.videoUrl)
        put("audioUrl", m.audioUrl)
        put("fileUrl", m.fileUrl)
        put("fileName", m.fileName)
        if let s = m.fileSize { w["fileSize"] = s }
        put("thumb", m.thumb)
        put("thumbUrl", m.thumbUrl)
        if let e = m.thumbEnc { w["thumbEnc"] = e.asDict }
        if let e = m.enc { w["enc"] = e.asDict }
        if !m.album.isEmpty {
            w["album"] = m.album.map { it -> [String: Any] in
                var d: [String: Any] = ["kind": it.kind, "imageUrl": it.imageUrl, "enc": it.enc.asDict,
                                        "width": it.width, "height": it.height]
                if let v = it.videoUrl { d["videoUrl"] = v }
                if let e = it.videoEnc { d["videoEnc"] = e.asDict }
                if it.isVideo || it.duration > 0 { d["duration"] = it.duration }
                return d
            }
        }
        if !m.albumSizes.isEmpty { w["albumSizes"] = m.albumSizes }
        if let v = m.width { w["width"] = v }
        if let v = m.height { w["height"] = v }
        if let v = m.duration { w["duration"] = v }
        if !m.waveform.isEmpty { w["waveform"] = m.waveform }
        put("blurhash", m.blurhash)

        // Thread
        if let r = m.replyTo {
            var d: [String: Any] = ["id": r.id, "authorId": r.authorId, "text": r.text]
            if r.isStatus { d["isStatus"] = true }
            if r.isReaction == true { d["isReaction"] = true }
            if let t = r.storyThumbUrl, !t.isEmpty { d["storyThumb"] = t }
            w["replyTo"] = d
        }
        flag("forwarded", m.forwarded)
        if let f = m.forwardSource { w["fwd"] = f.map }
        if m.replyCount > 0 { w["replyCount"] = m.replyCount }
        if !m.replyFaces.isEmpty { w["replyFaces"] = m.replyFaces }
        // The post's own switch only when it has one: unset means "the channel's default".
        if m.repliesOff(channelDefault: true) == m.repliesOff(channelDefault: false) {
            w["repliesOff"] = m.repliesOff(channelDefault: false)
        }
        if m.quoteCount > 0 { w["quoteCount"] = m.quoteCount }
        if !m.quoteFaces.isEmpty { w["quoteFaces"] = m.quoteFaces }

        // State
        flag("edited", m.edited)
        flag("deleted", m.deleted)
        put("deletedBy", m.deletedBy)
        flag("viewOnce", m.viewOnce)
        flag("consumed", m.consumed)
        flag("held", m.held)
        if let s = m.disappearSeconds { w["disappearSeconds"] = s }
        if !m.reactions.isEmpty { w["reactions"] = m.reactions }
        if !m.reactionCounts.isEmpty { w["reactionCounts"] = m.reactionCounts }
        if m.views > 0 { w["views"] = m.views }
        flag("pollClosed", m.pollClosed)

        // Calls and notices
        if let d = m.callDuration { w["callDuration"] = d }
        put("callOutcome", m.callOutcome)
        flag("callVideo", m.callVideo)
        put("callerUid", m.callerUid)
        if let u = m.callJoinedUids { w["joinedUids"] = u }
        if let u = m.callRungUids { w["rungUids"] = u }
        flag("restrictRequest", m.isRestrictRequest)
        put("bs", m.bubbleStyle)
        flag("bsd", m.bubbleDecor)
        return w
    }

    // MARK: - wire -> Message (no decryption: every value is already open)

    static func decode(_ w: [String: Any], cid: String) -> Message? {
        guard let id = w["id"] as? String, !id.isEmpty,
              let created = date(w["createdAt"]) else { return nil }
        func str(_ k: String) -> String? { w[k] as? String }
        func bool(_ k: String) -> Bool { w[k] as? Bool ?? false }
        func int(_ k: String) -> Int? { (w[k] as? NSNumber)?.intValue }
        func dbl(_ k: String) -> Double? { (w[k] as? NSNumber)?.doubleValue }
        func strings(_ k: String) -> [String]? { (w[k] as? [Any])?.compactMap { $0 as? String } }
        func encMeta(_ v: Any?) -> EncMeta? { (v as? [String: Any]).flatMap(EncMeta.init(map:)) }

        // The plainest init there is, then every field from the wire. Its notice symbol is unset
        // below, so nothing of the notice is left.
        var m = Message(localNotice: "", symbol: "", id: id, at: created)
        m.localNoticeSymbol = nil
        m.hasServerTime = true
        m.authorId = str("authorId") ?? ""
        m.text = str("text") ?? ""
        m.type = str("type")
        m.clientId = str("clientId")
        m.clientTs = date(w["clientTs"])
        m.expiresAt = date(w["expiresAt"])

        // Content
        if let fmt = str("fmt"), !fmt.isEmpty {
            m.boldSpans = TextFormat.spans(TextFormat.parse(fmt, length: (m.text as NSString).length))
        }
        m.mentions = strings("mentions") ?? []
        if let lp = w["linkPreview"] as? [String: Any], let url = lp["url"] as? String, !url.isEmpty {
            m.linkPreview = Message.LinkPreviewData(
                url: url, title: lp["title"] as? String ?? "", desc: lp["desc"] as? String ?? "",
                imageUrl: lp["imageUrl"] as? String, imageEnc: encMeta(lp["imageEnc"]))
        }
        m.stickerPack = str("stickerPack")
        m.stickerId = str("stickerId")
        m.stickerEmoji = str("emoji")
        m.stickerAnimated = w["animated"] as? Bool
        if let q = (w["quote"] as? [String: Any])?["qid"] as? String, QuoteStore.isQid(q) { m.quoteId = q }
        if let s = w["storyMention"] as? [String: Any], let sid = s["id"] as? String, !sid.isEmpty {
            m.storyMention = StoryMentionRef(id: sid, thumbUrl: s["thumb"] as? String ?? "")
        }

        // Media
        m.imageUrl = str("imageUrl")
        m.videoUrl = str("videoUrl")
        m.audioUrl = str("audioUrl")
        m.fileUrl = str("fileUrl")
        m.fileName = str("fileName")
        m.fileSize = int("fileSize")
        m.thumb = str("thumb").flatMap { $0.isEmpty ? nil : $0 }
        m.thumbUrl = str("thumbUrl")
        m.thumbEnc = encMeta(w["thumbEnc"])
        m.enc = encMeta(w["enc"])
        m.album = (w["album"] as? [[String: Any]])?.compactMap { d in
            guard let url = d["imageUrl"] as? String, let enc = encMeta(d["enc"]) else { return nil }
            return Message.AlbumItem(imageUrl: url, enc: enc,
                                     width: (d["width"] as? NSNumber)?.doubleValue ?? 1,
                                     height: (d["height"] as? NSNumber)?.doubleValue ?? 1,
                                     kind: d["kind"] as? String ?? "image",
                                     videoUrl: d["videoUrl"] as? String,
                                     videoEnc: encMeta(d["videoEnc"]),
                                     duration: MediaDuration.clean((d["duration"] as? NSNumber)?.doubleValue) ?? 0)
        } ?? []
        m.albumSizes = (w["albumSizes"] as? [Any])?.compactMap { row -> [Double]? in
            (row as? [Any])?.compactMap { ($0 as? NSNumber)?.doubleValue }
        } ?? []
        m.width = dbl("width")
        m.height = dbl("height")
        m.duration = MediaDuration.clean(dbl("duration"))
        m.waveform = (w["waveform"] as? [Any])?.compactMap { ($0 as? NSNumber)?.intValue } ?? []
        m.blurhash = str("blurhash").flatMap { $0.isEmpty ? nil : $0 }

        // Thread
        if let r = w["replyTo"] as? [String: Any] {
            m.replyTo = ReplyRef(id: r["id"] as? String ?? "",
                                 authorId: r["authorId"] as? String ?? "",
                                 text: r["text"] as? String ?? "",
                                 isStatus: r["isStatus"] as? Bool ?? false,
                                 storyThumbUrl: r["storyThumb"] as? String,
                                 isReaction: r["isReaction"] as? Bool)
        }
        m.forwarded = bool("forwarded")
        m.deleted = bool("deleted")
        // As the Firestore parser: a source only on a forwarded message that is still there.
        if m.forwarded, !m.deleted, let f = w["fwd"] as? [String: Any] { m.forwardSource = ForwardSource(map: f) }
        m.replyCount = max(0, int("replyCount") ?? 0)
        m.replyFaces = Array((strings("replyFaces") ?? []).prefix(3))
        if let off = w["repliesOff"] as? Bool { m.setPostRepliesSwitch(off) }
        m.quoteCount = max(0, int("quoteCount") ?? 0)
        m.quoteFaces = Array((strings("quoteFaces") ?? []).prefix(3))

        // State
        m.edited = bool("edited")
        m.deletedBy = str("deletedBy")
        m.viewOnce = bool("viewOnce")
        m.consumed = bool("consumed")
        m.held = bool("held")
        m.disappearSeconds = int("disappearSeconds")
        m.reactions = ((w["reactions"] as? [String: Any]) ?? [:]).compactMapValues { v -> String? in
            guard let s = v as? String, !s.isEmpty else { return nil }
            return s
        }
        m.reactionCounts = ((w["reactionCounts"] as? [String: Any]) ?? [:])
            .compactMapValues { ($0 as? NSNumber)?.intValue }.filter { $0.value > 0 }
        m.views = max(0, int("views") ?? 0)
        m.pollClosed = bool("pollClosed")

        // Calls and notices
        m.callDuration = int("callDuration")
        m.callOutcome = str("callOutcome")
        m.callVideo = bool("callVideo")
        m.callerUid = str("callerUid")
        m.callJoinedUids = strings("joinedUids")
        m.callRungUids = strings("rungUids")
        m.isRestrictRequest = bool("restrictRequest")
        if let bs = str("bs"), !bs.isEmpty, bs.count <= 32 { m.bubbleStyle = bs }
        m.bubbleDecor = bool("bsd")
        return m
    }

    // MARK: - Time

    /// Whole milliseconds since 1970, the wire's time unit.
    static func ms(_ d: Date) -> Int64 { Int64((d.timeIntervalSince1970 * 1000).rounded()) }

    private static func date(_ v: Any?) -> Date? {
        guard let n = v as? NSNumber else { return nil }
        return Date(timeIntervalSince1970: n.doubleValue / 1000)
    }
}
