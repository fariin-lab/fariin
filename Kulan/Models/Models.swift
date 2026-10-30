import Foundation
import Observation
import CryptoKit   // drafts are sealed at rest — see the note on `Drafts`
import FirebaseFirestore
import UIKit   // the inline thumbnail is decoded here, next to the field that carries it

// Domain models. Field names match the existing Firestore schema EXACTLY so the
// native client reads the same data the RN app writes (see MIGRATION.md).

// Compile-time feature gates. Groups ship OFF for the App Store v1: the code stays
// in the project but every user-reachable door (create, join link, filter tab,
// contact-screen section, group header tap) is closed until this flips to true.
enum Flags {
    /// Channel Schedule Post (Hold Post > Schedule Post, Channel Settings > Scheduled Posts).
    /// HIDDEN, owner 2026-10-29: "remove or hide, I don't need it now". The code stays; true brings
    /// both doors back.
    static let schedulePosts = false
    /// Unfinished: the admin panel can only switch it OFF (RemoteFeatures, next open).
    /// ON for testing — owner 2026-10-18: "turn on all group doors, will turn off later". Off again
    /// from the panel (config/features groups=false, next open) or by flipping this back.
    static var groupsEnabled: Bool { RemoteFeatures.offOnly("groups", default: true) }
    /// "Create new groups" (owner 2026-10-18, admin panel): OFF hides every way to MAKE a group and
    /// the rules refuse one; groups that exist keep working. Live (`LiveFeatures`), on unless set.
    static var groupCreateEnabled: Bool { groupsEnabled && LiveFeatures.shared.values["groupCreate"] != false }
    /// Group Statistics page (owner 2026-10-26, admin panel Features switch). Live; on unless set.
    static var groupStatsEnabled: Bool { LiveFeatures.shared.values["groupStats"] != false }
    /// The "All Members" bubble cloud on a group's page (owner 2026-10-19): off, every group, or
    /// the groups the admin panel picks (config/features memberCloud). Live; off unless set.
    static func memberCloud(for cid: String) -> Bool { LiveFeatures.shared.memberCloud.isOn(for: cid) }
    /// Two-step verification's door in Settings. OFF (owner, 2026-09-25: "turn off 2FA as groups,
    /// we are not ready to finalize"). Only the door closes. An account that ALREADY turned it on
    /// still sees the row, so it can turn it off, and still gets the sign-in password prompt,
    /// because the database rules keep enforcing the claim for that account; hiding the prompt
    /// would lock it out of its own data.
    static var twoStepEnabled: Bool { RemoteFeatures.offOnly("twoStep", default: false) }
    /// Profile links (the capsules under the bio, and Edit Profile › Links). OFF (owner,
    /// 2026-09-27: "link feature hide, don't delete, hide by flag"). Only what people SEE goes:
    /// saved links stay on the profile and in `ProfileLinksView`, and come back when this flips.
    /// Finished: on or off from the admin panel (RemoteFeatures, next open).
    static var profileLinksEnabled: Bool { RemoteFeatures.value("profileLinks", default: false) }
    /// The Official Announcements admin screen in Settings. OFF (owner, 2026-09-25): the admin panel
    /// will live on a fariin.com subdomain instead of inside the app. Only the door closes; the
    /// channel everyone reads, the admin rules and the sending functions are untouched, so the web
    /// panel can use the same backend.
    static let inAppAnnouncementAdmin = false
    /// Puts the Verification console in Settings. OFF (owner, 2026-08-05): the whole system is built,
    /// wired and enforced — this only decides whether the door to it is on the wall. Turning it on is
    /// this one word; nothing else has to change, and badges granted while it was off keep showing.
    ///
    /// Hiding it here does NOT weaken anything. The Firestore rules gate every write on the `verify`
    /// capability independently, so the console being absent from the screen and the console being
    /// unusable by a stranger are two separate defences and only the second one ever mattered.
    static let verificationConsole = false
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
    /// The admin panel opened group stories for this person in any group they run, whatever its size
    /// (owner 2026-10-23). Server-only field (`serverOnlyUserFields`).
    var groupStoryOpen = false
    var name: String
    var handle: String
    var about: String
    var photoUrl: String?
    /// The TALL header framing. A separate crop of the same picture, chosen separately, because a
    /// face centred for a full-width header is not centred for a 40pt circle. nil = never set one.
    var posterUrl: String?
    /// ⛔ THE PICTURE THAT CANNOT BE LATE. A base64 JPEG about 30px on its long edge — the same
    /// thing a story carries in `blurThumb`, for the same reason. It travels IN the user document,
    /// so it is already in hand the moment the profile opens and there is no state where we know
    /// somebody has a photograph and have nothing of it to draw. The header blurs it and the real
    /// picture fades in on top. Nil for accounts whose photo was set before this existed; those
    /// still fall back to the letter.
    var photoThumb: String?
    var publicKeyB64: String?
    /// The account's verification record, or nil for the overwhelming majority who have none. Granted
    /// only by us, never requested, never bought — see Verification.swift.
    var verification: Verification?
    var privacy: [String: String]   // per-field audience: "everyone" | "contacts" | "nobody"
    /// ⛔ THE GLOW COUNTS, AND THEY ARE THE SERVER'S — his Glow feature, 2026-09-02. Public numbers
    /// on a document any signed-in account may read, which is the half of his privacy ruling that
    /// is meant to travel: counts are public, the NAME LISTS are the owner's alone and the rules
    /// enforce that separately.
    ///
    /// ⚠️ Both names are in `serverOnlyUserFields()` in `firestore.rules`, so no phone can inflate
    /// its own — the same protection the verification badge has. They are written by `onGlowWrite`
    /// off the /glows collection. **Zero until that function is deployed**, which is why the profile
    /// card reads them straight and never counts rows itself: counting would need the very list the
    /// rules refuse to hand over for anybody but yourself.
    var glowerCount: Int = 0
    var glowingCount: Int = 0
    /// ⛔ WHEN THIS ACCOUNT WAS MADE — his concept, 2026-09-09: a "Joined May 2026" pill under the
    /// bio. Optional, and the pill is simply absent when it is nil, because it genuinely is unknown
    /// for anyone whose account document was written before the field existed. A profile page must
    /// not invent a date; a wrong joining date is worse than no line at all.
    var joinedAt: Date?
    /// ⛔ THE PROFILE'S LINKS — see `ProfileLink`. Up to two, in the order the owner put them.
    var links: [ProfileLink] = []
    /// Set when the owner asks for deletion. The account is HIDDEN from everyone else from that moment
    /// but nothing is destroyed until this date passes, so signing back in can restore it. nil = live.
    var deletionScheduledFor: Date?
    /// Banned from the admin panel. Only the server writes it (readable like the rest of the profile);
    /// the rules refuse a banned account's stories,
    /// and the app reads it only to say so before the picker opens (2026-10-13).
    var banned: Bool = false
    /// The phone's language, 2-letter ISO (owner 2026-10-26, Group Statistics' Languages chart).
    /// Written by my own phone at launch (`ProfileStore.syncMyLanguage`).
    var lang: String?

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
        self.groupStoryOpen = data["groupStoryOpen"] as? Bool ?? false
        self.lang = data["lang"] as? String
        self.posterUrl = data["posterUrl"] as? String
        self.photoThumb = data["photoThumb"] as? String
        self.publicKeyB64 = data["publicKey"] as? String
        // Verification rides along with the profile rather than being fetched. See Verification.swift
        // for why that single decision is what makes the badge appear everywhere without a request.
        self.verification = Verification(data["verification"] as? [String: Any])
        self.privacy = (data["privacy"] as? [String: String]) ?? [:]
        // Absent on every account until the function has run for it once, and absent means zero —
        // which is the truth for somebody nobody has glowed.
        self.glowerCount = data["glowerCount"] as? Int ?? 0
        self.glowingCount = data["glowingCount"] as? Int ?? 0
        // `createdAt` is the account document's own creation stamp. Nil for accounts written before
        // anything recorded it — see `joinedAt`.
        self.joinedAt = (data["createdAt"] as? Timestamp)?.dateValue()
        self.links = ProfileLink.list(from: data["links"])
        self.banned = data["banned"] as? Bool ?? false
    }
}

/// ⛔ A LINK SOMEBODY PUTS ON THEIR PROFILE — owner, 2026-09-11: an "Add link" card under the bio in
/// Edit Profile, opening a page like the username one, where each account may keep up to two. They
/// appear on the profile as small pills under the bio, on other people's and on your own.
///
/// ⚠️ A TITLE AND A URL, AND THE TITLE IS WHAT PEOPLE READ. The pill shows the title alone, so a
/// link with no title would be a blank pill — the editor requires both, and the parser below drops
/// anything missing either rather than drawing a hole.
///
/// ⚠️ NO `UUID` FOR THE IDENTITY. These round-trip through Firestore as plain maps, so a generated
/// id would be a different value every time the document is read and every list animation would
/// treat an unchanged link as a new one. The pair itself is the identity.
struct ProfileLink: Identifiable, Equatable, Hashable {
    var title: String
    var url: String

    var id: String { "\(url)\u{1}\(title)" }

    /// How many an account may keep. His number.
    static let maxPerUser = 2
    static let maxTitleChars = 30
    static let maxUrlChars = 250

    /// What the pill and the list row show under the title: the address without its scheme or its
    /// "www.", because "https://" is four fifths of a short link and says nothing.
    var displayUrl: String {
        var s = url
        for prefix in ["https://", "http://"] where s.hasPrefix(prefix) {
            s = String(s.dropFirst(prefix.count))
        }
        if s.hasPrefix("www.") { s = String(s.dropFirst(4)) }
        if s.hasSuffix("/") { s = String(s.dropLast()) }
        return s
    }

    /// ⚠️ THE SCHEME IS ADDED BACK FOR OPENING, because somebody typing a link types
    /// "example.com/name" and `URL(string:)` will happily build a relative URL out of that which
    /// opens nothing. `https` rather than `http`: this is 2026, and the worst case is one redirect.
    var openURL: URL? {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let absolute = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let u = URL(string: absolute), let host = u.host, host.contains(".") else { return nil }
        // ⛔ ONLY THE WEB. A profile field that could carry any scheme is a profile field that can
        // carry `javascript:` or a deep link into another app's private surface, and this value
        // comes from a stranger. Two schemes, both harmless, both what anybody actually means.
        guard let scheme = u.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return nil }
        return u
    }

    /// What goes into the user document: plain maps, in order, capped.
    static func encode(_ links: [ProfileLink]) -> [[String: String]] {
        links.prefix(maxPerUser).map { ["title": $0.title, "url": $0.url] }
    }

    static func list(from raw: Any?) -> [ProfileLink] {
        guard let items = raw as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            let title = (item["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let url = (item["url"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, !url.isEmpty else { return nil }
            return ProfileLink(title: String(title.prefix(maxTitleChars)),
                               url: String(url.prefix(maxUrlChars)))
        }
        // Trimmed on the way IN as well as on the way out: an older build, or a hand-edited
        // document, can hold more than the ceiling and the profile must not grow a third pill.
        .prefix(maxPerUser)
        .map { $0 }
    }
}

struct ReplyRef: Equatable, Codable {
    var id: String
    var authorId: String
    var text: String          // decrypted snippet
    var isStatus: Bool = false       // true = this quote points at a story/status, not a chat message
    var storyThumbUrl: String? = nil // plain (non-E2EE) story image URL, baked so it shows in-window
    /// Sent from the story's REACT BAR (owner 2026-10-13): drawn on the card's corner, not as a
    /// message under it. Optional so cached messages from older builds still decode.
    var isReaction: Bool? = nil
}

extension Message {
    /// ⛔ A STORY REACTION (an emoji sent from a story's react bar) is a mark on the story, not a
    /// message to answer: owner 2026-10-13, "when somebody reacts to my story I can reply to it or
    /// react to that emoji; stop that — only for the react bar, not for typed replies". Nobody can
    /// reply to it or react to it, by swipe, double tap or menu, and reactions already on one are hidden.
    var isStoryReaction: Bool { replyTo?.isStatus == true && replyTo?.isReaction == true }
}

// Local delivery state for a message I'm sending. nil = a confirmed server message
// (its receipt is derived from the other person's lastRead instead).
enum MessageSendState: Equatable { case sending, failed }

/// Decoded inline thumbnails, held OUTSIDE the model.
///
/// `Message` is a struct that is copied constantly and re-parsed on every snapshot, and the bubble
/// asks for its preview on every body evaluation. Decoding a base64 JPEG each of those times is
/// pointless work on the main thread, and a stored `UIImage` would make every copy of the struct
/// heavier. Keyed by `rowId` because that is the id a bubble keeps across the optimistic-to-real
/// handover. NSCache, so memory pressure empties it and the next draw simply decodes again.
enum InlineThumbCache {
    private static let cache = NSCache<NSString, UIImage>()

