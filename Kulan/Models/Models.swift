import Foundation
import Observation
import FirebaseFirestore

// Domain models. Field names match the existing Firestore schema EXACTLY so the
// native client reads the same data the RN app writes (see MIGRATION.md).

struct UserProfile: Identifiable, Equatable {
    let id: String            // uid
    var name: String
    var handle: String
    var about: String
    var photoUrl: String?
    var publicKeyB64: String?

    init(id: String, data: [String: Any]) {
        self.id = id
        self.name = data["name"] as? String ?? ""
        self.handle = data["handle"] as? String ?? ""
        self.about = data["about"] as? String ?? ""
        self.photoUrl = data["photoUrl"] as? String
        self.publicKeyB64 = data["publicKey"] as? String
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
    var viewOnce: Bool = false        // view-once photo (Signal-style): recipient can open it exactly once
    var album: [AlbumItem] = []       // 2+ photos sent together = ONE album message (grid + one caption)
    var localAlbum: [Data] = []       // optimistic album previews shown before upload
    var createdAt: Date
    var sendState: MessageSendState? = nil  // set only on local optimistic messages
    var localImageData: Data? = nil         // optimistic local photo shown before upload
    var localAudioData: Data? = nil         // optimistic local voice note shown before upload
    var localFile: Bool = false             // optimistic file bubble shown before upload (no fileUrl yet)
    var width: Double? = nil                // image pixel size -> natural aspect ratio bubble
    var height: Double? = nil
    var callerUid: String? = nil            // call record: who placed the call (viewer derives direction)
    var callOutcome: String? = nil          // answered | missed
    var callVideo: Bool = false             // placed as a video call (older records default to voice)
    var callDuration: Int? = nil            // seconds (0 if not answered)
    var edited: Bool = false                // text was edited after sending

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

    /// Local optimistic message shown instantly before the server confirms it.
    /// `id` = clientId until the server echo (matched by clientId) replaces it.
    init(localText: String, authorId: String, clientId: String, replyTo: ReplyRef?, sendState: MessageSendState) {
        self.id = clientId
        self.authorId = authorId
        self.text = localText
        self.clientId = clientId
        self.replyTo = replyTo
        self.reactions = [:]
        self.createdAt = Date()
        self.sendState = sendState
    }

    /// Local optimistic ALBUM — shows the picked photos as a grid instantly before upload.
    init(localAlbum: [Data], caption: String, authorId: String, clientId: String, sendState: MessageSendState) {
        self.id = clientId
        self.authorId = authorId
        self.text = caption
        self.type = "album"
        self.clientId = clientId
        self.reactions = [:]
        self.createdAt = Date()
        self.sendState = sendState
        self.localAlbum = localAlbum
    }

    // One photo inside an album message.
    struct AlbumItem: Equatable { let imageUrl: String; let enc: EncMeta; let width: Double; let height: Double }

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
        self.callerUid = data["callerUid"] as? String
        self.callOutcome = data["callOutcome"] as? String
        self.callVideo = data["callVideo"] as? Bool ?? false
        self.callDuration = (data["callDuration"] as? NSNumber)?.intValue
        self.edited = data["edited"] as? Bool ?? false
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
                             height: (d["height"] as? NSNumber)?.doubleValue ?? 1)
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
    }
}

struct Conversation: Identifiable, Equatable, Hashable {
    let id: String            // cid ("uidA_uidB")
    var users: [String]
    var names: [String: String]
    var photos: [String: String]
    var lastMessageCipher: String
    var lastImageUrl: String?          // last message's image (when it's a photo) → list thumbnail
    var lastImageEnc: EncMeta?         // enc meta to decrypt that thumbnail
    var lastSender: String             // uid of who sent the last message ("" if unknown)
    var unreadCount: [String: Int]
    var typing: [String: Bool]
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
        self.lastMessageCipher = data["lastMessage"] as? String ?? ""
        self.lastImageUrl = data["lastImageUrl"] as? String
        self.lastImageEnc = (data["lastImageEnc"] as? [String: Any]).flatMap(EncMeta.init(map:))
        self.lastSender = data["lastSender"] as? String ?? ""
        self.unreadCount = intMap(data["unreadCount"])
        self.typing = boolMap(data["typing"])
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

    // ── Group helpers ──
    var isGroup: Bool { convType == "group" }
    func isAdmin(_ me: String) -> Bool { admins.contains(me) }
    // Announcement mode: in a group with onlyAdminsSend, non-admins can't send.
    func canSend(_ me: String) -> Bool { !isGroup || !onlyAdminsSend || admins.contains(me) }
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
    func pinRank(_ me: String) -> Double { pinOrder[me] ?? updatedAtMillis }
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
