import Foundation
import Observation
import FirebaseFirestore

// Domain models. Field names match the existing Firestore schema EXACTLY so the
// native client reads the same data the RN app writes (see MIGRATION.md).

// Compile-time feature gates. Groups ship OFF for the App Store v1: the code stays
// in the project but every user-reachable door (create, join link, filter tab,
// contact-screen section, group header tap) is closed until this flips to true.
enum Flags {
    static let groupsEnabled = false
    /// Lets a person choose between the modern poster header and the classic circle in Settings.
    /// OFF (owner, 2026-08-02): everyone gets the modern header and nobody is offered the choice.
    /// The setting page and the classic header are both kept, wired and working — this only decides
    /// whether the door to them is on the wall. See ProfileLayoutStyle.resolved.
    static let profileLayoutChoice = false
    /// Shows the Avatar / Poster switch while you are framing a profile photo, so you can preview the
    /// same crop as both shapes. OFF (owner, 2026-08-02): "why user Chose Type of picture juts Hide
    /// this… only Show new design No tabs." Nothing about the crop changes — it was always ONE square
    /// and the circle is inscribed in it — so this only decides whether the preview is offered.
    static let profileCropShapePreview = false
}

struct UserProfile: Identifiable, Equatable {
    let id: String            // uid
    var name: String
    var handle: String
    var about: String
    var photoUrl: String?
    /// The TALL header framing. A separate crop of the same picture, chosen separately, because a
    /// face centred for a full-width header is not centred for a 40pt circle. nil = never set one.
    var posterUrl: String?
    var publicKeyB64: String?
    var privacy: [String: String]   // per-field audience: "everyone" | "contacts" | "nobody"
    /// Set when the owner asks for deletion. The account is HIDDEN from everyone else from that moment
    /// but nothing is destroyed until this date passes, so signing back in can restore it. nil = live.
    var deletionScheduledFor: Date?

    /// True while this account is inside its deletion grace period: hidden from search, contacts and
    /// stories, but not yet destroyed.
    var isAwaitingDeletion: Bool {
        guard let d = deletionScheduledFor else { return false }
        return d > Date()
    }

    init(id: String, data: [String: Any]) {
        self.id = id
        self.name = data["name"] as? String ?? ""
        self.handle = data["handle"] as? String ?? ""
        self.about = data["about"] as? String ?? ""
        if let ts = data["deletionScheduledFor"] as? Timestamp { self.deletionScheduledFor = ts.dateValue() }
        self.photoUrl = data["photoUrl"] as? String
        self.posterUrl = data["posterUrl"] as? String
        self.publicKeyB64 = data["publicKey"] as? String
        self.privacy = (data["privacy"] as? [String: String]) ?? [:]
    }
}

struct ReplyRef: Equatable {
    var id: String
    var authorId: String
    var text: String          // decrypted snippet
    var isStatus: Bool = false       // true = this quote points at a story/status, not a chat message
    var storyThumbUrl: String? = nil // plain (non-E2EE) story image URL, baked so it shows in-window
}

// Local delivery state for a message I'm sending. nil = a confirmed server message
// (its receipt is derived from the other person's lastRead instead).
enum MessageSendState: Equatable { case sending, failed }

struct Message: Identifiable, Equatable {
    let id: String
    var authorId: String
    var text: String          // DECRYPTED for display
    var type: String?         // "image" photos, "audio" voice notes, "file" documents, "video" videos
    var imageUrl: String?
    var audioUrl: String?
    var videoUrl: String?     // encrypted mp4 (deleted from storage after delivery — mailman model)
    var thumbUrl: String?     // encrypted video thumbnail (kept, so old bubbles still render)
    var thumbEnc: EncMeta?
    var fileUrl: String?      // encrypted document (type == "file")
    var fileName: String?     // original document name
    var fileSize: Int?        // bytes (for the "1.2 MB" label)
    var duration: Double?     // voice note length (seconds)
    var waveform: [Int] = []  // tiny amplitude bars (0…100) for the voice-note UI
    var enc: EncMeta?
    var clientId: String?
    var replyTo: ReplyRef?
    var reactions: [String: String]   // uid -> decrypted emoji
    var mentions: [String] = []       // uids @-mentioned in this message (groups)
    var viewOnce: Bool = false        // view-once photo (standard): recipient can open it exactly once
    var album: [AlbumItem] = []       // 2+ photos sent together = ONE album message (grid + one caption)
    var localAlbum: [Data] = []       // optimistic album previews shown before upload
    var localAlbumIsVideo: [Bool] = [] // per optimistic item: is it a video? (→ play badge before upload)
    var createdAt: Date
    var sendState: MessageSendState? = nil  // set only on local optimistic messages
    var localImageData: Data? = nil         // optimistic local photo shown before upload
    var localAudioData: Data? = nil         // optimistic local voice note shown before upload
    var localFile: Bool = false             // optimistic file bubble shown before upload (no fileUrl yet)
    var width: Double? = nil                // image pixel size -> natural aspect ratio bubble
    var blurhash: String? = nil             // sealed BlurHash of the photo → instant blurred placeholder
    var localMediaURL: String? = nil        // pending video/file payload persisted to tmp → retry can re-send the REAL bytes
    var height: Double? = nil
    var callerUid: String? = nil            // call record: who placed the call (viewer derives direction)
    var callOutcome: String? = nil          // answered | missed
    var callVideo: Bool = false             // placed as a video call (older records default to voice)
    var callDuration: Int? = nil            // seconds (0 if not answered)
    var edited: Bool = false                // text was edited after sending
    /// Deleted for everyone. The document SURVIVES as a tombstone so both sides see that something
    /// was here and removed, the way WhatsApp and Signal do it, instead of a message silently
    /// vanishing and leaving the other person wondering what they missed. The content is stripped
    /// server-side and the media is deleted from Storage, so what remains is a few bytes of marker.
    var deleted: Bool = false
    var forwarded: Bool = false             // passed along from another chat (bubble shows the tag)
    var clientTs: Date? = nil               // sender's tap time (ms epoch on the wire) — display order is send order