    static func image(id: String, base64: String?) -> UIImage? {
        guard let base64, !base64.isEmpty else { return nil }
        if let hit = cache.object(forKey: id as NSString) { return hit }
        guard let data = Data(base64Encoded: base64), let raw = UIImage(data: data) else { return nil }
        // ⛔ FORCE THE BITMAP DECODE. `UIImage(data:)` is lazy: it parses the header and defers the
        // actual pixels until something draws it — which is the main thread, mid-scroll, in the
        // frame the row appears. `DiskImageCache.image(for:)` has done this for its own path for
        // months and its comment says exactly why; this path was the one that never learned.
        //
        // Measured from his own log, 2026-08-30: media rows averaged 2.0ms and peaked at 8.3ms,
        // which is a whole frame at 120Hz. Text averaged 0.5ms. The picture rows were the only
        // thing in the chat that could drop a frame on its own.
        let img = raw.preparingForDisplay() ?? raw
        cache.setObject(img, forKey: id as NSString)
        return img
    }

    /// ⛔ WARM IT OFF THE MAIN THREAD, BEFORE THE ROW IS ASKED FOR. Both this cache and
    /// `BlurHash.decode`'s are filled on demand, inside the cell, while the finger is moving — so
    /// the FIRST appearance of every picture pays for its own placeholder in the frame it lands.
    /// The cache made the second appearance free and left the first one exactly as expensive.
    ///
    /// `NSCache` is thread-safe and `UIImage` decoding off the main thread is the ordinary way to do
    /// this, so warming is just calling the same function early, somewhere that is not a frame.
    static func warm(id: String, base64: String?) {
        guard let base64, !base64.isEmpty, cache.object(forKey: id as NSString) == nil else { return }
        _ = image(id: id, base64: base64)
    }
}

/// See `Message.storyMention`.
struct StoryMentionRef: Equatable, Codable, Hashable {
    let id: String
    let thumbUrl: String
}

struct Message: Identifiable, Equatable, Codable {
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
    /// ⛔ A STORY MENTION — owner 2026-10-16: posting a story whose caption @mentions somebody puts
    /// this message in the 1:1 chat with them, drawn as a centred card (`MessageRowModelBuilder`).
    /// The poster is `authorId`; the person mentioned is the chat's other member. Plain story id and
    /// thumbnail url, like a story reply's (`ReplyRef.storyThumbUrl`), which are not secrets.
    var storyMention: StoryMentionRef?
    /// ⛔ A CHAT STICKER — owner 2026-10-17. `type == "sticker"`. A built-in one names its pack and
    /// file and every phone draws its own copy; one I made (`stickerPack == "mine"`) is a transparent
    /// PNG in `imageUrl` + `enc`, sealed like a photo. Plain fields: which art, not what was said.
    var stickerPack: String? = nil
    var stickerId: String? = nil
    var stickerEmoji: String? = nil
    var stickerAnimated: Bool? = nil   // optional so an older chat cache (without it) still decodes
    var reactions: [String: String]   // uid -> decrypted emoji
    var mentions: [String] = []       // uids @-mentioned in this message (groups)
    var viewOnce: Bool = false        // view-once photo (standard): recipient can open it exactly once
    /// Sent while the recipient had the author blocked (written by the server's onNewMessage). It was
    /// never delivered, so it keeps ONE tick for good, even after an unblock moves the watermarks.
    var held: Bool = false
    var album: [AlbumItem] = []       // 2+ photos sent together = ONE album message (grid + one caption)
    /// PER-TILE ASPECTS, WRITTEN BEFORE THE TILES EXIST.
    ///
    /// An album message is written the instant Send is tapped, like every other media type, but its
    /// grid is SOLVED from each tile's aspect ratio — so a placeholder without them would lay out
    /// differently from the album that replaces it and the whole bubble would jump. These are read
    /// off the source images before anything is uploaded and cost no bytes worth counting.
    ///
    /// ⚠️ Deliberately NOT fake `album` entries. `AlbumItem` requires a url and real encryption
    /// metadata, and inventing those to hold a shape would put meaningless crypto fields in the
    /// database and make `isAlbum` true for a message with nothing behind it.
    var albumSizes: [[Double]] = []
    var localAlbum: [Data] = []       // optimistic album previews shown before upload
    var localAlbumIsVideo: [Bool] = [] // per optimistic item: is it a video? (→ play badge before upload)
    var createdAt: Date
    var sendState: MessageSendState? = nil  // set only on local optimistic messages
    var localImageData: Data? = nil         // optimistic local photo shown before upload
    var localAudioData: Data? = nil         // optimistic local voice note shown before upload
    var localFile: Bool = false             // optimistic file bubble shown before upload (no fileUrl yet)
    var width: Double? = nil                // image pixel size -> natural aspect ratio bubble
    var blurhash: String? = nil             // sealed BlurHash of the photo → instant blurred placeholder
    /// THE PICTURE THAT NEEDS NO DOWNLOAD. A ~40px JPEG of the photo (or of a video's poster frame),
    /// base64'd and sealed like the caption, riding INSIDE the message document. Under a kilobyte on
    /// the wire, and it is on screen the instant the bubble is, with no URL, no fetch and no policy
    /// to satisfy — owner, 2026-08-25: "when someone sends something I see nothing until it
    /// downloads, only loading". See `ChatService.inlineThumb`.
    var thumb: String? = nil
    var localMediaURL: String? = nil        // pending video/file payload persisted to tmp → retry can re-send the REAL bytes
    var height: Double? = nil
    var callerUid: String? = nil            // call record: who placed the call (viewer derives direction)
    var callOutcome: String? = nil          // answered | missed | ringing/ongoing (live row) | declined (legacy, renders missed)
    var callVideo: Bool = false             // placed as a video call (older records default to voice)
    /// A notice that exists only on this phone (`init(localNotice:)`): the pill's leading symbol.
    var localNoticeSymbol: String? = nil
    var callDuration: Int? = nil            // seconds (0 if not answered)
    /// A group chat's call record (server, at close; group call audit 2026-10-23): who was in it, and
    /// who it rang. Each viewer's own outcome comes from these (`GroupCallOutcome`). nil elsewhere.
    var callJoinedUids: [String]? = nil
    var callRungUids: [String]? = nil
    /// A disappearing-timer system notice carries the value it set (0 = turned off), so each phone
    /// can word the line for its own reader ("You set…" / "<name> set…") instead of showing the
    /// writer's baked-in sentence. nil on every other message, including older notices.
    var disappearSeconds: Int? = nil
    /// A "<name> asked to turn off Restricted chat" notice (2026-10-03). Tapping it lets the person
    /// it was asked of accept or decline, while the request on the chat is still pending.
    var isRestrictRequest = false
    /// A channel post's views (2026-10-28), counted by the server (functions-groups channelViews).
    var views: Int = 0
    /// A channel post's reactions as counts only (2026-10-29): who picked what is never on the post.
    var reactionCounts: [String: Int] = [:]
    var edited: Bool = false               // text was edited after sending
    /// Deleted for everyone. The document SURVIVES as a tombstone so both sides see that something
    /// was here and removed, the way the standard messengers do it, instead of a message silently
    /// vanishing and leaving the other person wondering what they missed. The content is stripped
    /// server-side and the media is deleted from Storage, so what remains is a few bytes of marker.
    var deleted: Bool = false
    /// ⛔ SENT BEFORE I WAS IN THE GROUP (owner 2026-10-20: a row of locks after joining an old
    /// end-to-end group). It was sealed only for the members of that moment, so it can never be read
    /// here; the chat leaves it out, as the big apps do with history from before you joined.
    var notForMe: Bool = false
    /// 2026-09-24 feature-audit (delete-message): set only when a group admin deleted someone else's
    /// message, so its author is not told "You deleted this message". Nil = the author did it.
    var deletedBy: String? = nil
    var forwarded: Bool = false             // passed along from another chat (bubble shows the tag)
    var pollClosed: Bool = false            // 2026-10-19: the poll's creator tapped Stop Poll
    /// THE MESSAGE EXISTS, THE PICTURE DOES NOT YET.
    ///
    /// A photo message is written the instant Send is tapped, carrying its blurhash and its size but
    /// no media, and the author attaches the media when the upload finishes. Before this, the
    /// message was not written at all until the upload had completely finished — so the person being
    /// sent a photo saw nothing whatsoever, no bubble and no progress, and then a picture.
    ///
    /// ⚠️ `isImage` deliberately stays FALSE while this is true. That property gates the media
    /// gallery, the profile grid and All Media, and a message with no URL answering yes there is the
    /// broken-tile bug the tombstone comment already warns about. The chat bubble asks
    /// `isPendingImage` instead; nothing else needs to know.
    var uploading: Bool = false
    var clientTs: Date? = nil               // sender's tap time (ms epoch on the wire) — display order is send order
    /// WHEN THE DISAPPEARING TIMER TAKES THIS MESSAGE, or nil for a chat with no timer and for every
    /// message sent before the timer was made real (2026-08-21).
    ///
    /// ⛔ IT IS THE SERVER'S FIELD AND ONLY THE SERVER'S. `onNewMessage` writes it from the
    /// conversation's `disappearSeconds` the moment the message lands, `cleanupExpiringMessages`
    /// deletes on it, and the rules refuse it from any client at create and from every update
    /// branch. So it is fixed at send time: changing the chat's timer afterwards does not move a
    /// message that is already here, in either direction.
    ///
    /// The app reads it to hide a message the instant it is due rather than waiting up to five
    /// minutes for the sweep. The DELETING is the server's; this is only the drawing.
    var expiresAt: Date? = nil

    var isImage: Bool { (type == "image" && (imageUrl?.isEmpty == false)) || (localImageData != nil && type != "video" && type != "sticker") }
    /// A sticker (see `stickerPack`). A pending one I made carries its PNG in `localImageData`,
    /// which is why `isImage` above leaves "sticker" out: it is never a photo for the gallery.
    var isSticker: Bool { type == "sticker" && stickerPack?.isEmpty == false && stickerId?.isEmpty == false }
    /// The shared model the sticker store and keyboard use.
    var sticker: Sticker? {
        guard isSticker, let pack = stickerPack, let sid = stickerId else { return nil }
        return Sticker(source: pack == "mine" ? .mine : .bundled, packId: pack, stickerId: sid,
                       emoji: stickerEmoji ?? "", animated: stickerAnimated ?? false)
    }
    /// ⚠️ THE THIRD CLAUSE IS FOR A FAILED NOTE THAT OUTLIVED THE APP. A pending voice message keeps
    /// `type == "audio"` across a restart but has no `audioUrl` (it never uploaded) and no
    /// `localAudioData` (bytes are not written to the cache) — so both of the first two clauses were
    /// false and the bubble stopped identifying as audio at all. Its retry branch never matched and
    /// the button did nothing. The parked file is the surviving proof that this is a voice note.
    var isAudio: Bool {
        (type == "audio" && (audioUrl?.isEmpty == false))
            || localAudioData != nil
            || (type == "audio" && localMediaURL != nil)
    }
    // Optimistic videos carry their thumbnail in localImageData (hence the isImage carve-out).
    var isVideo: Bool { type == "video" && (videoUrl?.isEmpty == false || localImageData != nil) }
    var isFile: Bool { type == "file" && (fileUrl?.isEmpty == false || localFile) }
    var isGif: Bool { type == "gif" && (imageUrl?.isEmpty == false) }   // public Giphy url (not E2EE)
    var isAlbum: Bool { type == "album" && (!album.isEmpty || !localAlbum.isEmpty) }
    /// WHAT TO DRAW BEFORE THE REAL BYTES EXIST, and every media bubble asks this one question
    /// rather than each deciding for itself.
    ///
    /// The inline thumbnail wins when there is one: it is a real picture of the actual photo, and it
    /// is already in this message. The blurhash is the fallback for everything sent before the
    /// thumbnail existed, and for anything whose thumbnail did not unseal. Nil means neither, and a
    /// plain fill is then the honest placeholder (a view-once photo publishes no preview at all, on
    /// purpose).
    var previewImage: UIImage? {
        InlineThumbCache.image(id: rowId, base64: thumb) ?? blurhash.flatMap { BlurHash.decode($0) }
    }

    /// A photo whose bytes have not landed yet: draw the preview at the real aspect ratio, with a
    /// spinner. Only ever true on the RECEIVING side — the sender keeps showing their own local copy
    /// until the upload completes (see ThreadRepository.refreshItems).
    var isPendingImage: Bool { pendingMediaKind == "image" }

    /// THE MESSAGE EXISTS, THE BYTES DO NOT — which kind of placeholder to draw, or nil.
    ///
    /// Every media send writes its message the instant Send is tapped and attaches the media when
    /// the upload finishes, so there is a window where a real message has no URL. The bubble needs
    /// to know which shape to hold during it.
    ///
    /// ⚠️ Nil whenever local bytes are present, which is what keeps the SENDER out of here: their
    /// optimistic bubble is the better picture and stays until the upload lands.
    ///
    /// ⚠️ And nil once the URL arrives, so this cannot outlive the upload even if the flag somehow
    /// did. The URL is the fact; `uploading` is only the hint.
    /// `uploading`, but not forever (2026-10-04 audit). A sender whose app was killed or lost the
    /// network between the first write and the media write leaves `uploading: true` with nothing
    /// to finish it, and every reader drew a spinning ring over the blur for good. Past 30 minutes
    /// (room for a big album on a slow line) the ring stops; the blur stays, which is the truth.
    var uploadingLive: Bool {
        uploading && Date().timeIntervalSince(createdAt) < 30 * 60
    }

    var pendingMediaKind: String? {
        guard uploading, localImageData == nil, localAudioData == nil, !localFile else { return nil }
        switch type {
        case "image": return (imageUrl?.isEmpty ?? true) ? "image" : nil
        case "audio": return (audioUrl?.isEmpty ?? true) ? "audio" : nil
        case "video": return (videoUrl?.isEmpty ?? true) ? "video" : nil
        case "file":  return (fileUrl?.isEmpty  ?? true) ? "file"  : nil
        case "album": return album.isEmpty ? "album" : nil
        default:      return nil
        }
    }
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
        m.width = nil; m.height = nil; m.blurhash = nil; m.thumb = nil
        m.album = []; m.localAlbum = []; m.localAlbumIsVideo = []
        m.linkPreview = nil
        m.stickerPack = nil; m.stickerId = nil; m.stickerEmoji = nil; m.stickerAnimated = nil
        m.replyTo = nil
        m.reactions = [:]
        m.mentions = []
        m.viewOnce = false
        m.forwarded = false
        m.localImageData = nil; m.localAudioData = nil; m.localFile = false; m.localMediaURL = nil
        return m
    }

    /// A link preview that TRAVELLED WITH THE MESSAGE (the reference app's model): the sender fetched it, sealed
    /// it, and the recipient renders it without ever contacting the site. All text fields arrive
    /// decrypted here; the image is an encrypted storage blob exactly like a photo's.
    struct LinkPreviewData: Equatable, Codable {
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

    /// Did the SERVER actually stamp this, or is `createdAt` the local stand-in?
    ///
    /// Firestore hands back an unresolved `serverTimestamp()` as nil while a write is still in flight,
    /// and the initialiser below falls back to `Date()` so nothing is ever undated. Which means
    /// `createdAt` is sometimes the server's clock and sometimes this phone's, with nothing to tell them
    /// apart — and the clock-offset measurement in `ThreadRepository.assignOrderKeys` would be poisoned by rows
    /// whose "server time" is really local. This flag is that difference, and it is why the measurement
    /// can be trusted.
    var hasServerTime = false

    /// ⚠️ `sortAt` USED TO LIVE HERE AND IT IS DELIBERATELY GONE. It returned the sender's tap time
    /// whenever that was within an hour of the server's, which meant the conversation was ordered by
    /// comparing one phone's clock against another's — his report of his own bubble drawing above a
    /// friend's message that was genuinely sent first. Two phones a few seconds apart is all it takes,
    /// and the hour-wide guard only ever caught clocks that were wildly wrong.
    ///
    /// Ordering now belongs to `ThreadRepository`, because it cannot be decided by one message on its
    /// own: it needs every message by that author to work out that author's clock error first. Read the
    /// note above `ThreadRepository.assignOrderKeys`.

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

    /// Local optimistic STICKER (2026-10-17). A built-in one draws from the pack at once; one I made
    /// carries its PNG in `localImageData` until the encrypted upload lands.
    init(localSticker s: Sticker, png: Data?, width: Double, height: Double,
         authorId: String, clientId: String, sendState: MessageSendState) {
        self.id = clientId
        self.authorId = authorId
        self.text = ""
        self.type = "sticker"
        self.clientId = clientId
        self.reactions = [:]
        self.createdAt = Date()
        self.sendState = sendState
        self.stickerPack = s.packId
        self.stickerId = s.stickerId
        self.stickerEmoji = s.emoji
        self.stickerAnimated = s.animated
        self.localImageData = png
        self.width = width
        self.height = height
    }

    /// Local optimistic message shown instantly before the server confirms it.
    /// `id` = clientId until the server echo (matched by clientId) replaces it.
    /// A centred notice that is never written anywhere and never leaves this phone — "You blocked
    /// this person." and its unblock twin (owner, 2026-09-28: "show only me, don't show the user I
    /// blocked"). A system row with no author, so every rule that skips system rows (menus, reply,
    /// forward, search counts, voice queue) skips it too.
    init(localNotice text: String, symbol: String, id: String, at: Date) {
        self.id = id
        self.authorId = ""
        self.text = text
        self.type = "system"
        self.reactions = [:]
        self.createdAt = at
        self.localNoticeSymbol = symbol
    }

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
    struct AlbumItem: Equatable, Codable {
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

    /// WHAT SURVIVES BEING WRITTEN DOWN, and what deliberately does not.
    ///
    /// `Codable` exists here for one reason: `ThreadMessageCache` keeps the last screen of a chat on
    /// disk so opening it after the app was killed paints the conversation instead of an empty
    /// wallpaper. Everything listed below is part of that picture.
    ///
    /// ⚠️ THE SEVEN THAT ARE MISSING ARE MISSING ON PURPOSE:
    ///
    /// `localImageData`, `localAudioData`, `localAlbum`, `localAlbumIsVideo`, `localFile` and
    /// `localMediaURL` are the RAW BYTES of something still being sent — a photo held in memory
    /// until the upload finishes. Writing those would put whole images into a cache meant to hold a
    /// screen of text, for messages that are by definition not finished.
    ///
    /// `sendState` is left out for a different reason: it is `.sending` or `.failed`, both of which
    /// describe a moment, not a message. Restored from disk it would draw a spinner on a message
    /// that was delivered hours ago and has nothing left to wait for. In-flight messages have their
    /// own home (`storePending`), which is where that state belongs.
    ///
    /// All seven carry defaults, so decoding without them is not a special case.
    enum CodingKeys: String, CodingKey {
        case id, authorId, text, type
        case imageUrl, audioUrl, videoUrl, thumbUrl, thumbEnc
        case fileUrl, fileName, fileSize, duration, waveform, enc
        case clientId, replyTo, storyMention, reactions, mentions, viewOnce, album
        case createdAt, width, blurhash, thumb, height
        case callerUid, callOutcome, callVideo, callDuration, callJoinedUids, callRungUids
        case edited, deleted, deletedBy, forwarded, clientTs, linkPreview, hasServerTime, uploading, albumSizes
        case expiresAt   // owner audit 2026-10-06 chat #21: a cold open must know what has already expired
        case stickerPack, stickerId, stickerEmoji, stickerAnimated   // 2026-10-17 chat stickers, all optional
        // ⚠️ THE PATH TO A PENDING SEND'S OWN BYTES, and it has to persist or a failed voice note
        // comes back after a restart as a bubble with nothing in it and a retry button that quietly
        // does nothing. The BYTES are not encoded (localAudioData/localImageData stay out on
        // purpose — a cache file is no place for megabytes); the path is, and the file it points at
        // lives in Application Support. See AudioRecorder.parkInFlight.
        case localMediaURL
    }

    init(id: String, data: [String: Any], cid: String, crypto: Crypto) {
        self.id = id
        self.authorId = data["authorId"] as? String ?? ""
        // Keys a member released to this group for its old sealed items (owner 2026-10-23, server-
        // written `rk`). Taken FIRST, so every decrypt below can use them. Groups only (Crypto).
        let freshKeys = crypto.noteReleased(cid: cid, rk: data["rk"])
        let rawText = data["text"] as? String ?? ""
        let decrypted = crypto.decrypt(rawText, cid: cid, authorId: data["authorId"] as? String ?? "")
        // 1:1 hardening (owner 2026-10-23): a person's message in a 1:1 is always sealed ("enc1:").
        // One stored in the clear was shown as if it were end-to-end encrypted; it is not shown as
        // such any more. System and call lines are plain on purpose and keep their text.
        let personTypes: Set<String> = ["text", "image", "video", "audio", "file", "album", "gif"]
        if cid.contains("_"), !rawText.isEmpty, !rawText.hasPrefix("enc1:"), !rawText.hasPrefix("enc:"),
           personTypes.contains(data["type"] as? String ?? "text") {
            self.text = "This message wasn't encrypted and can't be shown."
        } else {
            self.text = decrypted
        }
        self.notForMe = crypto.groupEnvelopeSkipsMe(data["text"] as? String ?? "", cid: cid)
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
        // Sealed the same way, read the same way, and the same sentinels mean the same thing: an
        // unreadable one is no thumbnail rather than a broken image.
        if let th = data["thumb"] as? String, !th.isEmpty {
            let clear = crypto.decrypt(th, cid: cid, authorId: data["authorId"] as? String ?? "")
            self.thumb = (clear.isEmpty || clear == "…" || clear == "🔒") ? nil : clear
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
        self.callJoinedUids = data["joinedUids"] as? [String]
        self.callRungUids = data["rungUids"] as? [String]
        self.disappearSeconds = (data["disappearSeconds"] as? NSNumber)?.intValue
        self.isRestrictRequest = data["restrictRequest"] as? Bool ?? false
        self.edited = data["edited"] as? Bool ?? false
        self.views = max(0, (data["views"] as? NSNumber)?.intValue ?? 0)
        self.reactionCounts = ((data["reactionCounts"] as? [String: Any]) ?? [:])
            .compactMapValues { ($0 as? NSNumber)?.intValue }.filter { $0.value > 0 }
        self.deleted = data["deleted"] as? Bool ?? false
        self.deletedBy = data["deletedBy"] as? String   // 2026-09-24 feature-audit
        self.forwarded = data["forwarded"] as? Bool ?? false
        self.pollClosed = data["pollClosed"] as? Bool ?? false
        self.uploading = data["uploading"] as? Bool ?? false
        self.albumSizes = (data["albumSizes"] as? [[Double]]) ?? []
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
        self.held = data["held"] as? Bool ?? false
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
        // ⛔ A ONE-ITEM ALBUM IS THE PHOTO OR VIDEO IT HOLDS — owner, 2026-08-28 and again
        // 2026-09-26: send two, cancel one, and the survivor drew beside a BLANK tile, because the
        // mosaic is built for two and up and a lone tile leaves its partner empty. The sender used
        // to rewrite the document into a photo and the rules refused that write (see
        // `ChatService.sendAlbum`); the mixed-album path never tried. Read here instead, once, for
        // every send path and every phone: the fields the readers already consult become the
        // item's own, `isAlbum` turns false, and the message is a plain picture from here on. An
        // album still uploading is left alone — its tiles are not in yet.
        if type == "album", album.count == 1, !uploading, let only = album.first {
            album = []
            albumSizes = []
            if only.isVideo, let clip = only.videoUrl, let clipEnc = only.videoEnc {
                type = "video"
                videoUrl = clip
                enc = clipEnc            // a video's `enc` is the clip's key; the poster has its own
                thumbUrl = only.imageUrl
                thumbEnc = only.enc
                if only.duration > 0 { duration = only.duration }
            } else {
                type = "image"
                imageUrl = only.imageUrl
                enc = only.enc
            }
            width = only.width
            height = only.height
        }
        if type == "sticker" {
            stickerPack = data["stickerPack"] as? String
            stickerId = data["stickerId"] as? String
            stickerEmoji = data["emoji"] as? String
            stickerAnimated = data["animated"] as? Bool
            // The sealed `text` is only what an OLDER build shows instead (StickerSend), never a
            // caption: dropped here so Copy, Edit, search and previews never see it.
            text = ""
        }
        if let m = data["storyMention"] as? [String: Any], let sid = m["id"] as? String, !sid.isEmpty {
            self.storyMention = StoryMentionRef(id: sid, thumbUrl: m["thumb"] as? String ?? "")
        }
        if let r = data["replyTo"] as? [String: Any] {
            self.replyTo = ReplyRef(
                id: r["id"] as? String ?? "",
                authorId: r["authorId"] as? String ?? "",
                // The reply snippet was sealed by the ENCLOSING message's sender, so decrypt
                // with that author (group). 1:1 ignores authorId (symmetric cid-pair key).
                text: crypto.decrypt(r["text"] as? String ?? "", cid: cid, authorId: data["authorId"] as? String ?? ""),
                isStatus: r["isStatus"] as? Bool ?? false,
                storyThumbUrl: r["storyThumb"] as? String,   // plaintext story URL, no decrypt
                isReaction: r["isReaction"] as? Bool
            )
        }
        if let ts = data["createdAt"] as? Timestamp {
            self.createdAt = ts.dateValue()
            self.hasServerTime = true
        } else {
            // Still in flight. Dated with this phone's clock so nothing is ever undated, and flagged so
            // the ordering knows this is not the server speaking.
            self.createdAt = Date()
        }
        // Written by the server, never by us — see the property's own note.
        if let ts = data["expiresAt"] as? Timestamp { self.expiresAt = ts.dateValue() }
        if let ms = (data["clientTs"] as? NSNumber)?.doubleValue {
            self.clientTs = Date(timeIntervalSince1970: ms / 1000)
        }
        // A released key just arrived for one of this message's files: a photo or clip marked
        // "sent before you joined" can open now, so its permanent failure is lifted.
        if !freshKeys.isEmpty {
            var media: [(url: String, enc: EncMeta?, itemId: String)] = [
                (imageUrl ?? "", enc, id), (videoUrl ?? "", enc, id), (audioUrl ?? "", enc, id),
                (fileUrl ?? "", enc, id), (thumbUrl ?? "", thumbEnc, id),
                (linkPreview?.imageUrl ?? "", linkPreview?.imageEnc, id),
            ]
            for (i, it) in album.enumerated() {
                media.append((it.imageUrl, it.enc, "\(id)-\(i)"))
                if let v = it.videoUrl { media.append((v, it.videoEnc, "\(id)-\(i)")) }
            }
            let hits: [[String]] = media.compactMap { m in
                guard !m.url.isEmpty, let n = m.enc?.n, let d = Crypto.looseBase64(n),
                      freshKeys.contains(d) else { return nil }
                return [m.url, m.itemId]
            }
            if !hits.isEmpty {
                Task { @MainActor in
                    for h in hits { MediaDownloads.shared.clearUnreadable(h[0], itemId: h[1]) }
                }
            }
        }
    }
}

/// ⛔ ROLE — owner 2026-10-18. A member's tag in one group: a few words and, if wanted, one emoji
/// in front. The second reference app's limits (MemberLabelViewController.swift:89, 24 glyphs; :479,
/// never an emoji alone). Stored at `roles.{uid}` = {text, emoji?}; firestore.rules checks the shape.
struct GroupRole: Equatable, Hashable {
    var text: String
    var emoji: String?
    /// One of `GroupRole.colors` (owner 2026-10-20: "I can add a colour to a tag"), nil = plain grey.
    var color: String? = nil

    /// The eight tag colours, by the name the rules accept, in the order the editor shows them.
    static let colors: [(name: String, rgb: UInt)] = [
        ("grey", 0x8E8E93), ("blue", 0x2392FE), ("green", 0x22A55B), ("teal", 0x14B8A6),
        ("orange", 0xF59E0B), ("red", 0xEF4444), ("pink", 0xEC4899), ("purple", 0x8B5CF6),
    ]
    static func rgb(_ name: String?) -> UInt? {
        guard let name, name != "grey" else { return nil }
        return colors.first { $0.name == name }?.rgb
    }

    /// The longest text. Counted in UTF-16 units, which is never fewer than the characters the
    /// rules' `size()` counts, so what the editor lets through the server lets through too.
    static let maxText = 24
    /// An emoji is one character to the eye but may be several underneath (a flag, a skin tone, a
    /// family): room for the longest common ones.
    static let maxEmoji = 16

    init(text: String, emoji: String?, color: String? = nil) {
        self.text = text
        self.emoji = (emoji?.isEmpty ?? true) ? nil : emoji
        self.color = GroupRole.rgb(color) == nil ? nil : color
    }

    /// From the stored map. Anything without words is no role.
    init?(_ raw: Any) {
        guard let m = raw as? [String: Any], let t = m["text"] as? String, !t.isEmpty else { return nil }
        self.init(text: t, emoji: m["emoji"] as? String, color: m["color"] as? String)
    }

    /// "🎨 Designer", or just "Designer".
    var display: String { emoji.map { "\($0) \(text)" } ?? text }

    /// Clean text as it will be saved: one line, runs of spaces made one, trimmed, cut to the limit.
    static func clean(_ raw: String) -> String {
        let one = raw.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        return fit(one, max: maxText)
    }

    /// The longest prefix, whole characters only, that stays within `max` UTF-16 units.
    static func fit(_ s: String, max: Int) -> String {
        var out = ""
        for ch in s {
            if out.utf16.count + String(ch).utf16.count > max { break }
            out.append(ch)
        }
        return out
    }
}

/// 2026-10-18 group moderation: the group's `mod` map, written only by Fariin's admin panel
/// (functions-admin groupModSet / groupDisable). The ladder: a Scam / Fake `label`, then `limited`
/// (nobody new joins), `suspended` (nobody sends, joins, invites or edits; timed or until lifted),
/// `disabled` (the same, for good). The rules enforce every step; this only decides what to show.
/// A suspension whose `until` has passed reads as lifted, as the rules read it.
struct GroupMod: Equatable, Hashable {
    var state: String = "ok"
    var reason: String = ""
    var label: String = ""        // "", "scam" or "fake"
    var untilMillis: Double = 0   // 0 = no end date (only meaningful while suspended)
    var notice: String = ""       // the short public text members see

    init(data: [String: Any]?) {
        guard let d = data else { return }
        let s = d["state"] as? String ?? "ok"
        state = ["ok", "limited", "suspended", "disabled"].contains(s) ? s : "ok"
        reason = d["reason"] as? String ?? ""
        let l = d["label"] as? String ?? ""
        label = ["scam", "fake"].contains(l) ? l : ""
        untilMillis = ((d["until"] as? Timestamp)?.dateValue().timeIntervalSince1970 ?? 0) * 1000
        notice = String((d["notice"] as? String ?? "").prefix(200))
    }

    /// ⛔ UNAVAILABLE (owner 2026-10-26, the reference app's blocked group): suspended and not yet
    /// over, or disabled, by Fariin. Nothing to read, send, call, edit or add; only Leave. A group its
    /// owner ended is NOT this (its history stays).
    func locksGroup(now: Date = Date()) -> Bool {
        if state == "disabled" { return true }
        guard state == "suspended" else { return false }
        return untilMillis <= 0 || untilMillis > now.timeIntervalSince1970 * 1000
    }

    /// Nobody may send here right now (suspended and not yet over, disabled, or ended by its owner).
    func blocksSending(now: Date = Date()) -> Bool {
        if state == "disabled" || state == "ended" { return true }
        guard state == "suspended" else { return false }
        return untilMillis <= 0 || untilMillis > now.timeIntervalSince1970 * 1000
    }

    /// Nobody new comes in (audit 2026-10-26 item 5): `limited`, or closed as `blocksSending` reads it.
    /// The rules refuse a member add for each (firestore.rules, the group mod ladder).
    func takesNoNewMembers(now: Date = Date()) -> Bool { state == "limited" || blocksSending(now: now) }

    /// The sentence in place of the message bar. The server's own notice when it wrote one, else
    /// a plain line from the reason, with the end date of a timed suspension.
    var noticeText: String {
        if state == "ended" { return "This group has ended." }
        var text = notice
        if text.isEmpty {
            let why: String
            switch reason {
            case "spam": why = "spam"
            case "scam": why = "scams or fraud"
            case "copyright": why = "copyright complaints"
            case "fake": why = "impersonation"
            case "abuse": why = "abuse or violence"
            case "adult": why = "adult content"
            case "illegal": why = "illegal content"
            default: why = "breaking the Fariin rules"
            }
            text = state == "disabled" ? "This group was closed for \(why)." : "This group is suspended for \(why)."
        }
        if state == "suspended", untilMillis > 0 {
            let until = Date(timeIntervalSince1970: untilMillis / 1000)
            text += " Until " + until.formatted(date: .abbreviated, time: .shortened) + "."
        }
        return text
    }
}

/// ⛔ EVERY CHANNEL THIS DEVICE HAS SEEN, NOT ONLY THE CHAT LIST'S (owner 2026-10-29 audit U1).
/// `Conversation.Right.isChannel(cid)` looked only in the chat list, so a visitor, or someone who
/// had just unfollowed, got group words on a channel ("This group is unavailable"). Each decoder
/// that reads `channel: true` notes the id here. A channel never turns back into a group, so ids
/// are only added. Locked because conversation docs are decoded off the main thread too.
/// My own follow (+1) or leave (−1) on a channel, shown until the channel's `followerCount` moves
/// (the server batches it once a minute). Keyed by channel, with the count it was made against:
/// once the count is anything else, the server has it and the bias is dropped. Any thread.
/// Bumped whenever my follow or unfollow changes a channel's shown count, so every page that reads
/// the count redraws at once: the count itself lives in a lock-guarded dictionary nothing observes
/// (owner 2026-10-30: the header kept the old number until something else happened to redraw it).
@Observable final class ChannelCountTick {
    static let shared = ChannelCountTick()
    var n = 0
    static func bump() { DispatchQueue.main.async { shared.n &+= 1 } }
}

enum ChannelCountBias {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var bias: [String: (base: Int?, delta: Int)] = [:]   // guarded by `lock`

    /// ⛔ MY CHANGES ADD UP UNTIL THE SERVER'S NUMBER MOVES (owner 2026-10-30: follow, unfollow,
    /// follow again inside a minute and the channel said 2 where 3 was right). It kept only the LAST
    /// change, and a follow made from the search page, where the channel's live count is not known
    /// yet, kept nothing at all. Now the changes against one stored count are summed (one person, so
    /// -1...+1), and a change made before the count is known takes the count it first sees as base.
    static func note(_ cid: String, base: Int?, delta: Int) {
        guard !cid.isEmpty else { return }
        lock.withLock {
            if let b = bias[cid], base == nil || b.base == nil || b.base == base {
                bias[cid] = (b.base ?? base, max(-1, min(1, b.delta + delta)))
            } else {
                bias[cid] = (base, delta)
            }
        }
        ChannelCountTick.bump()
    }

    /// The server's own word, from its answer to my follow or unfollow: the stored count and what the
    /// count buffer will add to it (mine included). Replaces any guess, so it never depends on which
    /// copy of the channel this phone happened to see first (owner 2026-10-30).
    static func set(_ cid: String, stored: Int, pending: Int) {
        guard !cid.isEmpty else { return }
        lock.withLock { bias[cid] = (stored, pending) }
        ChannelCountTick.bump()
    }

    /// The followers to show: the stored count, plus my change while the count is still the old one.
    static func adjusted(_ cid: String, _ count: Int) -> Int {
        lock.withLock {
            guard let b = bias[cid] else { return count }
            guard let base = b.base else {
                bias[cid] = (count, b.delta)   // first sight of the count since my change: that is the base
                return max(0, count + b.delta)
            }
            if base == count { return max(0, count + b.delta) }
            bias[cid] = nil   // the batch landed: the server's number has it
            return count
        }
    }
}

enum KnownChannels {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var ids: Set<String> = []   // guarded by `lock`
    static func note(_ id: String) {
        guard !id.isEmpty else { return }
        lock.withLock { _ = ids.insert(id) }
    }
    static func contains(_ id: String) -> Bool { lock.withLock { ids.contains(id) } }
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
    /// An album's first photos (up to 3) for the list's overlapped stack (owner, 2026-10-04).
    /// Belongs to the current summary only while its first entry is `lastImageUrl`.
    var lastImages: [ListThumb] = []
    struct ListThumb: Hashable { let url: String; let enc: EncMeta }
    var lastSender: String            // uid of who sent the last message ("" if unknown)
    var unreadCount: [String: Int]
    var typing: [String: Bool]
    /// Seconds since 1970 each person's typing/recording flag was last refreshed (when known).
    var typingAt: [String: Double] = [:]
    /// Is `uid`'s typing or recording flag recent? Senders refresh it every few seconds while it
    /// is on, so one older than 25 s was left behind (an app killed, an account signed out).
    func activityFresh(_ uid: String) -> Bool {
        guard let at = typingAt[uid], at > 0 else { return true }   // an older build: the 15 s row clock decides
        return Date().timeIntervalSince1970 - at < 25
    }
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
    // ⚠️ 2026-09-26: THE OLD, SHARED COPY OF A BLOCK, read only until `BlockList.migrate` moves it
    // to the owner's private list and deletes it here. Nothing writes these any more. Ask
    // `isBlockedByMe` / `BlockList`, never these maps directly.
    var blockedBy: [String: Bool]
    var blockedAt: [String: Double]    // when each user blocked (ms) — hides later messages
    var blockClearedAt: [String: Double] = [:]   // when each user unblocked (ms)
    var pinOrder: [String: Double]     // per-user manual order for pinned chats
    /// uid → the createdAt (ms) of the NEWEST voice note that person has played. A watermark, not a
    /// per-message flag, for the same reason `lastRead` is one: one small field on a document the chat
    /// already listens to, instead of a write against every message. See `voicePlayedByOther`.
    var lastPlayedVoice: [String: Double]
    /// 2026-09-25 delivered ticks: per member, the `updatedAt` (ms) their phone confirmed it had.
    var delivered: [String: Double]
    /// The newest message was held by a block on the recipient's side (server-written). Its sender
    /// keeps one tick in the list, whatever `delivered` / `unreadCount` say after an unblock.
    var lastHeld: Bool
    /// 2026-09-24 decision D13: Mark as Unread is its own per-user flag, not a sign on `unreadCount`.
    /// uid → true while that member has marked the chat unread by hand; cleared when they open it.
    var markedUnread: [String: Bool]
    var pinnedMessageId: String        // a pinned message in this chat ("" = none)
    var disappearSeconds: Int          // auto-delete timer (0 = off), shared by both members
    /// When the newest message falls due on the timer (server-written beside `expiresAt` on the
    /// message, 2026-10-07). The chat list burns a CLOSED chat on it; see ConversationsRepository.
    var lastExpiresAt: Date? = nil
    /// Restricted chat (owner, 2026-10-03). Shared by both members, like the timer: either may set
    /// them and they bind both. See `ChatRestrictions`.
    var noScreenshots = false
    var noForwarding = false
    var noSaving = false
    /// uid → true for each person who has switched Restricted Chat on for this chat.
    var restrictedBy: [String: Bool] = [:]
    /// A pending request to turn it off (the reference app's consent step): who asked, and when.
    var restrictRequestBy: String?
    var restrictRequestAt: Date?
    var convType: String              // "group" = group chat; "" / "direct" = 1:1
    var title: String                  // group name (groups only)
    var groupDescription: String       // group description / "about" (groups only)
    var avatarUrl: String?             // group photo (groups only)
    var admins: [String]               // uids allowed to manage the group
    var createdBy: String              // uid of the group creator (owner)
    var createdAt: Date?               // when the group was created
    var onlyAdminsSend: Bool           // announcement mode: only admins may send (groups)
    var membersCanAdd: Bool            // group: non-admins may add members (default false)
    var membersCanEditInfo: Bool       // group: non-admins may edit name/photo/desc (default false)
    var onlyAdminsCall = false         // group: only admins may START a call (joining stays open)
    /// owner 2026-10-27 (the founder): the group's profile hides its members, count, admins and
    /// Owner label from everyone but Fariin staff. Set only by staff (functions-groups
    /// setGroupHideMembers; the rules keep phones off it). Messages are unchanged.
    var hideMembers = false
    /// A channel (2026-10-28): a group with a hat. Set once by the server (functions-groups
    /// makeChannel), never by a phone. Admins are in `users`; followers are NOT (they live in
    /// conversations/{cid}/followers, mirrored in users/{me}/channels for my list).
    var isChannel = false
    var followerCount = 0
    /// Posts so far (server, onNewMessage). A follower's unread is this minus `followerRead`.
    var postCount = 0
    /// Mine as a follower, from users/{me}/channels/{cid} (ChannelFollows), nil when I am not one.
    var followerRead: Int?
    var followerMuted = false
    /// When that mute ends (ms), 0 = always (audit E7: the list asks the clock, not a copy).
    var followerMutedUntil: Double = 0
    var followerPinned = false
    var followerArchived = false
    /// When I followed this channel, ms (`ChannelFollows`, from my follow entry's `at`); 0 otherwise.
    var followedAtMillis: Double = 0
    /// Admins' names under their posts (Channel Settings > Sign Posts).
    var signPosts = false
    /// A channel's reactions (2026-10-29): "all", "some" (only `reactList`, up to 6) or "off".
    var reactMode = "all"
    var reactList: [String] = []
    /// group: what members may send (2026-10-20), `memberSend` {photos, videos, voice, files,
    /// stickers, gifs, links, polls, location}; a missing key = allowed. firestore.rules
    /// `memberSendOk` enforces it.
    var memberSend: [String: Bool] = [:]
    /// group: seconds a member waits between messages (2026-10-20), 0 = off. Admins never wait.
    var slowModeSeconds: Int = 0
    /// ⛔ CHAT HISTORY FOR NEW MEMBERS (owner 2026-10-20): when it was set to Hidden (ms, 0 = Visible).
    /// Someone who joins after that sees the chat from the moment they came in, like a new group.
    var hideHistoryAt: Double = 0
    /// When each member came in (ms), written by the server (functions-groups stampMemberSince).
    var memberSince: [String: Double] = [:]

    /// Where `uid`'s chat starts: their join time when they came in after history was hidden,
    /// nil (everything) otherwise, including for anyone who joined before it was hidden.
    func historyStart(for uid: String) -> Date? {
        guard isGroup, hideHistoryAt > 0, let since = memberSince[uid], since >= hideHistoryAt else { return nil }
        return Date(timeIntervalSince1970: since / 1000)
    }
    var membersCanShareLink = false    // group: non-admins see Share and the QR of the invite link (owner 2026-10-19)
    /// 2026-10-19 groups v2 (owner): the group's document says `e2ee == false`, so its new messages
    /// are NOT end-to-end encrypted (ChatService.groupIsPlain). Server-written; false for every 1:1.
    var e2eeOff = false
    /// 2026-10-19 groups v2: written beside a member's PLAIN text in such a group, `plainTag` of that
    /// `lastMessage`. A notice ("X added Y") is plain words too and does not write it, so the list can
    /// still tell "Ayaan: hello" from a notice: the tag matches only the text it was written with.
    var lastPlainTag: String?

    /// A short, stable fingerprint of a summary line (FNV-1a, 64 bits). Not a secret and not a
    /// security check, only "is this still the line the tag was written for".
    static func plainTag(_ s: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
        return String(h, radix: 16)
    }

    /// The newest line is a member's own words, sent in the clear in a group that switched.
    var lastIsPlainText: Bool {
        guard let t = lastPlainTag, !t.isEmpty, !lastMessageCipher.isEmpty else { return false }
        return t == Conversation.plainTag(lastMessageCipher)
    }
    /// ⛔ ROLE — owner 2026-10-18: uid → the short tag an ADMIN gives a member ("🎨 Designer"),
    /// shown beside their name in the group's bubbles, the members list and their card. Groups only.
    /// Replaces the self-set Member Label of the same day (`memberLabels`, never shipped).
    var roles: [String: GroupRole] = [:]
    /// owner 2026-10-18: the group's SHARED wallpaper (`ChatWallpaper.stored`, or "u:<download
    /// link>" for a photo). Set by whoever may change group info; beats each phone's own pick.
    /// nil = never set, so every phone keeps its own. Groups only; a 1:1 never carries it.
    var groupWallpaper: String? = nil
    /// 2026-10-19 groups v2: a PUBLIC group has an @name in the same namespace as people, so it can be
    /// found in global search and opened from fariin.com/<name>. Written only by the server
    /// (functions-username setGroupUsername); "" and false for a private group and every 1:1.
    var isPublic = false
    var publicName = ""
    // Per-flag admin rights (the reference app model): uid → granted right slugs. An admin with NO entry
    // has ALL rights (legacy behaviour); the owner (createdBy) always has all. See Conversation.Right.
    var inviteCode: String             // group's current primary invite-link code ("" = none)
    var adminRights: [String: [String]]
    // owner 2026-10-18: admin uid → the admin who promoted them. Only that admin (or the owner) may
    // change their rights or demote them. Missing = the owner's appointment (or from before this).
    var adminBy: [String: String] = [:]
    // Per-member restrictions (the reference app bannedRights): uid → restricted flags + an auto-expiring
    // `until` timestamp (ms). Empty flags or a past `until` = no restriction. See Conversation.Restrict.
    var restrictedFlags: [String: [String]]
    var restrictedUntil: [String: Double]
    var lastReactionEnc: String?       // sealed emoji of the newest reaction (list preview)
    /// Sealed words for the message that reaction was on ("Voice message", the start of a text),
    /// so the list can say what was reacted to. Nil on reactions from before 2026-09-26.
    var lastReactionToEnc: String?
    /// The pictures the reaction was on, up to three (owner, 2026-10-03). Empty for text, and for
    /// reactions written before this existed.
    var lastReactionToImages: [ReactionThumb] = []
    var lastReactionBy: String         // who reacted ("" = none)
    var lastReactionToAuthor: String   // author of the reacted-to message
    var lastReactionAtMillis: Double   // 0 = none; previewed only while newer than updatedAt
    var updatedAtMillis: Double
    // MESSAGE REQUESTS. `startedBy` is who opened this 1:1; `accepted` is whether the other person
    // has answered. A conversation with NO `startedBy` predates the request system and is accepted —
    // otherwise every chat anyone already has would turn into a pending request overnight, which is
    // the one thing this must never do. Groups never carry it.
    var startedBy: String
    var accepted: Bool
    /// HOW this conversation came to be accepted: "pin" when somebody opened it with the owner's
    /// Chat Key, empty for the ordinary route (a reply, or Accept on a request). Written by
    /// `verifyChatPin` and read only to tell the owner — see `ContactInfoView` (audit S4).
    var acceptedVia: String
    /// The uid of whoever typed the key, when `acceptedVia` is "pin". Empty otherwise.
    /// 2026-10-10: also stamped by the server (onRequestAccepted) for an ordinary Accept: the uid
    /// of the person who accepted the request.
    var acceptedBy: String
    /// 2026-10-10: when the request was accepted (server stamp, onRequestAccepted). 0 = unknown.
    var acceptedAtMillis: Double
    /// owner 2026-10-21: this 1:1's first message went while Message Requests were OFF for the
    /// person written to (set once, with that message, and only then; the rules check it). Such a
    /// chat stays an ordinary chat if the switch comes back on (`MessageRequests.stance`), though
    /// friendship still begins at Accept or a reply (`rawStance` ignores it).
    var reqOff: Bool = false
    /// owner 2026-10-21: who last used Remove Friend on this chat (`MessageRequests.unfriend`). Tells
    /// "I removed them and wait for their knock" apart from "they opened this and never wrote".
    var unfriendedBy: String = ""
    /// owner 2026-10-18: members whose account was deleted for good. Written only by the server's
    /// purge (kpurgeOne, functions-loginalert), which also renames them to "Deleted Account" in
    /// `names`. Empty during the 30-day grace period: only a finished deletion lands here.
    var deletedUsers: [String] = []
    /// owner 2026-10-18: people removed from the group (ChatService.removeGroupMember). They cannot
    /// rejoin by link while listed; Removed Users in Group Settings lets one back.
    var bannedUids: [String] = []
    /// 2026-10-18 group moderation: where Fariin's moderators have put the group (`mod`, written
    /// only by the admin panel; the rules refuse any phone's write). See `GroupMod`.
    var groupMod: GroupMod = GroupMod(data: nil)
    /// 2026-10-18: the group's verified badge (`verified`, admin panel only).
    var groupVerified: Bool = false
    /// The badge's type (`verifiedType`, admin panel, owner 2026-10-26): the person list, gold for
    /// Business / Organization. Nil on an older badge or a type this build does not know: plain blue.
    var groupVerifiedType: Verification.Kind?
    /// The badge as it is shown: verified and no Scam / Fake label.
    var showsGroupBadge: Bool { isGroup && groupVerified && groupMod.label.isEmpty }
    /// The admin panel hid Report on this group (owner 2026-10-26: Fariin's official groups).
    var groupNoReport: Bool = false
    /// Suspended or disabled by Fariin right now (see `GroupMod.locksGroup`).
    var fariinLocked: Bool { isGroup && groupMod.locksGroup() }

    /// The label for a member whose account is gone. Same words the server writes into `names`.
    static let deletedAccountName = "Deleted Account"
    func isDeletedAccount(_ uid: String) -> Bool { !uid.isEmpty && deletedUsers.contains(uid) }

    init(id: String, data: [String: Any]) {
        self.id = id
        self.users = data["users"] as? [String] ?? []
        self.names = data["names"] as? [String: String] ?? [:]
        self.photos = data["photos"] as? [String: String] ?? [:]
        self.posters = data["posters"] as? [String: String] ?? [:]
        self.lastMessageCipher = data["lastMessage"] as? String ?? ""
        self.lastImageUrl = data["lastImageUrl"] as? String
        self.lastImageEnc = (data["lastImageEnc"] as? [String: Any]).flatMap(EncMeta.init(map:))
        self.lastImages = (data["lastImages"] as? [[String: Any]] ?? []).prefix(3).compactMap { d in
            guard let u = d["imageUrl"] as? String,
                  let e = (d["enc"] as? [String: Any]).flatMap(EncMeta.init(map:)) else { return nil }
            return ListThumb(url: u, enc: e)
        }
        self.lastSender = data["lastSender"] as? String ?? ""
        self.unreadCount = intMap(data["unreadCount"])
        // Typing = Bool true (older builds) OR the "text-<seconds>" refresh string senders now write.
        self.typing = (data["typing"] as? [String: Any] ?? [:])
            .compactMapValues { ($0 as? Bool) == true || ($0 as? String)?.hasPrefix("text") == true ? true : nil }
        self.recording = (data["typing"] as? [String: Any] ?? [:])
            .compactMapValues { ($0 as? String)?.hasPrefix("audio") == true ? true : nil }
        // When each flag was last refreshed ("text-<seconds>" / "audio-<seconds>"); a Bool from an
        // older build has no time (0). See `activityFresh` (owner 2026-10-29, a flag left on by a
        // sign-out showed "typing…" for minutes).
        self.typingAt = (data["typing"] as? [String: Any] ?? [:]).compactMapValues { v -> Double? in
            guard let s = v as? String, let dash = s.firstIndex(of: "-") else { return nil }
            return Double(s[s.index(after: dash)...])
        }
        self.typingRawKey = (data["typing"] as? [String: Any] ?? [:])
            .map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ",")
        self.mutedBy = doubleMap(data["mutedBy"])
        self.pinnedBy = boolMap(data["pinnedBy"])
        self.archivedBy = boolMap(data["archivedBy"])
        self.clearedAt = doubleMap(data["clearedAt"])
        self.blockedBy = boolMap(data["blockedBy"])
        self.blockedAt = doubleMap(data["blockedAt"])
        self.blockClearedAt = doubleMap(data["blockClearedAt"])
        self.pinOrder = doubleMap(data["pinOrder"])
        self.lastPlayedVoice = doubleMap(data["lastPlayedVoice"])
        self.delivered = doubleMap(data["delivered"])
        self.lastHeld = data["lastHeld"] as? Bool ?? false
        self.markedUnread = boolMap(data["markedUnread"])   // 2026-09-24 decision D13
        self.pinnedMessageId = data["pinnedMessageId"] as? String ?? ""
        self.disappearSeconds = (data["disappearSeconds"] as? NSNumber)?.intValue ?? 0
        self.lastExpiresAt = (data["lastExpiresAt"] as? Timestamp)?.dateValue()
        // ⛔ EACH PERSON'S OWN SWITCH — owner, 2026-10-03, the reference app's private-chat rule:
        // `restrictedBy[uid]` is set by that person alone; the chat is restricted while ANYONE'S is
        // on. The three older fields (one shared switch, 2026-10-03 morning) still count until a
        // newer build clears them. See `ChatRestrictions`.
        self.restrictedBy = (data["restrictedBy"] as? [String: Any] ?? [:]).compactMapValues { $0 as? Bool }
            .filter { $0.value }
        let anyone = !self.restrictedBy.isEmpty
        self.noScreenshots = anyone || (data["noScreenshots"] as? Bool ?? false)
        self.noForwarding = anyone || (data["noForwarding"] as? Bool ?? false)
        self.noSaving = anyone || (data["noSaving"] as? Bool ?? false)
        let request = data["restrictRequest"] as? [String: Any]
        self.restrictRequestBy = request?["by"] as? String
        self.restrictRequestAt = (request?["at"] as? Timestamp)?.dateValue()
        self.convType = data["type"] as? String ?? ""
        self.title = data["title"] as? String ?? ""
        self.groupDescription = data["desc"] as? String ?? ""
        self.avatarUrl = data["avatarUrl"] as? String
        self.admins = data["admins"] as? [String] ?? []
        self.createdBy = data["createdBy"] as? String ?? ""
        self.createdAt = (data["createdAt"] as? Timestamp)?.dateValue()
        self.onlyAdminsSend = data["onlyAdminsSend"] as? Bool ?? false
        self.membersCanAdd = data["membersCanAdd"] as? Bool ?? false
        // ⛔ ADMINS ONLY, WHATEVER AN OLDER GROUP STORED (owner 2026-10-19): editing group info and
        // sharing the link have no member switch any more, so a group that had them on reads off.
        // Change group info is a member switch again (owner 2026-10-19, later); the link stays admins'.
        self.membersCanEditInfo = data["membersCanEditInfo"] as? Bool ?? false
        self.onlyAdminsCall = data["onlyAdminsCall"] as? Bool ?? false
        self.hideMembers = data["hideMembers"] as? Bool ?? false
        self.isChannel = data["channel"] as? Bool ?? false
        if self.isChannel { KnownChannels.note(id) }
        self.signPosts = data["signPosts"] as? Bool ?? false
        if let rs = data["reactSet"] as? [String: Any] {
            self.reactMode = (rs["mode"] as? String).flatMap { ["all", "some", "off"].contains($0) ? $0 : nil } ?? "all"
            self.reactList = (rs["list"] as? [String]) ?? []
        }
        self.followerCount = max(0, (data["followerCount"] as? NSNumber)?.intValue ?? 0)
        self.postCount = max(0, (data["postCount"] as? NSNumber)?.intValue ?? 0)
        self.memberSend = data["memberSend"] as? [String: Bool] ?? [:]
        self.slowModeSeconds = (data["slowMode"] as? NSNumber)?.intValue ?? 0
        func ms(_ v: Any?) -> Double {
            if let t = v as? Timestamp { return t.dateValue().timeIntervalSince1970 * 1000 }
            return (v as? NSNumber)?.doubleValue ?? 0
        }
        self.hideHistoryAt = ms(data["hideHistoryAt"])
        self.memberSince = (data["memberSince"] as? [String: Any] ?? [:]).mapValues { ms($0) }
        self.membersCanShareLink = false
        self.e2eeOff = (data["type"] as? String) == "group" && (data["e2ee"] as? Bool) == false
        self.lastPlainTag = data["lastPlainTag"] as? String
        // Released keys for the list's last line / reaction / thumbnails (owner 2026-10-23). Groups
        // only; Crypto ignores anything else. The worker that releases them hears of the group here.
        if self.e2eeOff {
            Crypto.shared.noteReleased(cid: id, rk: data["rk"])
            GroupKeyRelease.noteGroup(id)
        }
        self.roles = self.convType == "group"
            ? (data["roles"] as? [String: Any] ?? [:]).compactMapValues { GroupRole($0) }
            : [:]
        self.groupWallpaper = self.convType == "group" ? data["wallpaper"] as? String : nil
        let pubName = self.convType == "group" ? (data["username"] as? String ?? "") : ""
        self.isPublic = !pubName.isEmpty && (data["isPublic"] as? Bool ?? false)
        self.publicName = self.isPublic ? pubName : ""
        self.inviteCode = data["inviteCode"] as? String ?? ""
        self.adminRights = stringArrayMap(data["adminRights"])
        self.adminBy = (data["adminBy"] as? [String: Any] ?? [:]).compactMapValues { $0 as? String }
        self.startedBy = data["startedBy"] as? String ?? ""
        // Absent means "from before this existed" — accepted. Present means the flag decides.
        self.accepted = data["accepted"] as? Bool ?? (data["startedBy"] == nil)
        self.acceptedVia = data["acceptedVia"] as? String ?? ""
        self.acceptedBy = data["acceptedBy"] as? String ?? ""
        self.acceptedAtMillis = ((data["acceptedAt"] as? Timestamp)?.dateValue().timeIntervalSince1970 ?? 0) * 1000
        self.reqOff = data["reqOff"] as? Bool ?? false
        self.unfriendedBy = data["unfriendedBy"] as? String ?? ""
        self.deletedUsers = data["deletedUsers"] as? [String] ?? []
        self.bannedUids = data["bannedUids"] as? [String] ?? []
        self.groupMod = GroupMod(data: data["mod"] as? [String: Any])
        // ⛔ ENDED BY ITS OWNER (owner 2026-10-20, endGroup): closed for good, messages kept. Read as a
        // moderation state, so every place that already stops sending, calls and changes stops here too.
        if data["endedAt"] != nil, data["type"] as? String == "group" { self.groupMod.state = "ended" }
        // ⛔ Suspended or disabled by Fariin: no group photo either (owner 2026-10-26), the plain
        // group circle everywhere the app draws this group.
        if data["type"] as? String == "group", groupMod.locksGroup() { self.avatarUrl = nil }
        self.groupVerified = data["verified"] as? Bool ?? false
        self.groupVerifiedType = (data["verifiedType"] as? String).flatMap(Verification.Kind.init(rawValue:))
        self.groupNoReport = data["noReport"] as? Bool ?? false
        self.restrictedFlags = stringArrayMap(data["restrictedFlags"])
        self.restrictedUntil = doubleMap(data["restrictedUntil"])
        self.lastReactionEnc = data["lastReactionEnc"] as? String
        self.lastReactionToEnc = data["lastReactionToEnc"] as? String
        self.lastReactionToImages = (data["lastReactionToImages"] as? [[String: Any]] ?? []).prefix(3).compactMap { row in
            guard let url = row["url"] as? String, !url.isEmpty else { return nil }
            return ReactionThumb(url: url, enc: (row["enc"] as? [String: Any]).flatMap(EncMeta.init(map:)))
        }
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
        // owner 2026-10-18: a deleted account is "Deleted Account" even under a saved contact name,
        // the way the reference app shows one. Only after the purge, never during the grace period.
        if !isGroup, isDeletedAccount(other) { return Self.deletedAccountName }
        // 1:1 only: a locally-saved contact name overrides the profile name.
        if !isGroup, let custom = ContactNames.shared.name(for: other) { return custom }
        return names[other] ?? "User"
    }
    /// ⛔ THE NEWER OF TWO COPIES — owner, 2026-09-27: "some users I can see their photo, some I
    /// cannot, though they have one and hide nothing". `photos` is this chat's MIRROR of each
    /// member's photo, and only the photo's OWNER keeps it right (`ProfileStore.healMyMirrors`, from
    /// their own chat list, on a current build). Someone on an old build, or who rarely opens the
    /// app, stayed blank or stale in every chat forever. Their own profile record, whenever this
    /// phone has read it (`ProfilePhotoIndex`), is the authority: whichever of the two carries the
    /// newer `?v=` stamp wins, and an empty mirror never hides a known photo.
    func photoUrl(for me: String) -> String? {
        let other = otherUid(me)
        // owner 2026-10-18: no picture for a deleted account, not even one this phone remembers.
        if !isGroup, isDeletedAccount(other) { return nil }
        let mirror = photos[other].flatMap { $0.isEmpty ? nil : $0 }
        let known = ProfilePhotoIndex.facts(other)?.photo
        guard let known, !known.isEmpty else { return photos[other] }
        guard let mirror else { return known }
        return Self.photoStamp(known) > Self.photoStamp(mirror) ? known : mirror
    }

    /// The `v=` stamp a published photo url carries (milliseconds of the upload); 0 when absent.
    static func photoStamp(_ url: String) -> Double {
        guard let q = URLComponents(string: url)?.queryItems,
              let v = q.first(where: { $0.name == "v" })?.value else { return 0 }
        return Double(v) ?? 0
    }
    /// nil when they have never set a poster — the profile then draws the classic circle, which is
    /// also what everyone who last set a photo before this existed will get until they set a new one.
    func posterUrl(for me: String) -> String? {
        isDeletedAccount(otherUid(me)) ? nil : posters[otherUid(me)]   // owner 2026-10-18
    }

    // ── Group helpers ──
    var isGroup: Bool { convType == "group" }
    func isAdmin(_ me: String) -> Bool { admins.contains(me) }
    func isOwner(_ me: String) -> Bool { !createdBy.isEmpty && createdBy == me }

    // Per-flag admin rights (reference-style). Slugs kept small, mapped to what Fariin actually gates.
    // Delegatable admin rights. Managing the admin TEAM belongs to the owner; owner 2026-10-18: the
    // owner may hand part of it on with `addAdmins`, which lets that admin promote members with at
    // most their own rights and manage only the admins they promoted (`adminBy`). See canManageAdmin.
    enum Right: String, CaseIterable, Identifiable {
        // postStories (owner 2026-10-25): group stories are a right of each admin, set on their own
        // page, instead of one group-wide "Allow Admins to Add Story" switch.
        case changeInfo, deleteMessages, banUsers, inviteUsers, pinMessages, manageCalls, postStories, addAdmins
        var id: String { rawValue }
        var label: String {
            switch self {
            case .changeInfo:     return "Change group info"
            case .deleteMessages: return "Delete messages"
            case .banUsers:       return "Restrict / remove members"
            case .inviteUsers:    return "Add members"
            case .pinMessages:    return "Pin messages"
            case .manageCalls:    return "Manage video chats"
            case .postStories:    return "Post group stories"
            case .addAdmins:      return "Add new admins"
            }
        }
        /// What a new admin gets: everything but `addAdmins`. Also what a legacy admin (no entry) holds.
        static var defaults: [Right] { allCases.filter { $0 != .addAdmins } }
    }
    /// Can `uid` perform `right`? Owner → always. Admin with no adminRights entry → the defaults
    /// (legacy: every right they had before `addAdmins` existed). Admin with an entry → only the
    /// granted slugs. Non-admin → never.
    func adminCan(_ uid: String, _ right: Right) -> Bool {
        if isOwner(uid) { return true }
        guard admins.contains(uid) else { return false }
        guard let granted = adminRights[uid] else { return right != .addAdmins }   // legacy admin
        return granted.contains(right.rawValue)
    }
    /// The rights `uid` holds as an admin, as granted (legacy = the defaults; owner = all).
    func adminRightsOf(_ uid: String) -> [Right] {
        Right.allCases.filter { adminCan(uid, $0) }
    }
    /// ⛔ ROLE — owner 2026-10-18: may `me` give `target` a role? Only admins, never yourself as a
    /// member. The owner: anyone, admins and themselves included. An admin: needs Change group info,
    /// and never the owner's. The same test as firestore.rules `roleWriteOK`.
    func canSetRole(_ me: String, _ target: String) -> Bool {
        // No tags in a channel (owner 2026-10-29): followers never see who the admins are.
        guard isGroup, !isChannel, users.contains(target) else { return false }
        if isOwner(me) { return true }
        return adminCan(me, .changeInfo) && !isOwner(target)
    }
    /// owner 2026-10-18: may `me` promote, demote or edit `target`? The owner: anyone but themselves.
    /// An admin with `addAdmins`: a member (to promote), or an admin they promoted. Never the owner.
    /// The same test as firestore.rules `delegatedAdminEditOK`.
    func canManageAdmin(_ me: String, _ target: String) -> Bool {
        guard isGroup, target != me, !isOwner(target), users.contains(target) else { return false }
        if isOwner(me) { return true }
        guard adminCan(me, .addAdmins), adminRights[me] != nil else { return false }
        return !admins.contains(target) || adminBy[target] == me
    }

    // Per-member restrictions (the reference app bannedRights). Slugs the client enforces at send time.
    enum Restrict: String, CaseIterable, Identifiable {
        case sendText, sendMedia, sendVoice, sendStickers, sendPolls, sendReactions, pinMessages, addMembers, changeInfo
        // owner 2026-10-18 (admin delete sheet, "What can this member do?"): `sendMedia` split three
        // ways. The old flag still means all three, so a restriction written by an older build keeps
        // its meaning; the sheet writes the finer ones (plus `sendMedia` when all three are off).
        case sendPhotos, sendFiles, sendLinks
        var id: String { rawValue }
    }
    /// Flags currently restricting `uid` (empty once the `until` timestamp passes). Admins/owner are never restricted.
    func activeRestrictions(_ uid: String, now: Double) -> Set<String> {
        if isOwner(uid) || admins.contains(uid) { return [] }
        guard (restrictedUntil[uid] ?? 0) > now, let flags = restrictedFlags[uid], !flags.isEmpty else { return [] }
        return Set(flags)
    }
    func isRestricted(_ uid: String, _ r: Restrict, now: Double) -> Bool {
        let active = activeRestrictions(uid, now: now)
        if active.contains(r.rawValue) { return true }
        // owner 2026-10-18: the old all-media flag covers each of the three it was split into.
        switch r {
        case .sendPhotos, .sendFiles, .sendLinks: return active.contains(Restrict.sendMedia.rawValue)
        default: return false
        }
    }
    /// owner 2026-10-18: what `uid` may not send right now, in words for the composer's notices
    /// ("photos and videos, files"). Empty when nothing is held back, or when everything is (the
    /// muted bar says that one).
    func blockedSendWords(_ uid: String, now: Double) -> [String] {
        guard !isMutedMember(uid, now: now) else { return [] }
        let words: [(Restrict, String)] = [(.sendPhotos, "photos and videos"), (.sendFiles, "files"),
                                           (.sendVoice, "voice messages"), (.sendStickers, "stickers and GIFs"),
                                           (.sendLinks, "links")]
        return words.filter { isRestricted(uid, $0.0, now: now) }.map(\.1)
    }
    /// The "mute everything" preset = every send flag restricted (what the simple Mute action sets).
    static let muteAllFlags: [String] = [Restrict.sendText, .sendMedia, .sendVoice, .sendStickers, .sendPolls, .sendReactions].map(\.rawValue)
    /// True if `uid` is fully muted (can't send any content) right now.
    func isMutedMember(_ uid: String, now: Double) -> Bool {
        activeRestrictions(uid, now: now).contains(Restrict.sendText.rawValue)
    }

    /// Slow mode applies to `me` here: a member (owner and admins never), with the switch on. The
    /// server's onNewMessage holds the same line, so a send it would remove is refused before it goes.
    func slowsMember(_ me: String) -> Bool {
        AppFeatures.slowMode && isGroup && slowModeSeconds > 0 && !isOwner(me) && !admins.contains(me)
    }
    /// Seconds `me` still waits, judged from the chat-list summary (my own message last). For screens
    /// without the message list, such as Forward; the chat itself uses its loaded messages.
    func slowWaitFromSummary(_ me: String, now: Double) -> Int {
        guard slowsMember(me), lastSender == me else { return 0 }
        let left = Double(slowModeSeconds) - (now - updatedAtMillis) / 1000
        return left > 0 ? Int(left.rounded(.up)) : 0
    }

    /// Group Settings "Start group call" (2026-10-18): with Admins only, a member may join a call
    /// that is going but not start one (the server's `groupCallToken` and the rules say the same).
    func canStartCall(_ me: String) -> Bool {
        // A closed group starts no calls (audit 2026-10-26 item 4): ended by its owner, or
        // suspended / disabled by Fariin. The call buttons go with it.
        if isGroup && groupMod.blocksSending() { return false }
        // An admin needs Manage video chats (audit item 3): the same test as the server's groupRights.js.
        return !isGroup || !onlyAdminsCall || adminCan(me, .manageCalls)
    }

    /// The kinds a group can turn off for members, each on its own (owner 2026-10-20: "a switch
    /// for each, not modes"). Admins are never limited. firestore.rules `memberSendOk` holds them.
    enum SendKind: String, CaseIterable {
        case photos, videos, voice, files, stickers, gifs, links, polls, location
        var label: String {
            switch self {
            case .photos: "Photos"
            case .videos: "Videos"
            case .voice: "Voice messages"
            case .files: "Files"
            case .stickers: "Stickers"
            case .gifs: "GIFs"
            case .links: "Links"
            case .polls: "Polls"
            case .location: "Location"
            }
        }
        var icon: String {
            switch self {
            case .photos: "photo"
            case .videos: "video"
            case .voice: "mic"
            case .files: "doc"
            case .stickers: "face.smiling"
            case .gifs: "sparkles.rectangle.stack"
            case .links: "link"
            case .polls: "chart.bar.xaxis"
            case .location: "location"
            }
        }
        /// The words in "Admins turned off ___ in this group."
        var words: String {
            switch self {
            case .photos: "photos"
            case .videos: "videos"
            case .voice: "voice messages"
            case .files: "files"
            case .stickers: "stickers"
            case .gifs: "GIFs"
            case .links: "links"
            case .polls: "polls"
            case .location: "location sharing"
            }
        }
    }

    func maySend(_ kind: SendKind, _ me: String) -> Bool {
        guard isGroup, !admins.contains(me), !isOwner(me) else { return true }
        return membersMaySend(kind)
    }

    /// The group's own switch for a kind, admins aside. Builds 990/991 wrote one `media` key for
    /// photos and videos: it still counts until a newer switch is written.
    func membersMaySend(_ kind: SendKind) -> Bool {
        if kind == .photos || kind == .videos, memberSend[kind.rawValue] == nil {
            return memberSend["media"] != false
        }
        return memberSend[kind.rawValue] != false
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
    var memberCountLabel: String {
        if isChannel { return "\(subscriberCount) follower\(subscriberCount == 1 ? "" : "s")" }
        return "\(users.count) member\(users.count == 1 ? "" : "s")"
    }

    /// ⛔ A CHANNEL'S SHOWN SIZE, THE REFERENCE APP'S COUNT (owner 2026-10-29: "followers sometimes
    /// say 0, it must work like the reference app"). Its subscriber count is every participant: the
    /// owner and admins too, so a new channel reads "1", never "0". Ours keeps followers apart from
    /// `users` (the admins), so the two are added here. And my own follow or leave shows at once
    /// (`ChannelCountBias`), since `followerCount` itself lands in the server's once-a-minute batch.
    /// Gates (statistics, story minimum) still use `followerCount`, followers only.
    var subscriberCount: Int {
        guard isChannel else { return users.count }
        _ = ChannelCountTick.shared.n   // read so a view showing this redraws when my change lands
        return max(0, ChannelCountBias.adjusted(id, followerCount) + users.count)
    }
    /// I follow this channel and am not one of its admins.
    func isFollower(_ me: String) -> Bool { isChannel && followerRead != nil && !users.contains(me) }
    /// HOW MANY messages are waiting. Never negative: a negative value is the OLD manual "mark as
    /// unread" flag (before 2026-09-24), which means a dot and no number — see `ChatService.markUnread`.
    /// A follower's: the channel's posts past the ones they have read.
    func unread(_ me: String) -> Int {
        if isFollower(me) { return max(0, postCount - (followerRead ?? 0)) }
        return max(0, unreadCount[me] ?? 0)
    }
    /// You marked this chat unread yourself. A reminder, not a claim that somebody sent you something,
    /// so the list shows a plain dot rather than "1".
    /// 2026-09-24 decision D13: read from its own `markedUnread` flag, so a new message (which bumps
    /// `unreadCount`) no longer cancels it. A chat still carrying the old -1 counts as marked until
    /// it is next opened, which writes the count back to 0.
    func manuallyUnread(_ me: String) -> Bool { (markedUnread[me] ?? false) || (unreadCount[me] ?? 0) < 0 }
    /// Anything at all to show in the list's badge slot, of either kind.
    func hasUnreadMark(_ me: String) -> Bool { unread(me) > 0 || manuallyUnread(me) }
    func isMuted(_ me: String, now: Double) -> Bool {
        if isFollower(me) { return followerMuted && (followerMutedUntil <= 0 || followerMutedUntil > now) }
        return (mutedBy[me] ?? 0) > now
    }
    /// 2026-09-26 block rebuild: `me` has blocked the other person in this 1:1. The account list
    /// (`BlockList`, private to me) decides; an old copy still on the chat counts until it is moved.
    /// Called with somebody else's uid it can only see that person's OLD shared copy, which is
    /// exactly as much as the app is allowed to know about who blocked whom. Never true for a group.
    func isBlockedByMe(_ me: String) -> Bool {
        guard !isGroup else { return false }
        let other = otherUid(me)
        if !other.isEmpty, other != me, BlockList.snapshot.contains(other) { return true }
        return blockedBy[me] ?? false
    }
    func blockedAtMillis(_ me: String) -> Double {
        if !isGroup, let at = BlockList.snapshot.entries[otherUid(me)], at > 0 { return at }
        return blockedAt[me] ?? 0
    }
    /// When the chat's latest activity is a message the block holds back (sent while I had them
    /// blocked, now or in a past block), the time the list must freeze at instead; nil when the
    /// latest activity may be shown. Silent block in the chat LIST: its preview/time/order freeze.
    private func hiddenLastSince(_ me: String) -> Double? {
        guard !isGroup, updatedAtMillis > 0 else { return nil }
        let other = otherUid(me)
        if isBlockedByMe(me) {
            let since = blockedAtMillis(me)
            return since > 0 && updatedAtMillis > since ? since : nil
        }
        // An ENDED block: only when the last message is theirs, from inside that block.
        guard lastSender == other else { return nil }
        let snap = BlockList.snapshot
        if let span = snap.spans[other]?.first(where: { $0.contains(updatedAtMillis) }) { return span.lowerBound }
        let at = blockedAt[me] ?? 0, cleared = blockClearedAt[me] ?? 0
        if at > 0, cleared >= at, (at...cleared).contains(updatedAtMillis) { return at }
        return nil
    }
    func leaksBlocked(_ me: String) -> Bool { hiddenLastSince(me) != nil }
    /// Sort/time key that ignores the blocked person's held-back messages (freezes at block time).
    func displayUpdatedAt(_ me: String) -> Double { hiddenLastSince(me) ?? updatedAtMillis }
    /// ⛔ WHERE THE CHAT LIST PUTS IT (owner 2026-10-29: "when I follow it should come to the top").
    /// A channel I follow sits by its last post OR the moment I followed, whichever is newer, as the
    /// reference app places a channel just joined; it then slides down like any chat. The row's
    /// TIME still says the last post (`displayUpdatedAt`).
    func listSortDate(_ me: String) -> Double {
        isFollower(me) ? max(displayUpdatedAt(me), followedAtMillis) : displayUpdatedAt(me)
    }
    func isPinned(_ me: String) -> Bool { isFollower(me) ? followerPinned : (pinnedBy[me] ?? false) }
    /// Manual order for pinned chats; defaults to recency so never-moved pins stay sensible.
    /// FROZEN recency (audit): the raw fallback let a silently-blocked pinned chat jump to the top
    /// of the pinned block on each of their messages — exactly the activity the freeze hides.
    func pinRank(_ me: String) -> Double { pinOrder[me] ?? displayUpdatedAt(me) }
    func isArchived(_ me: String) -> Bool { isFollower(me) ? followerArchived : (archivedBy[me] ?? false) }
    /// "delete for me" until a newer message arrives (parity with RN Db.isCleared).
    func isCleared(_ me: String) -> Bool { updatedAtMillis <= (clearedAt[me] ?? 0) }
    /// My message is the most recent one — show delivery/read ticks for it in the list.
    func lastIsMine(_ me: String) -> Bool { !lastSender.isEmpty && lastSender == me }
    /// The other person has read my last message once their unread count hits 0.
    /// In a group, "read" = every other member's unread count is 0.
    /// `<= 0`, not `== 0`: somebody who marks YOUR chat unread on their side writes a negative flag,
    /// and they have still read your message — taking your second tick away because they wanted a
    /// reminder would be a lie about them.
    /// My last message reached the other person's phone (1:1 only; a group has no delivered state).
    func lastDeliveredToOther(_ me: String) -> Bool {
        guard !isGroup, updatedAtMillis > 0, !lastHeld else { return false }
        return (delivered[otherUid(me)] ?? 0) >= updatedAtMillis
    }
    func lastReadByOther(_ me: String) -> Bool {
        if isGroup { return others(me).allSatisfy { (unreadCount[$0] ?? 0) <= 0 } }
        if lastHeld { return false }   // unblocking zeroes their unread count; it was never read
        return (unreadCount[otherUid(me)] ?? 0) <= 0
    }
    /// HAS SOMEBODY ELSE PLAYED MY VOICE NOTE? The reference app turns the sender's mic icon blue for exactly
    /// this, and it is the one voice-note signal we had nothing for: you could send a two-minute note
    /// and never learn whether it was heard.
    ///
    /// A watermark comparison, so it inherits the watermark's one flaw honestly: playing your newest
    /// note while skipping an older one marks the older one played too. That is the same approximation
    /// `PlayedVoice.upTo` already makes on the listening side, and it buys one small field instead of a
    /// write against every message.
    ///
    /// In a group it takes ANYBODY having played it, not everybody — a note read out to eight people is
    /// heard once it is heard, and holding the mark back until the last silent member opens the app
    /// would leave it dark forever.
    func voicePlayedByOther(_ me: String, createdAtMillis: Double) -> Bool {
        others(me).contains { (lastPlayedVoice[$0] ?? 0) >= createdAtMillis }
    }
    /// A reaction newer than the last message → the chat list previews it ("Reacted 🙏").
    /// Hidden for silently-blocked reactors, and for reactions older than a delete-for-me.
    func freshReaction(_ me: String) -> Bool {
        // A channel's list line is always its last post (2026-10-28), never somebody's reaction.
        !isChannel && !lastReactionBy.isEmpty && lastReactionEnc != nil
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
/// ⛔ DRAFTS ARE ENCRYPTED AT REST — owner's decision, 2026-08-28, and it fixes the oddest hole in
/// the app: in a messenger whose whole premise is end-to-end encryption, the ONE message body that
/// was never encrypted anywhere was the one still being typed.
///
/// It used to be `UserDefaults.standard.set(map, forKey:)` on every keystroke, which lands the text
/// in `Library/Preferences/<bundle>.plist` in the clear, keyed by conversation. Readable by anything
/// with container access, and carried into an unencrypted computer backup.
///
/// The shape here is theirs in spirit: they keep the draft body on the thread record inside their
/// encrypted database, under the same protection as the messages. We have no such database, so the
/// equivalent is a device-local key in the keychain and the same AES-GCM seal the rest of the app
/// uses for content.
///
/// ⚠️ THE KEY IS DEVICE-ONLY AND SURVIVES REBOOT, deliberately: `Keychain.set` writes with
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, so a draft is readable after the first unlock
/// (which is when the app can run at all) and never leaves this phone or reaches a backup that could
/// be restored elsewhere. Losing the key simply means the drafts are unreadable and are dropped —
/// which is the right failure for unsent text, and is why every read is fallible rather than
/// throwing.
@Observable
final class Drafts {
    static let shared = Drafts()
    private static let key = "chatDraftsSealed"
    /// The old plaintext key. Read once at startup so existing drafts are not lost, then deleted —
    /// leaving it behind would keep the very plaintext this change exists to remove.
    private static let legacyPlainKey = "chatDrafts"
    private static let keychainKey = "draftsKey"

    /// owner audit 2026-10-06 chat #44. EVERY KEY PRESS used to seal the whole map (all chats), read
    /// the key from the keychain, write UserDefaults, and change this observed property, which
    /// re-ran the chat list's body under the open chat. Small hitches while typing fast.
    ///
    /// Now: `live` takes each edit at once and is NOT observed, so `text(_:)` always answers with the
    /// latest words. Observers watch `version` only, which moves when the edits are flushed: after a
    /// short pause in typing, on leaving the chat (`flush()`), and when the app resigns active or goes
    /// to the background, which is also the step before any kill from the app switcher. A crash
    /// inside the pause can lose at most that pause's keystrokes of an unsent draft.
    @ObservationIgnored private var live: [String: String]
    private var version = 0
    @ObservationIgnored private var dirty = false
    @ObservationIgnored private var pendingFlush: DispatchWorkItem?
    @ObservationIgnored private var lifecycleObservers: [NSObjectProtocol] = []
    private static let flushDelay: TimeInterval = 0.6

    /// Kept for any reader of the whole map; observing it observes the flushes.
    var map: [String: String] { _ = version; return live }

    private init() {
        live = Self.load()
        // Migrate anything written by the old plaintext store, then take it off the disk.
        if let old = UserDefaults.standard.dictionary(forKey: Self.legacyPlainKey) as? [String: String] {
            for (cid, text) in old where live[cid] == nil { live[cid] = text }
            UserDefaults.standard.removeObject(forKey: Self.legacyPlainKey)
            Self.save(live)
        }
        // Never leave an edit only in memory when the app is about to stop running.
        let nc = NotificationCenter.default
        for name in [UIApplication.willResignActiveNotification,
                     UIApplication.didEnterBackgroundNotification,
                     UIApplication.willTerminateNotification] {
            lifecycleObservers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.flush()
            })
        }
    }

    func text(_ cid: String) -> String { _ = version; return live[cid] ?? "" }
    func set(_ cid: String, _ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard live[cid] ?? "" != t else { return }   // no-op → no observation churn per keystroke
        let wasEmpty = (live[cid] ?? "").isEmpty
        if t.isEmpty { live.removeValue(forKey: cid) } else { live[cid] = t }
        dirty = true
        // A draft appearing or disappearing decides whether a chat row says "Draft" at all, so that
        // edge is flushed at once; edits inside an existing draft wait for the pause.
        if wasEmpty != t.isEmpty { flush(); return }
        scheduleFlush()
    }

    /// Writes any held edit now: seals it to disk and lets observers (the chat list) see it.
    func flush() {
        pendingFlush?.cancel(); pendingFlush = nil
        guard dirty else { return }
        dirty = false
        version &+= 1
        Self.save(live)
    }

    private func scheduleFlush() {
        pendingFlush?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flush() }
        pendingFlush = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.flushDelay, execute: work)
    }

    /// Sign-out/delete: drafts are unsent message text — wipe them, and the key with them, so the
    /// stored blob is not merely orphaned but unreadable.
    func clear() {
        pendingFlush?.cancel(); pendingFlush = nil
        dirty = false
        live = [:]
        version &+= 1
        UserDefaults.standard.removeObject(forKey: Self.key)
        Keychain.delete(Self.keychainKey)
        Self.keyLock.withLock { Self.cachedKey = nil }   // the next draft gets a fresh key
    }

    // MARK: - At-rest

    /// owner audit 2026-10-06 chat #44: the key is read from the keychain once and kept in memory;
    /// it was a keychain read on every save. Dropped by `clear()` together with the stored key.
    private static let keyLock = NSLock()
    private static var cachedKey: SymmetricKey?

    /// The device-local sealing key, created on first use.
    private static func sealingKey() -> SymmetricKey {
        keyLock.withLock {
            if let k = cachedKey { return k }
            if let stored = Keychain.get(keychainKey), let raw = Data(base64Encoded: stored) {
                let k = SymmetricKey(data: raw)
                cachedKey = k
                return k
            }
            let fresh = SymmetricKey(size: .bits256)
            let raw = fresh.withUnsafeBytes { Data($0) }
            Keychain.set(keychainKey, raw.base64EncodedString())
            cachedKey = fresh
            return fresh
        }
    }

    private static func save(_ map: [String: String]) {
        guard !map.isEmpty else { UserDefaults.standard.removeObject(forKey: key); return }
        guard let json = try? JSONSerialization.data(withJSONObject: map),
              let sealed = try? AES.GCM.seal(json, using: sealingKey()).combined else {
            // A draft we cannot seal is not written in the clear as a fallback. Losing unsent text is
            // a small harm; writing it as plaintext is the harm this whole type exists to prevent.
            UserDefaults.standard.removeObject(forKey: key)
            return
        }
        UserDefaults.standard.set(sealed, forKey: key)
    }

    private static func load() -> [String: String] {
        guard let blob = UserDefaults.standard.data(forKey: key),
              let box = try? AES.GCM.SealedBox(combined: blob),
              let json = try? AES.GCM.open(box, using: sealingKey()),
              let out = try? JSONSerialization.jsonObject(with: json) as? [String: String] else { return [:] }
        return out
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
    static let contactMarker = "fariin-contact:"
    /// Marker format: "fariin-contact:<uid>|<photoURL-or-empty>|<name>" (name last — it may contain "|"-free
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
    static let locationMarker = "fariin-location:"
    /// "fariin-location:<lat>|<lon>|<label-or-empty>"
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

// MARK: - Pinned-message notice (reference-style "X pinned …" row in the chat). E2EE-SAFE: the
// snippet rides the ENCRYPTED text pipeline as a feature marker — a plaintext system message would
// leak message content to the server.

struct PinNoticeCard {
    let messageId: String   // the pinned message → the notice is tappable (jump to it)
    let label: String       // "\"snippet…\"" or "a photo" / "a voice message" / …
}

extension Message {
    static let pinMarker = "fariin-pinned:"
    /// "fariin-pinned:<messageId>|<label>" (label last — may contain any characters).
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

// MARK: - Poll (reference-style). E2EE-SAFE: the question + options ride the ENCRYPTED text pipeline as
// a "fariin-poll:" marker (base64 JSON), so the server never sees them. Votes live in a per-voter
// subcollection (messages/{mid}/votes/{uid}) as plain option INDICES — meaningless without the
// end-to-end-encrypted options — and each voter can only write their own doc.

struct PollCard: Equatable {
    let id: String
    let question: String
    let options: [String]
    let multiple: Bool
    /// 2026-10-19: names stay off the results. Display only: each vote is still the voter's own
    /// document, which the group's members can read, so this is not a secret ballot.
    var hideVoters: Bool = false
    /// Quiz: the right option(s); empty = an ordinary poll. Sealed with the poll, like the options.
    var correct: [Int] = []
    /// When voting ends (ms), nil = never. Also written in the clear (`pollEndsAt`) for the rules.
    var endsAt: Double? = nil
    var isQuiz: Bool { !correct.isEmpty }
}

extension Message {
    static let pollMarker = "fariin-poll:"
    var poll: PollCard? {
        guard text.hasPrefix(Self.pollMarker) else { return nil }
        let b64 = String(text.dropFirst(Self.pollMarker.count))
        guard let data = Data(base64Encoded: b64),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = obj["id"] as? String,
              let q = obj["q"] as? String,
              let opts = obj["opts"] as? [String], opts.count >= 2 else { return nil }
        let correct = ((obj["quiz"] as? [Any]) ?? []).compactMap { ($0 as? NSNumber)?.intValue }
            .filter { $0 >= 0 && $0 < opts.count }
        let ends = (obj["ends"] as? NSNumber)?.doubleValue
        return PollCard(id: id, question: q, options: opts, multiple: obj["multi"] as? Bool ?? false,
                        hideVoters: obj["anon"] as? Bool ?? false, correct: correct,
                        endsAt: (ends ?? 0) > 0 ? ends : nil)
    }
    static func pollMarkerText(id: String, question: String, options: [String], multiple: Bool,
                               hideVoters: Bool = false, correct: [Int] = [], endsAt: Double? = nil) -> String {
        var obj: [String: Any] = ["id": id, "q": question, "opts": options, "multi": multiple]
        if hideVoters { obj["anon"] = true }
        if !correct.isEmpty { obj["quiz"] = correct }
        if let endsAt { obj["ends"] = Int64(endsAt) }
        let data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
        return pollMarker + data.base64EncodedString()
    }
}

// MARK: - Forward compatibility: structured feature payloads share the reserved "fariin-<feature>:"
// namespace over the text pipeline. A build that does NOT recognize a given feature (e.g. a stable
// version receiving a payload from a newer beta) renders it as a system "sent with a newer version"
// notice instead of the raw marker text. When you add a NEW feature marker, add its prefix to
// `knownFeatureMarkers` so THIS version keeps rendering it normally.
extension Message {
    static let knownFeatureMarkers: [String] = [contactMarker, locationMarker, pinMarker, pollMarker]

    /// True when the text uses the reserved fariin-feature namespace with a feature this build doesn't
    /// know — i.e. it was sent by a newer app version. Matched strictly (`^fariin-<name>:`) so ordinary
    /// text that merely contains "fariin-" is never affected. (Alphanumeric so future names like
    /// `fariin-poll2:` / `fariin-livelocation:` are still caught.)
    static let featureMarkerPattern = "^fariin-[a-z0-9]+:"
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
        if isSticker { return StickerSend.label(emoji: stickerEmoji) }   // 2026-10-17 chat stickers
        if contactCard != nil { return "Contact" }
        if locationCard != nil { return "Location" }
        if let p = poll { return "📊 \(p.question)" }
        if pinNotice != nil { return "Pinned a message" }
        if isUnsupportedFeature { return "Message from a newer version" }
        if isFeatureMarker { return "Message" }   // malformed known marker → never leak the raw payload
        return text
    }
}

/// One picture a chat-list reaction preview shows (see `Conversation.lastReactionToImages`).
struct ReactionThumb: Hashable {
    let url: String
    let enc: EncMeta?
}