    var isImage: Bool { (type == "image" && (imageUrl?.isEmpty == false)) || (localImageData != nil && type != "video") }
    var isAudio: Bool { (type == "audio" && (audioUrl?.isEmpty == false)) || localAudioData != nil }
    // Optimistic videos carry their thumbnail in localImageData (hence the isImage carve-out).
    var isVideo: Bool { type == "video" && (videoUrl?.isEmpty == false || localImageData != nil) }
    var isFile: Bool { type == "file" && (fileUrl?.isEmpty == false || localFile) }
    var isGif: Bool { type == "gif" && (imageUrl?.isEmpty == false) }   // public Giphy url (not E2EE)
    var isAlbum: Bool { type == "album" && (!album.isEmpty || !localAlbum.isEmpty) }
    var isCall: Bool { type == "call" }
    var isSystem: Bool { type == "system" }   // group event ("X added Y"), shown centered

    /// Stable list identity: an optimistic message and its server echo share the
    /// same clientId, so the row updates in place (no delete+insert blink) on confirm.
    var rowId: String { clientId ?? id }

    /// The local half of "Delete for Everyone": the same strip the server applies, applied here the
    /// moment the user taps, so the bubble becomes a tombstone immediately instead of after a doc
    /// read, a write and the listener echo (about a second on wifi, far worse on a weak connection,
    /// which read as a dead button). The repository reverts to the original if the server refuses.
    ///
    /// Kept next to `deleted` on purpose: if the server-side strip in `ChatService.deleteMessage`
    /// ever gains a field, it has to gain one here too, or the optimistic bubble and the confirmed
    /// one stop matching. contactCard / locationCard / poll need no line of their own, they are
    /// computed from `text` and `type`, which both go here.
    func tombstoned() -> Message {
        var m = self
        m.deleted = true
        m.text = ""
        m.type = "text"
        m.enc = nil
        m.imageUrl = nil; m.audioUrl = nil; m.videoUrl = nil; m.fileUrl = nil
        m.thumbUrl = nil; m.thumbEnc = nil
        m.fileName = nil; m.fileSize = nil
        m.duration = nil; m.waveform = []
        m.width = nil; m.height = nil; m.blurhash = nil
        m.album = []; m.localAlbum = []; m.localAlbumIsVideo = []
        m.linkPreview = nil
        m.replyTo = nil
        m.reactions = [:]
        m.mentions = []
        m.viewOnce = false
        m.forwarded = false
        m.localImageData = nil; m.localAudioData = nil; m.localFile = false; m.localMediaURL = nil
        return m
    }

    /// A link preview that TRAVELLED WITH THE MESSAGE (Signal's model): the sender fetched it, sealed
    /// it, and the recipient renders it without ever contacting the site. All text fields arrive
    /// decrypted here; the image is an encrypted storage blob exactly like a photo's.
    struct LinkPreviewData: Equatable {
        let url: String
        let title: String
        let desc: String
        let imageUrl: String?
        let imageEnc: EncMeta?
        var host: String {
            URL(string: url)?.host?.replacingOccurrences(of: "www.", with: "") ?? url
        }
    }
    var linkPreview: LinkPreviewData? = nil

    /// Display-order time: the sender's TAP time when sane, else the server arrival time.
    /// Standard messenger rule — a slow-uploading photo stays ABOVE a fast text sent after it;
    /// messages never swap when the upload finishes. The 1h sanity cap ignores broken clocks.
    var sortAt: Date {
        if let c = clientTs, abs(createdAt.timeIntervalSince(c)) < 3600 { return c }
        return createdAt
    }

    /// Local optimistic IMAGE message — shows the picked photo instantly before upload.
    init(localImageData: Data, width: Double, height: Double, authorId: String, clientId: String, sendState: MessageSendState) {
        self.id = clientId
        self.authorId = authorId
        self.text = ""
        self.type = "image"
        self.clientId = clientId
        self.reactions = [:]
        self.createdAt = Date()
        self.sendState = sendState
        self.localImageData = localImageData
        self.width = width
        self.height = height
    }

    /// Local optimistic VIDEO — shows the thumbnail bubble instantly while the
    /// transcode + encrypt + upload run (play enables once the server echo lands).
    init(localVideoThumb: Data, duration: Double, width: Double, height: Double,
         authorId: String, clientId: String, sendState: MessageSendState) {
        self.id = clientId
        self.authorId = authorId
        self.text = ""
        self.type = "video"
        self.clientId = clientId
        self.reactions = [:]
        self.createdAt = Date()
        self.sendState = sendState
        self.localImageData = localVideoThumb
        self.duration = duration
        self.width = width
        self.height = height
    }

    /// Local optimistic VOICE note — shows the bubble (waveform + duration, playable from
    /// the just-recorded bytes) instantly, before the encrypt + upload finishes.
    init(localAudioData: Data, duration: Double, waveform: [Int], authorId: String, clientId: String, sendState: MessageSendState) {
        self.id = clientId
        self.authorId = authorId
        self.text = ""
        self.type = "audio"
        self.clientId = clientId
        self.reactions = [:]
        self.createdAt = Date()
        self.sendState = sendState
        self.localAudioData = localAudioData
        self.duration = duration
        self.waveform = waveform
    }

    /// Local optimistic FILE — shows the document bubble (name + size + spinner) instantly, before the
    /// encrypt + upload finishes; reconciled by clientId when the server echo lands.
    init(localFileName: String, fileSize: Int, authorId: String, clientId: String, sendState: MessageSendState) {
        self.id = clientId
        self.authorId = authorId
        self.text = ""
        self.type = "file"
        self.clientId = clientId
        self.reactions = [:]
        self.createdAt = Date()
        self.sendState = sendState
        self.localFile = true
        self.fileName = localFileName
        self.fileSize = fileSize
    }

    /// Local optimistic GIF — renders instantly from its public CDN url (nothing to upload), so
    /// sending a GIF glides the chat to the newest message exactly like a text send. GIF was the one
    /// send type with no optimistic bubble: it only appeared on the server echo, which is why it never
    /// scrolled (user report).
    init(localGifUrl: String, width: Double, height: Double, authorId: String, clientId: String, sendState: MessageSendState) {
        self.id = clientId
        self.authorId = authorId
        self.text = ""
        self.type = "gif"
        self.clientId = clientId
        self.reactions = [:]
        self.createdAt = Date()
        self.sendState = sendState
        self.imageUrl = localGifUrl
        self.width = width
        self.height = height
    }

    /// Local optimistic message shown instantly before the server confirms it.
    /// `id` = clientId until the server echo (matched by clientId) replaces it.
    init(localText: String, authorId: String, clientId: String, replyTo: ReplyRef?, sendState: MessageSendState,
         linkPreview: LinkPreviewData? = nil) {
        self.id = clientId
        self.authorId = authorId
        self.text = localText
        self.clientId = clientId
        self.replyTo = replyTo
        self.reactions = [:]
        self.createdAt = Date()
        self.sendState = sendState
        self.linkPreview = linkPreview   // plaintext draft — the card shows on the pending bubble too
    }

    /// Local optimistic ALBUM — shows the picked photos as a grid instantly before upload.
    init(localAlbum: [Data], caption: String, authorId: String, clientId: String, sendState: MessageSendState,
         localAlbumIsVideo: [Bool] = []) {
        self.id = clientId
        self.authorId = authorId
        self.text = caption
        self.type = "album"
        self.clientId = clientId
        self.reactions = [:]
        self.createdAt = Date()
        self.sendState = sendState
        self.localAlbum = localAlbum
        self.localAlbumIsVideo = localAlbumIsVideo
    }

    // One item inside an album message — a photo OR a video (mixed media grouping, as standard messengers do).
    // For a video, `imageUrl`/`enc` are its POSTER thumbnail; `videoUrl`/`videoEnc`/`duration` are the clip.
    struct AlbumItem: Equatable {
        let imageUrl: String
        let enc: EncMeta
        let width: Double
        let height: Double
        var kind: String = "image"          // "image" | "video"
        var videoUrl: String? = nil
        var videoEnc: EncMeta? = nil
        var duration: Double = 0
        var isVideo: Bool { kind == "video" }
    }

    init(id: String, data: [String: Any], cid: String, crypto: Crypto) {
        self.id = id
        self.authorId = data["authorId"] as? String ?? ""
        self.text = crypto.decrypt(data["text"] as? String ?? "", cid: cid, authorId: data["authorId"] as? String ?? "")
        self.type = data["type"] as? String
        self.imageUrl = data["imageUrl"] as? String
        self.audioUrl = data["audioUrl"] as? String
        self.videoUrl = data["videoUrl"] as? String
        self.thumbUrl = data["thumbUrl"] as? String
        self.thumbEnc = (data["thumbEnc"] as? [String: Any]).flatMap(EncMeta.init(map:))
        self.fileUrl = data["fileUrl"] as? String
        self.fileName = data["fileName"] as? String
        self.fileSize = (data["fileSize"] as? NSNumber)?.intValue
        self.duration = (data["duration"] as? NSNumber)?.doubleValue
        self.waveform = (data["waveform"] as? [Int])
            ?? (data["waveform"] as? [NSNumber])?.map { $0.intValue } ?? []
        self.width = (data["width"] as? NSNumber)?.doubleValue
        self.height = (data["height"] as? NSNumber)?.doubleValue
        // Sealed exactly like the caption; sentinels (key not warm / tampered) render as no placeholder.
        if let bh = data["blurhash"] as? String, !bh.isEmpty {
            let clear = crypto.decrypt(bh, cid: cid, authorId: data["authorId"] as? String ?? "")
            self.blurhash = (clear.isEmpty || clear == "…" || clear == "🔒") ? nil : clear
        }
        // The embedded link preview, sealed like the caption/blurhash. Sentinels (key not warm /
        // tampered) drop the whole card rather than rendering garbage.
        if let lp = data["linkPreview"] as? [String: Any] {
            let author = data["authorId"] as? String ?? ""
            func open(_ key: String) -> String {
                let raw = lp[key] as? String ?? ""
                guard !raw.isEmpty else { return "" }
                let clear = crypto.decrypt(raw, cid: cid, authorId: author)
                return (clear == "…" || clear == "🔒") ? "" : clear
            }
            let lpUrl = open("url")
            if !lpUrl.isEmpty {
                self.linkPreview = LinkPreviewData(
                    url: lpUrl, title: open("title"), desc: open("desc"),
                    imageUrl: lp["imageUrl"] as? String,
                    imageEnc: (lp["imageEnc"] as? [String: Any]).flatMap(EncMeta.init(map:)))
            }
        }
        self.callerUid = data["callerUid"] as? String
        self.callOutcome = data["callOutcome"] as? String
        self.callVideo = data["callVideo"] as? Bool ?? false
        self.callDuration = (data["callDuration"] as? NSNumber)?.intValue
        self.edited = data["edited"] as? Bool ?? false
        self.deleted = data["deleted"] as? Bool ?? false
        self.forwarded = data["forwarded"] as? Bool ?? false
        self.clientId = data["clientId"] as? String
        self.enc = (data["enc"] as? [String: Any]).flatMap(EncMeta.init(map:))
        // Each reaction is sealed by ITS reactor (the map key), so decrypt with that uid as
        // the author — group reactions (encg1) need it; 1:1 ignores authorId. Skip sentinels
        // (…, 🔒) so a not-yet-decryptable or tampered reaction never renders as a garbage pill.
        self.reactions = (data["reactions"] as? [String: String])?
            .reduce(into: [String: String]()) { acc, kv in
                let e = crypto.decrypt(kv.value, cid: cid, authorId: kv.key)
                if !e.isEmpty, e != "…", e != "🔒" { acc[kv.key] = e }
            } ?? [:]
        self.mentions = data["mentions"] as? [String] ?? []
        self.viewOnce = data["viewOnce"] as? Bool ?? false
        self.album = (data["album"] as? [[String: Any]])?.compactMap { d in
            guard let url = d["imageUrl"] as? String,
                  let enc = (d["enc"] as? [String: Any]).flatMap(EncMeta.init(map:)) else { return nil }
            return AlbumItem(imageUrl: url, enc: enc,
                             width: (d["width"] as? NSNumber)?.doubleValue ?? 1,
                             height: (d["height"] as? NSNumber)?.doubleValue ?? 1,
                             kind: d["kind"] as? String ?? "image",
                             videoUrl: d["videoUrl"] as? String,
                             videoEnc: (d["videoEnc"] as? [String: Any]).flatMap(EncMeta.init(map:)),
                             duration: (d["duration"] as? NSNumber)?.doubleValue ?? 0)
        } ?? []
        if let r = data["replyTo"] as? [String: Any] {
            self.replyTo = ReplyRef(
                id: r["id"] as? String ?? "",
                authorId: r["authorId"] as? String ?? "",
                // The reply snippet was sealed by the ENCLOSING message's sender, so decrypt
                // with that author (group). 1:1 ignores authorId (symmetric cid-pair key).
                text: crypto.decrypt(r["text"] as? String ?? "", cid: cid, authorId: data["authorId"] as? String ?? ""),
                isStatus: r["isStatus"] as? Bool ?? false,
                storyThumbUrl: r["storyThumb"] as? String   // plaintext story URL, no decrypt
            )
        }
        if let ts = data["createdAt"] as? Timestamp {
            self.createdAt = ts.dateValue()
        } else {
            self.createdAt = Date()
        }
        if let ms = (data["clientTs"] as? NSNumber)?.doubleValue {
            self.clientTs = Date(timeIntervalSince1970: ms / 1000)
        }
    }
}

struct Conversation: Identifiable, Equatable, Hashable {
    let id: String            // cid ("uidA_uidB")
    var users: [String]
    var names: [String: String]
    var photos: [String: String]
    /// Per-member TALL header photo, mirroring `photos`. Carried on the conversation for the same
    /// reason the avatar is: a profile has to know on its FIRST frame whether it has one to draw,
    /// and a value fetched from the user document arrives after the page is already on screen.
    var posters: [String: String]
    var lastMessageCipher: String
    var lastImageUrl: String?          // last message's image (when it's a photo) → list thumbnail
    var lastImageEnc: EncMeta?         // enc meta to decrypt that thumbnail
    var lastSender: String             // uid of who sent the last message ("" if unknown)
    var unreadCount: [String: Int]
    var typing: [String: Bool]
    // Voice-note recording rides the SAME "typing" field, as a string value ("audio-<seconds>")
    // instead of a Bool — old clients' boolMap reads it as not-typing and shows nothing.
    var recording: [String: Bool]
    // Stable digest of the RAW typing map. Recording's 10s refresh changes the value string without
    // changing the parsed Bools — the chat list's 15s self-clear restarts on THIS, so a live
    // recording never ages out while a crashed sender's stuck flag does.
    var typingRawKey: String
    var mutedBy: [String: Double]      // expiry in ms
    var pinnedBy: [String: Bool]
    var archivedBy: [String: Bool]
    var clearedAt: [String: Double]    // delete-for-me, ms
    var blockedBy: [String: Bool]
    var blockedAt: [String: Double]    // when each user blocked (ms) — hides later messages
    var pinOrder: [String: Double]     // per-user manual order for pinned chats
    var pinnedMessageId: String        // a pinned message in this chat ("" = none)
    var disappearSeconds: Int          // auto-delete timer (0 = off), shared by both members
    var convType: String               // "group" = group chat; "" / "direct" = 1:1
    var title: String                  // group name (groups only)
    var groupDescription: String       // group description / "about" (groups only)
    var avatarUrl: String?             // group photo (groups only)
    var admins: [String]               // uids allowed to manage the group
    var createdBy: String              // uid of the group creator (owner)
    var createdAt: Date?               // when the group was created
    var onlyAdminsSend: Bool           // announcement mode: only admins may send (groups)
    var membersCanAdd: Bool            // group: non-admins may add members (default false)
    var membersCanEditInfo: Bool       // group: non-admins may edit name/photo/desc (default false)
    // Per-flag admin rights (Telegram model): uid → granted right slugs. An admin with NO entry
    // has ALL rights (legacy behaviour); the owner (createdBy) always has all. See Conversation.Right.
    var inviteCode: String             // group's current primary invite-link code ("" = none)
    var adminRights: [String: [String]]
    // Per-member restrictions (Telegram bannedRights): uid → restricted flags + an auto-expiring
    // `until` timestamp (ms). Empty flags or a past `until` = no restriction. See Conversation.Restrict.
    var restrictedFlags: [String: [String]]
    var restrictedUntil: [String: Double]
    var lastReactionEnc: String?       // sealed emoji of the newest reaction (list preview)
    var lastReactionBy: String         // who reacted ("" = none)
    var lastReactionToAuthor: String   // author of the reacted-to message
    var lastReactionAtMillis: Double   // 0 = none; previewed only while newer than updatedAt
    var updatedAtMillis: Double

    init(id: String, data: [String: Any]) {
        self.id = id
        self.users = data["users"] as? [String] ?? []
        self.names = data["names"] as? [String: String] ?? [:]
        self.photos = data["photos"] as? [String: String] ?? [:]
        self.posters = data["posters"] as? [String: String] ?? [:]
        self.lastMessageCipher = data["lastMessage"] as? String ?? ""
        self.lastImageUrl = data["lastImageUrl"] as? String
        self.lastImageEnc = (data["lastImageEnc"] as? [String: Any]).flatMap(EncMeta.init(map:))
        self.lastSender = data["lastSender"] as? String ?? ""
        self.unreadCount = intMap(data["unreadCount"])
        // Typing = Bool true (older builds) OR the "text-<seconds>" refresh string senders now write.
        self.typing = (data["typing"] as? [String: Any] ?? [:])
            .compactMapValues { ($0 as? Bool) == true || ($0 as? String)?.hasPrefix("text") == true ? true : nil }
        self.recording = (data["typing"] as? [String: Any] ?? [:])
            .compactMapValues { ($0 as? String)?.hasPrefix("audio") == true ? true : nil }
        self.typingRawKey = (data["typing"] as? [String: Any] ?? [:])
            .map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ",")
        self.mutedBy = doubleMap(data["mutedBy"])
        self.pinnedBy = boolMap(data["pinnedBy"])
        self.archivedBy = boolMap(data["archivedBy"])
        self.clearedAt = doubleMap(data["clearedAt"])
        self.blockedBy = boolMap(data["blockedBy"])
        self.blockedAt = doubleMap(data["blockedAt"])
        self.pinOrder = doubleMap(data["pinOrder"])
        self.pinnedMessageId = data["pinnedMessageId"] as? String ?? ""
        self.disappearSeconds = (data["disappearSeconds"] as? NSNumber)?.intValue ?? 0
        self.convType = data["type"] as? String ?? ""
        self.title = data["title"] as? String ?? ""
        self.groupDescription = data["desc"] as? String ?? ""
        self.avatarUrl = data["avatarUrl"] as? String
        self.admins = data["admins"] as? [String] ?? []
        self.createdBy = data["createdBy"] as? String ?? ""
        self.createdAt = (data["createdAt"] as? Timestamp)?.dateValue()
        self.onlyAdminsSend = data["onlyAdminsSend"] as? Bool ?? false
        self.membersCanAdd = data["membersCanAdd"] as? Bool ?? false
        self.membersCanEditInfo = data["membersCanEditInfo"] as? Bool ?? false
        self.inviteCode = data["inviteCode"] as? String ?? ""
        self.adminRights = stringArrayMap(data["adminRights"])
        self.restrictedFlags = stringArrayMap(data["restrictedFlags"])
        self.restrictedUntil = doubleMap(data["restrictedUntil"])
        self.lastReactionEnc = data["lastReactionEnc"] as? String
        self.lastReactionBy = data["lastReactionBy"] as? String ?? ""
        self.lastReactionToAuthor = data["lastReactionToAuthor"] as? String ?? ""
        if let ts = data["lastReactionAt"] as? Timestamp {
            self.lastReactionAtMillis = ts.dateValue().timeIntervalSince1970 * 1000
        } else {
            self.lastReactionAtMillis = 0
        }
        if let ts = data["updatedAt"] as? Timestamp {
            self.updatedAtMillis = ts.dateValue().timeIntervalSince1970 * 1000
        } else {
            self.updatedAtMillis = 0
        }
    }

    func otherUid(_ me: String) -> String { users.first { $0 != me } ?? "" }
    func name(for me: String) -> String {
        let other = otherUid(me)
        // 1:1 only: a locally-saved contact name overrides the profile name.
        if !isGroup, let custom = ContactNames.shared.name(for: other) { return custom }
        return names[other] ?? "User"
    }
    func photoUrl(for me: String) -> String? { photos[otherUid(me)] }
    /// nil when they have never set a poster — the profile then draws the classic circle, which is
    /// also what everyone who last set a photo before this existed will get until they set a new one.
    func posterUrl(for me: String) -> String? { posters[otherUid(me)] }

    // ── Group helpers ──
    var isGroup: Bool { convType == "group" }
    func isAdmin(_ me: String) -> Bool { admins.contains(me) }
    func isOwner(_ me: String) -> Bool { !createdBy.isEmpty && createdBy == me }

    // Per-flag admin rights (Telegram-style). Slugs kept small, mapped to what Kulan actually gates.
    // Delegatable admin rights. Managing the admin TEAM (promote/demote/set-rights) is deliberately
    // NOT here — it is owner-only, so a limited admin can never mint an admin more powerful than
    // themselves or demote a peer the owner appointed.
    enum Right: String, CaseIterable, Identifiable {
        case changeInfo, deleteMessages, banUsers, inviteUsers, pinMessages, manageCalls
        var id: String { rawValue }
        var label: String {
            switch self {
            case .changeInfo:     return "Change group info"
            case .deleteMessages: return "Delete messages"
            case .banUsers:       return "Restrict / remove members"
            case .inviteUsers:    return "Add members"
            case .pinMessages:    return "Pin messages"
            case .manageCalls:    return "Manage video chats"
            }
        }
    }
    /// Can `uid` perform `right`? Owner → always. Admin with no adminRights entry → all (legacy).
    /// Admin with an entry → only the granted slugs. Non-admin → never.
    func adminCan(_ uid: String, _ right: Right) -> Bool {
        if isOwner(uid) { return true }
        guard admins.contains(uid) else { return false }
        guard let granted = adminRights[uid] else { return true }   // legacy admin = full rights
        return granted.contains(right.rawValue)
    }

    // Per-member restrictions (Telegram bannedRights). Slugs the client enforces at send time.
    enum Restrict: String, CaseIterable, Identifiable {
        case sendText, sendMedia, sendVoice, sendStickers, sendPolls, sendReactions, pinMessages, addMembers, changeInfo
        var id: String { rawValue }
    }
    /// Flags currently restricting `uid` (empty once the `until` timestamp passes). Admins/owner are never restricted.
    func activeRestrictions(_ uid: String, now: Double) -> Set<String> {
        if isOwner(uid) || admins.contains(uid) { return [] }
        guard (restrictedUntil[uid] ?? 0) > now, let flags = restrictedFlags[uid], !flags.isEmpty else { return [] }
        return Set(flags)
    }
    func isRestricted(_ uid: String, _ r: Restrict, now: Double) -> Bool {
        activeRestrictions(uid, now: now).contains(r.rawValue)
    }
    /// The "mute everything" preset = every send flag restricted (what the simple Mute action sets).
    static let muteAllFlags: [String] = [Restrict.sendText, .sendMedia, .sendVoice, .sendStickers, .sendPolls, .sendReactions].map(\.rawValue)
    /// True if `uid` is fully muted (can't send any content) right now.
    func isMutedMember(_ uid: String, now: Double) -> Bool {
        activeRestrictions(uid, now: now).contains(Restrict.sendText.rawValue)
    }

    // Announcement mode: in a group with onlyAdminsSend, non-admins can't send. Also blocks a
    // member restricted from sending text.
    func canSend(_ me: String) -> Bool {
        if !isGroup { return true }
        if onlyAdminsSend && !admins.contains(me) && !isOwner(me) { return false }
        return true
    }
    /// Send gate that also honours a live restriction (needs `now` for the expiry check).
    func canSend(_ me: String, now: Double) -> Bool {
        canSend(me) && !isMutedMember(me, now: now)
    }
    /// Everyone but me (the fan-out set; N-1 people in a group).
    func others(_ me: String) -> [String] { users.filter { $0 != me } }
    /// Header title: group name for groups, the other person's name for 1:1.
    func displayName(_ me: String) -> String { isGroup ? (title.isEmpty ? "Group" : title) : name(for: me) }
    /// Header photo: group avatar for groups, the other person's photo for 1:1.
    func displayPhoto(_ me: String) -> String? { isGroup ? avatarUrl : photoUrl(for: me) }
    /// Group header subtitle, e.g. "7 members".
    var memberCountLabel: String { "\(users.count) member\(users.count == 1 ? "" : "s")" }
    func unread(_ me: String) -> Int { unreadCount[me] ?? 0 }
    func isMuted(_ me: String, now: Double) -> Bool { (mutedBy[me] ?? 0) > now }
    func isBlockedByMe(_ me: String) -> Bool { blockedBy[me] ?? false }
    func blockedAtMillis(_ me: String) -> Double { blockedAt[me] ?? 0 }
    // Silent block in the chat LIST: a chat I blocked whose latest activity is the
    // blocked person's post-block message — its preview/time/order must be frozen.
    func leaksBlocked(_ me: String) -> Bool {
        isBlockedByMe(me) && blockedAtMillis(me) > 0 && updatedAtMillis > blockedAtMillis(me)
    }
    /// Sort/time key that ignores the blocked person's later messages (freezes at block time).
    func displayUpdatedAt(_ me: String) -> Double {
        leaksBlocked(me) ? blockedAtMillis(me) : updatedAtMillis
    }
    func isPinned(_ me: String) -> Bool { pinnedBy[me] ?? false }
    /// Manual order for pinned chats; defaults to recency so never-moved pins stay sensible.
    /// FROZEN recency (audit): the raw fallback let a silently-blocked pinned chat jump to the top
    /// of the pinned block on each of their messages — exactly the activity the freeze hides.
    func pinRank(_ me: String) -> Double { pinOrder[me] ?? displayUpdatedAt(me) }
    func isArchived(_ me: String) -> Bool { archivedBy[me] ?? false }
    /// "delete for me" until a newer message arrives (parity with RN Db.isCleared).
    func isCleared(_ me: String) -> Bool { updatedAtMillis <= (clearedAt[me] ?? 0) }
    /// My message is the most recent one — show delivery/read ticks for it in the list.
    func lastIsMine(_ me: String) -> Bool { !lastSender.isEmpty && lastSender == me }
    /// The other person has read my last message once their unread count hits 0.
    /// In a group, "read" = every other member's unread count is 0.
    func lastReadByOther(_ me: String) -> Bool {
        if isGroup { return others(me).allSatisfy { (unreadCount[$0] ?? 0) == 0 } }
        return (unreadCount[otherUid(me)] ?? 0) == 0
    }
    /// A reaction newer than the last message → the chat list previews it ("Reacted 🙏").
    /// Hidden for silently-blocked reactors, and for reactions older than a delete-for-me.
    func freshReaction(_ me: String) -> Bool {
        !lastReactionBy.isEmpty && lastReactionEnc != nil
            && lastReactionAtMillis > updatedAtMillis
            && lastReactionAtMillis > (clearedAt[me] ?? 0)
            && !(isBlockedByMe(me) && lastReactionBy != me)
    }
}

extension EncMeta {
    init?(map: [String: Any]) {
        guard let n = map["n"] as? String,
              let k = map["k"] as? String,
              let kn = map["kn"] as? String else { return nil }
        self.init(v: (map["v"] as? Int) ?? 1, n: n, k: k, kn: kn,
                  w: map["w"] as? [String: String],   // group per-member wraps (was dropped!)
                  a: map["a"] as? String)              // group author
    }
}

// MARK: - Local chat-list state (device-only; never written to the server)

/// Unsent composer drafts, keyed by conversation id: leave a chat with text still in
/// the box and the chat list shows "Draft: …" until you send or clear it.
@Observable
final class Drafts {
    static let shared = Drafts()
    private static let key = "chatDrafts"
    private(set) var map: [String: String]
    private init() { map = UserDefaults.standard.dictionary(forKey: Self.key) as? [String: String] ?? [:] }

    func text(_ cid: String) -> String { map[cid] ?? "" }
    func set(_ cid: String, _ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard map[cid] ?? "" != t else { return }   // no-op → no observation churn per keystroke
        if t.isEmpty { map.removeValue(forKey: cid) } else { map[cid] = t }
        UserDefaults.standard.set(map, forKey: Self.key)
    }

    /// Sign-out/delete: drafts are unsent plaintext — wipe with the account.
    func clear() {
        map = [:]
        UserDefaults.standard.removeObject(forKey: Self.key)
    }
}

/// Which incoming voice notes have been PLAYED (not just seen). Drives the accent
/// "unheard" mic in the chat list and the dot on the bubble. Opening a chat is not
/// hearing a voice note, so this is separate from the unread count.
@Observable
final class PlayedVoice {
    static let shared = PlayedVoice()
    private static let idsKey = "playedVoiceIds"
    private static let upToKey = "playedVoiceUpTo"
    private(set) var ids: Set<String>
    private(set) var upTo: [String: Double]   // cid → createdAt ms of the newest played incoming note
    private init() {
        ids = Set(UserDefaults.standard.stringArray(forKey: Self.idsKey) ?? [])
        upTo = UserDefaults.standard.dictionary(forKey: Self.upToKey) as? [String: Double] ?? [:]
    }

    /// Sign-out/delete: reset played-state with the account.
    func clear() {
        ids = []
        upTo = [:]
        UserDefaults.standard.removeObject(forKey: Self.idsKey)
        UserDefaults.standard.removeObject(forKey: Self.upToKey)
    }

    /// Chat list: the newest message is an incoming voice note that hasn't been played.
    func lastVoiceUnplayed(_ conv: Conversation, me: String) -> Bool {
        guard conv.lastMessageCipher.hasPrefix("🎤 Voice message"),
              !conv.lastIsMine(me), !conv.leaksBlocked(me) else { return false }
        return conv.updatedAtMillis > (upTo[conv.id] ?? 0)
    }

    /// Thread bubble: this specific note hasn't been played on this device.
    func isUnplayed(cid: String, messageId: String, createdAt: Date) -> Bool {
        if ids.contains(messageId) { return false }
        // Anything at/before the newest played note counts as heard — keeps ancient
        // history quiet even when its ids have been trimmed from the capped set.
        return createdAt.timeIntervalSince1970 * 1000 > (upTo[cid] ?? 0)
    }

    func markPlayed(cid: String, messageId: String, createdAt: Date) {
        guard !ids.contains(messageId) else { return }
        ids.insert(messageId)
        var arr = UserDefaults.standard.stringArray(forKey: Self.idsKey) ?? []
        arr.append(messageId)
        if arr.count > 600 { arr.removeFirst(arr.count - 600) }   // cap the stored set
        UserDefaults.standard.set(arr, forKey: Self.idsKey)
        let ms = createdAt.timeIntervalSince1970 * 1000
        if ms > (upTo[cid] ?? 0) { upTo[cid] = ms }
        UserDefaults.standard.set(upTo, forKey: Self.upToKey)
    }
}

// Firestore returns map values as Any (NSNumber-backed); convert safely.
private func intMap(_ any: Any?) -> [String: Int] {
    guard let m = any as? [String: Any] else { return [:] }
    return m.compactMapValues { ($0 as? NSNumber)?.intValue }
}
private func doubleMap(_ any: Any?) -> [String: Double] {
    guard let m = any as? [String: Any] else { return [:] }
    return m.compactMapValues { ($0 as? NSNumber)?.doubleValue }
}
private func boolMap(_ any: Any?) -> [String: Bool] {
    guard let m = any as? [String: Any] else { return [:] }
    return m.compactMapValues { $0 as? Bool }
}
private func stringArrayMap(_ any: Any?) -> [String: [String]] {
    guard let m = any as? [String: Any] else { return [:] }
    return m.compactMapValues { ($0 as? [Any])?.compactMap { $0 as? String } }
}

// MARK: - Shared contact card (rides the encrypted text pipeline as a marker — no new message fields)

struct SharedContactCard {
    let uid: String
    let name: String
    let photo: String?
}

extension Message {
    static let contactMarker = "kulan-contact:"
    /// Marker format: "kulan-contact:<uid>|<photoURL-or-empty>|<name>" (name last — it may contain "|"-free
    /// arbitrary text; uid/photo never contain "|"). Returns nil for normal messages.
    var contactCard: SharedContactCard? {
        guard text.hasPrefix(Self.contactMarker) else { return nil }
        let body = text.dropFirst(Self.contactMarker.count)
        let parts = body.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, !parts[0].isEmpty, !parts[2].isEmpty else { return nil }
        return SharedContactCard(uid: String(parts[0]),
                                 name: String(parts[2]),
                                 photo: parts[1].isEmpty ? nil : String(parts[1]))
    }
    static func contactMarkerText(uid: String, name: String, photo: String?) -> String {
        "\(contactMarker)\(uid)|\(photo ?? "")|\(name)"
    }
}

// MARK: - Shared location (same encrypted-text marker transport as contact cards)

struct SharedLocationCard {
    let lat: Double
    let lon: Double
    let label: String?
}

extension Message {
    static let locationMarker = "kulan-location:"
    /// "kulan-location:<lat>|<lon>|<label-or-empty>"
    var locationCard: SharedLocationCard? {
        guard text.hasPrefix(Self.locationMarker) else { return nil }
        let parts = text.dropFirst(Self.locationMarker.count)
            .split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 2, let lat = Double(parts[0]), let lon = Double(parts[1]) else { return nil }
        let label = parts.count == 3 && !parts[2].isEmpty ? String(parts[2]) : nil
        return SharedLocationCard(lat: lat, lon: lon, label: label)
    }
    static func locationMarkerText(lat: Double, lon: Double, label: String?) -> String {
        "\(locationMarker)\(lat)|\(lon)|\(label ?? "")"
    }
}

// MARK: - Pinned-message notice (Telegram-style "X pinned …" row in the chat). E2EE-SAFE: the
// snippet rides the ENCRYPTED text pipeline as a feature marker — a plaintext system message would
// leak message content to the server.

struct PinNoticeCard {
    let messageId: String   // the pinned message → the notice is tappable (jump to it)
    let label: String       // "\"snippet…\"" or "a photo" / "a voice message" / …
}

extension Message {
    static let pinMarker = "kulan-pinned:"
    /// "kulan-pinned:<messageId>|<label>" (label last — may contain any characters).
    var pinNotice: PinNoticeCard? {
        guard text.hasPrefix(Self.pinMarker) else { return nil }
        let parts = text.dropFirst(Self.pinMarker.count)
            .split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return PinNoticeCard(messageId: String(parts[0]), label: String(parts[1]))
    }
    static func pinMarkerText(messageId: String, label: String) -> String {
        "\(pinMarker)\(messageId)|\(label)"
    }
}

// MARK: - Poll (Telegram-style). E2EE-SAFE: the question + options ride the ENCRYPTED text pipeline as
// a "kulan-poll:" marker (base64 JSON), so the server never sees them. Votes live in a per-voter
// subcollection (messages/{mid}/votes/{uid}) as plain option INDICES — meaningless without the
// end-to-end-encrypted options — and each voter can only write their own doc.

struct PollCard: Equatable {
    let id: String
    let question: String
    let options: [String]
    let multiple: Bool
}

extension Message {
    static let pollMarker = "kulan-poll:"
    var poll: PollCard? {
        guard text.hasPrefix(Self.pollMarker) else { return nil }
        let b64 = String(text.dropFirst(Self.pollMarker.count))
        guard let data = Data(base64Encoded: b64),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = obj["id"] as? String,
              let q = obj["q"] as? String,
              let opts = obj["opts"] as? [String], opts.count >= 2 else { return nil }
        return PollCard(id: id, question: q, options: opts, multiple: obj["multi"] as? Bool ?? false)
    }
    static func pollMarkerText(id: String, question: String, options: [String], multiple: Bool) -> String {
        let obj: [String: Any] = ["id": id, "q": question, "opts": options, "multi": multiple]
        let data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
        return pollMarker + data.base64EncodedString()
    }
}

// MARK: - Forward compatibility: structured feature payloads share the reserved "kulan-<feature>:"
// namespace over the text pipeline. A build that does NOT recognize a given feature (e.g. a stable
// version receiving a payload from a newer beta) renders it as a system "sent with a newer version"
// notice instead of the raw marker text. When you add a NEW feature marker, add its prefix to
// `knownFeatureMarkers` so THIS version keeps rendering it normally.
extension Message {
    static let knownFeatureMarkers: [String] = [contactMarker, locationMarker, pinMarker, pollMarker]

    /// True when the text uses the reserved kulan-feature namespace with a feature this build doesn't
    /// know — i.e. it was sent by a newer app version. Matched strictly (`^kulan-<name>:`) so ordinary
    /// text that merely contains "kulan-" is never affected. (Alphanumeric so future names like
    /// `kulan-poll2:` / `kulan-livelocation:` are still caught.)
    static let featureMarkerPattern = "^kulan-[a-z0-9]+:"
    var isUnsupportedFeature: Bool {
        guard let r = text.range(of: Message.featureMarkerPattern, options: .regularExpression) else { return false }
        return !Message.knownFeatureMarkers.contains(String(text[r]))
    }

    /// True for ANY reserved feature marker (known or not), including a malformed one that failed to
    /// parse into a card — used to keep the raw marker out of text surfaces.
    var isFeatureMarker: Bool {
        text.range(of: Message.featureMarkerPattern, options: .regularExpression) != nil
    }

    /// A safe human-friendly label for surfaces that must NEVER show raw text/markers — reply quotes,
    /// clipboard, forward/info headers. For ordinary messages it is just the text; for feature markers
    /// it is a friendly noun (mirrors the chat-list preview). Media types keep their own snippet logic
    /// elsewhere; this only rescues the marker-carrying text messages.
    var safeText: String {
        if contactCard != nil { return "Contact" }
        if locationCard != nil { return "Location" }
        if let p = poll { return "📊 \(p.question)" }
        if pinNotice != nil { return "Pinned a message" }
        if isUnsupportedFeature { return "Message from a newer version" }
        if isFeatureMarker { return "Message" }   // malformed known marker → never leak the raw payload
        return text
    }
}
