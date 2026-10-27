import Foundation
import Observation
import UIKit
import AVFoundation
import ImageIO   // CGImageSourceCreateThumbnailAtIndex, for the embedded story cover
import FirebaseAuth
import FirebaseFirestore
import FirebaseStorage
import FirebaseFunctions   // copyRepostMedia — an unchanged repost is copied on the server
import CryptoKit   // audienceToken — see `StoryAudienceToken.token`
import StoryUI   // StoryVideoSeed / StoryImageSeed — the uploader warms the viewer's caches

/// ⛔ WHO A STORY WENT TO, WITHOUT SAYING WHO THEY ARE.
///
/// The story document has to carry its audience: the tray is one `array-contains` query against it,
/// and a Firestore read rule can only authorise from fields on the document it is granting. But a
/// rule cannot grant a document while HIDING one field of it — so for as long as that array held raw
/// uids, every recipient who read a story read the author's whole contact list with it, up to a
/// thousand people. The same hole was closed for strangers in 2026-08 by moving public reach to
/// `users/{uid}/publicStories`; this is the half that was left, and it was the bigger half, because
/// a friend is far likelier to look.
///
/// The array holds an opaque token per person now: `sha256("fariin-audience-v1:<uid>")`, lowercase
/// hex. Everything that has to work still works, because every party can compute the token it needs
/// and nobody can invert the ones it does not:
///   · the tray queries `array-contains` its OWN token — one listener, same shape, same cost;
///   · the read rule recomputes the caller's token with `hashing.sha256` and looks for it;
///   · one-time consumption and block-revocation remove that person's token;
///   · the author still gets a COUNT for `recipientsLeft`, which never needed identities.
///
/// ⚠️ THE TOKEN CANNOT BE PER-STORY, AND THAT IS A CONSTRAINT RATHER THAN A CHOICE. The tray is a
/// single `array-contains` across every story at once, so the value it searches for has to be the
/// same in all of them; a token mixed with the story id would need one query per story. So it is
/// derived from the uid alone.
///
/// ⚠️ WHAT THIS DOES NOT DO, so nobody writes a stronger claim beside it. A uid is not guessable —
/// 28 characters of base62 — so the list cannot be inverted or enumerated, which is the leak. Two
/// things do survive: somebody who ALREADY KNOWS a particular uid can hash it and test whether that
/// person received a story, and because the token is stable they can tell that the same unnamed
/// person appears in several stories they received. Closing those would mean a fan-out write per
/// recipient rather than one array, which is a different feature.
enum StoryAudienceToken {
    /// ⚠️ THIS EXACT STRING IS RECOMPUTED IN TWO OTHER PLACES — `firestore.rules` (`hashing.sha256`)
    /// and `onStoryConsumed` in the Cloud Functions. Change the prefix, the separator or the case and
    /// all three have to change in the same breath, or every story becomes unreadable to everyone.
    /// The version in the prefix is there so a future change can be made without guessing.
    static func token(_ uid: String) -> String {
        SHA256.hash(data: Data("fariin-audience-v1:\(uid)".utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    static func tokens(_ uids: some Sequence<String>) -> [String] { uids.map(token) }
}

// One story (photo or video). Rules-protected (v1, not E2EE); media is a plain file in Storage.
/// WHO A STORY WENT TO, as a label — not as a pointer to the list it came from.
///
/// The header shows this so an author with ten stories up can tell at a glance which went where
/// (his request, 2026-08-06, with three reference screens). It is a LABEL and nothing more: it says
/// what KIND of audience was chosen, never who was in it, because a recipient reads the whole story
/// document and anything on it is something they can see.
///
/// ⚠️ `name` IS NEVER WRITTEN TO FIRESTORE. A custom story's name is the author's own private note
/// for it — "only you can see the name of this story" — and he restated that rule with this very
/// request ("they should not see any private details beyond the audience type"). So the name is kept
/// on the author's own device, keyed by the story it belongs to, and other people see the plain word
/// "Custom".
///
/// It is also NOT a listId, deliberately. Nothing on a posted story points back at the list it came
/// from, which is what makes "changes never affect stories you've already sent" true by construction
/// rather than by care. A label is frozen at post time and cannot lead anywhere.
struct StoryAudienceTag {
    var label: String        // "everyone" | "friends" | "glowers" | "custom" | "oneTime"
    var name: String = ""    // custom lists only, device-local
    /// The custom list(s) it went to, by id: the link the header follows to the list's CURRENT name,
    /// as the reference app links a story to its list rather than to a name. See `StoryAudienceLink`.
    var listIds: [String] = []
    var oneTime: Bool { label == "oneTime" }
    /// GROUP STORY (owner 2026-10-23): label "group", the group's conversation id in `listIds[0]` and
    /// its name in `name`. Carried this way because the tag already rides every post path, the
    /// outboxes included, so a retried upload still knows which group it was for.
    var groupId: String? { label == "group" ? listIds.first.flatMap { $0.isEmpty ? nil : $0 } : nil }
    static func group(_ id: String, name: String) -> StoryAudienceTag {
        StoryAudienceTag(label: "group", name: name, listIds: [id])
    }
    static let friends = StoryAudienceTag(label: "friends")
    static let everyone = StoryAudienceTag(label: "everyone")
    /// ⚠️ ITS OWN LABEL, NOT "friends". This is the word the author's own header shows and the key
    /// the Posted Stories filter groups by, so a Glowers story wearing the friends label would be
    /// mislabelled on the story AND invisible to its own filter. The two `switch a.kind` blocks in
    /// `ShareStorySheet` both fell through to `.friends` by `default`, which is why this had to be
    /// added at both of them rather than only in the type.
    static let glowers = StoryAudienceTag(label: "glowers")

    /// ⛔ WHETHER AN EMPTY `included` MEANS NOBODY, OR MEANS "NO EXPLICIT LIST" — and getting this
    /// wrong is the worst bug this feature can have.
    ///
    /// `resolveAudience` ends in three lines: a non-empty `included` wins, then a non-empty
    /// `excluded`, then the whole pool. So an audience whose ENTIRE definition is its `included`
    /// set, arriving empty, falls through to the pool — the author's whole chat list. A story the
    /// sheet labelled Glowers is then delivered to every person he has ever chatted with, his own
    /// header still says "glowers", and `recipientUids` is pinned immutable by the update rule, so
    /// there is no repair and nothing tells him. Three separate routes reached that state:
    ///
    ///   · an account with no glows yet (the list is legitimately empty),
    ///   · a cold launch where the two glow listeners have not landed (`GlowService.hasLoaded` was
    ///     false and NOTHING read it),
    ///   · editing a posted story's audience to Glowers, where the branch was simply missing.
    ///
    /// The fix is to stop inferring intent from emptiness. The tag already travels with every post
    /// through every entry point — the sheet, the background poster, the outbox retry and the
    /// audience edit — so it is the one thing that knows what was MEANT, and it says so here.
    ///
    /// ⚠️ FALSE FOR `custom` AND `friends`, deliberately, and not because their lists cannot be
    /// empty. `custom` and My Friends' two narrowing modes are collected by a picker that refuses an
    /// empty selection (`requireAtLeastOne`), and `friends`/`everyone` legitimately mean "the pool".
    /// Marking those true would turn a working audience into a refusal.
    var emptyMeansNobody: Bool { label == "glowers" }
}

struct Story: Identifiable, Hashable, Codable {
    let id: String
    let authorUid: String
    let createdAt: Date
    let expiresAt: Date
    let mediaUrl: String
    let allowsReplies: Bool
    var caption: String = ""   // overlay caption (stored as text, rendered in the viewer)
    var isVideo: Bool = false
    var duration: Double = 0   // video length in seconds (photos: 0 → viewer uses the 5s standard)
    var thumbUrl: String = ""  // video poster frame (photos: empty)
    /// An official story's bottom button ("Learn more" and where it goes), set in the admin panel.
    /// OPTIONAL on purpose: stories are cached as JSON, and the synthesized decoder only tolerates a
    /// missing key on an optional, so a default value here would fail every story saved before it.
    var buttonText: String?
    var buttonUrl: String?
    /// A base64 JPEG about 30px wide, carried in the story document itself. See `blurThumbBase64`
    /// and `StoryUI.Story.blurThumb` — this is the cover that cannot be missing.
    var blurThumb: String = ""
    /// The Link and Location stickers on this story, if any — see `StoryTapTarget`. The DRAWING of
    /// them is already in the media; this is only where they are and what they open.
    var stickers: [StoryTapTarget] = []
    /// Bytes of this clip worth fetching before it is watched, written at post time. Zero for
    /// anything posted before the field existed. See `StoryUI.Story.preloadPrefix`.
    var preloadPrefix: Int64 = 0
    /// The audience LABEL this story was posted with. See `StoryAudienceTag`.
    var audienceLabel: String = "friends"
    /// One of Fariin's welcome stories for new accounts (the feed's `welcome`). Shown WITHOUT a time
    /// anywhere (owner 2026-10-24: people should not see when we posted it).
    /// Optional on disk: a cached copy from before the field existed must still decode.
    var welcomeFlag: Bool? = nil
    var isWelcome: Bool { welcomeFlag == true }
    /// Each recipient may open it exactly once. Enforced on the server by removing them from
    /// `recipientUids` the moment they do — see `StoryPrefs.consumeOneTime` and `onStoryConsumed`.
    var oneTime: Bool = false
    /// ⛔ THE AUTHOR ASKED FOR THIS STORY NOT TO BE COPIED, and the viewer honours it for the whole
    /// session. What iOS actually does about a screenshot is written down in `CaptureShield`, and it
    /// is less than the word "block" promises — nothing near this flag may claim more than the
    /// system delivers. False for every story posted before the option existed.
    var captureProtected: Bool = false
    /// How many of the people this story was sent to are still in its audience — and therefore, for
    /// a one-time story, how many of them have NOT used their single view yet. It counts down as
    /// each one opens it, because that is precisely what consuming a one-time story does: the
    /// server takes them out of `recipientUids`.
    ///
    /// MY OWN STORIES ONLY. Nobody else may read that field (it is the author's audience list), so
    /// for everybody else's stories this stays at -1, which means "not known" and never "nobody".
    var recipientsLeft: Int = -1
    /// ⛔ THE STORY THIS ONE WAS REPOSTED FROM, or nil for an ordinary post — see `StoryRepost`.
    var repostOf: StoryRepost? = nil
    /// My own story only: who it went to, as the hashed tokens the document holds. Lets the header
    /// find a custom list's name when this phone has lost it (see `storyAudienceTitle`). Optional so
    /// a story cached before this existed still decodes.
    var recipientTokens: [String]? = nil
    /// Set on a group story: the group's conversation id, name and photo as they were at posting.
    /// Optional for the same reason as the tokens above, so the row cache from older builds decodes.
    var groupId: String? = nil
    var groupName: String? = nil
    var groupPhoto: String? = nil
    /// The ring this story sits in for somebody else: the group's for a group story, else the author's.
    var ringKey: String {
        guard let g = groupId, !g.isEmpty else { return authorUid }
        return StoryGroup.groupKeyPrefix + g
    }

    // What card/ring/reply thumbnails should render: the photo itself, or the video's poster.
    // Every image consumer (row cards, morph carousel, reply quotes, archive) reads THIS, never
    // mediaUrl directly — a video's mediaUrl is an .mp4 and image-decodes to nothing.
    //
    // ⚠️ EMPTY, NEVER THE MP4, for a video with no thumb yet. The old fallback handed the .mp4 to
    // every image consumer, and the video poster path then read megabytes off disk on the main
    // thread, downloaded the whole clip a SECOND time in parallel with the player's own fetch, and
    // still had no picture at the end — his 2026-08-09 spinner-over-black screenshot. An empty url
    // draws a placeholder immediately, which is honest and free.
    var previewUrl: String { isVideo ? thumbUrl : mediaUrl }
}

/// ⛔ WHERE A REPOSTED STORY CAME FROM — owner, 2026-09-11: "repost story, how does it work, make
/// it like [the reference app] exactly, go take experience, read please."
///
/// ⚠️ A REPOST IS A NEW STORY WITH A COPY OF THE PICTURE, NOT A POINTER AT THE ORIGINAL, and that
/// single decision settles most of the rest. The reference builds the repost by uploading the media
/// again alongside a small header naming the source, so:
///
///   • the repost runs on the REPOSTER's own clock and expires on its own schedule, not the
///     original's;
///   • it has its own audience, chosen by the reposter, independent of the original's;
///   • deleting or expiring the original leaves every repost intact and playable — there is no
///     cascade, because there is nothing to cascade through. Only the back-LINK goes dead, and the
///     attribution falls back to a plain name.
///
/// A pointer would have been less work and is the wrong shape: it makes every repost a live
/// dependency on a document its author does not control, and a story that vanishes mid-view is a
/// worse experience than one whose credit line no longer opens.
///
/// ⚠️ `authorName` IS STORED, NOT LOOKED UP. The reference carries a bare name string for exactly
/// the case where the source cannot be resolved — a deleted account, a story long gone, somebody who
/// blocked the viewer since. Without it the credit line on an old repost reads as blank, which looks
/// like a bug and quietly strips the attribution the feature exists to give.
///
/// ⚠️ `modified` SAYS THE PICTURE WAS CHANGED. The reposter may draw, crop, add text or stickers, and
/// a viewer deserves to know whether what they are looking at is what was posted. True whenever the
/// composer altered the media, false for a clean pass-through.
/// ⚠️ `Codable` BECAUSE `Story` IS. Story conforms, and a stored property that does not drops the
/// whole synthesised conformance several hundred lines away with an error that names Story rather
/// than this — which is exactly how the first build of this feature failed. The two string fields
/// and the flag synthesise it for free.
struct StoryRepost: Equatable, Hashable, Codable {
    var authorUid: String
    var authorName: String
    var storyId: String
    var modified: Bool = false
    /// ⛔ DRAWN AS A CARD — owner, 2026-10-11 (`RepostCard`): the picture itself carries the
    /// author's face and name, so the viewer's header does not repeat them. False for every repost
    /// made before the card, which keep their header credit line. OPTIONAL so a post saved in the
    /// outbox before this field existed still decodes (`StoryOutbox` stores this type as JSON).
    var card: Bool? = nil
    /// ⛔ A GROUP STORY'S REPOST CREDITS THE GROUP (owner 2026-10-26): `authorName` is then the
    /// group's name, the card wears the group's photo, and a tap opens the group. `authorUid` stays
    /// the poster, which the server's copy check compares with the original. Nil for a person's story.
    var groupId: String? = nil
    var groupPhoto: String? = nil

    var asData: [String: Any] {
        var d: [String: Any] = ["authorUid": authorUid, "authorName": authorName, "storyId": storyId,
                                "modified": modified, "card": card ?? false]
        if let groupId, !groupId.isEmpty { d["groupId"] = groupId; d["groupPhoto"] = groupPhoto ?? "" }
        return d
    }

    static func from(_ raw: Any?) -> StoryRepost? {
        guard let m = raw as? [String: Any],
              let uid = m["authorUid"] as? String, !uid.isEmpty else { return nil }
        // ⚠️ THE STORY ID IS NOT REQUIRED. It is the back-link the credit line opens, and a record
        // without one is still a repost with an author to credit; empty here means "no original to
        // open", and the tap on that line falls back to the author's profile.
        return StoryRepost(authorUid: uid,
                           authorName: m["authorName"] as? String ?? "",
                           storyId: m["storyId"] as? String ?? "",
                           modified: m["modified"] as? Bool ?? false,
                           card: m["card"] as? Bool,
                           groupId: (m["groupId"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                           groupPhoto: (m["groupPhoto"] as? String).flatMap { $0.isEmpty ? nil : $0 })
    }
}

/// ⛔ A GROUP'S OWNER AND ITS ADMINS OVER ITS STORIES (owner 2026-10-26, as the reference app): the
/// owner, or an admin holding Delete messages, may take down any story in the group's ring (the rules'
/// `groupStoryModerator`), and neither is offered Hide Stories or Report on their own group.
@MainActor enum GroupStoryStaff {
    private static var me: String { AuthService.shared.uid ?? "" }
    private static func conv(_ gid: String) -> Conversation? {
        ConversationsRepository.shared.conversations.first { $0.id == gid && $0.isGroup }
    }
    /// Staff = exactly who may take a story down (audit 2026-10-26 item 7). An admin without Delete
    /// messages cannot delete one, so they keep Hide Stories and Report like any member.
    static func isStaff(ringKey: String) -> Bool {
        guard ringKey.hasPrefix(StoryGroup.groupKeyPrefix) else { return false }
        return mayDelete(groupId: String(ringKey.dropFirst(StoryGroup.groupKeyPrefix.count)))
    }
    static func noReport(ringKey: String) -> Bool {
        // Fariin's own official stories: nothing to report to Fariin (owner 2026-10-27).
        if OfficialChannel.isOfficial(ringKey) { return true }
        guard ringKey.hasPrefix(StoryGroup.groupKeyPrefix) else { return false }
        return conv(String(ringKey.dropFirst(StoryGroup.groupKeyPrefix.count)))?.groupNoReport == true
    }
    /// The rules' `groupStoryModerator`, word for word: a member who is the owner, or is in `admins`
    /// with no rights entry (legacy, all rights) or one that lists deleteMessages.
    static func mayDelete(groupId: String) -> Bool {
        guard let c = conv(groupId), c.users.contains(me) else { return false }
        if c.createdBy == me { return true }
        guard c.admins.contains(me) else { return false }
        return c.adminRights[me]?.contains(Conversation.Right.deleteMessages.rawValue) ?? true
    }
}

/// ONE REPLY IN A GROUP STORY'S SHARED THREAD (owner 2026-10-23, group stories v2, the reference
/// (signal) model): a reply to a group story goes to everyone the story reached, not privately to
/// the poster. Text, or an emoji for a reaction. Stored at `stories/{id}/replies/{replyId}`; the rules
/// let everyone the story reached read and write until it expires, and its writer or a group admin
/// delete. `onStoryDeleted` removes the thread with the story.
struct GroupStoryReply: Identifiable, Equatable {
    let id: String
    let uid: String
    let text: String
    let emoji: String
    let createdAt: Date
    var isReaction: Bool { text.isEmpty && !emoji.isEmpty }
}

extension StoriesService {
    func sendGroupReply(_ story: Story, text: String = "", emoji: String = "") async throws {
        guard story.groupId != nil else { return }
        try await sendGroupReply(storyId: story.id, text: text, emoji: emoji)
    }

    /// The same, from the Replies tab's composer, which knows the story by id alone.
    func sendGroupReply(storyId: String, text: String = "", emoji: String = "") async throws {
        let me = AuthService.shared.uid ?? ""
        guard !me.isEmpty, !storyId.isEmpty else { return }
        var data: [String: Any] = ["uid": me, "createdAt": FieldValue.serverTimestamp()]
        let t = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1000))
        if !t.isEmpty { data["text"] = t }
        if !emoji.isEmpty { data["emoji"] = String(emoji.prefix(16)) }
        guard data["text"] != nil || data["emoji"] != nil else { return }
        try await FirestoreHub.db.collection("stories").document(storyId)
            .collection("replies").addDocument(data: data)
    }

    /// Oldest first, as a chat reads. The caller removes the registration.
    func listenGroupReplies(storyId: String, _ onChange: @escaping ([GroupStoryReply]) -> Void) -> ListenerRegistration {
        FirestoreHub.db.collection("stories").document(storyId).collection("replies")
            .order(by: "createdAt").limit(toLast: 500)
            .addSnapshotListener { snap, _ in
                let rows = (snap?.documents ?? []).map { d -> GroupStoryReply in
                    let x = d.data()
                    return GroupStoryReply(id: d.documentID, uid: x["uid"] as? String ?? "",
                                           text: x["text"] as? String ?? "", emoji: x["emoji"] as? String ?? "",
                                           createdAt: (x["createdAt"] as? Timestamp)?.dateValue() ?? Date())
                }
                DispatchQueue.main.async { onChange(rows) }
            }
    }

    func deleteGroupReply(storyId: String, replyId: String) async throws {
        try await FirestoreHub.db.collection("stories").document(storyId)
            .collection("replies").document(replyId).delete()
    }

    /// Who may delete `reply` in this group: its writer, or the group's owner or an admin.
    @MainActor static func canDeleteGroupReply(_ reply: GroupStoryReply, groupId: String) -> Bool {
        let me = AuthService.shared.uid ?? ""
        if reply.uid == me { return true }
        guard let c = ConversationsRepository.shared.conversations.first(where: { $0.id == groupId }) else { return false }
        return c.isOwner(me) || c.isAdmin(me)
    }
}

extension GroupStoryRights {
    /// WHO SEES A GROUP STORY'S VIEWS (owner 2026-10-23): its poster, and the group's owner and
    /// admins, whoever of them posted it. Members never do. firestore.rules `storyViewsReader`.
    @MainActor static func canSeeViews(_ s: Story) -> Bool {
        let me = AuthService.shared.uid ?? ""
        guard !me.isEmpty else { return false }
        if s.authorUid == me { return true }
        guard let gid = s.groupId,
              let c = ConversationsRepository.shared.conversations.first(where: { $0.id == gid }) else { return false }
        return c.isOwner(me) || c.isAdmin(me)
    }
}

/// WHO MAY POST A GROUP STORY (owner 2026-10-23). The same test as firestore.rules `groupStoryOK`:
/// the owner always, an admin who holds the Add story right (owner 2026-10-25), nobody else.
enum GroupStoryRights {
    static func canPost(_ c: Conversation, _ uid: String) -> Bool {
        guard c.isGroup, !uid.isEmpty, c.users.contains(uid), !c.fariinLocked else { return false }
        // owner 2026-10-23: only a group of 50 or more (panel-set) has stories, except for app
        // admins (like @v), who may post to any group they run.
        guard c.users.count >= AppLimits.shared.groupStoryMinMembers || AdminStore.shared.isAdmin
                || ProfileStore.shared.me?.groupStoryOpen == true else { return false }
        if c.isOwner(uid) { return true }
        return c.adminCan(uid, .postStories)
    }
    /// The groups the New Group Story list offers, from the live chat list.
    @MainActor static func eligibleGroups() -> [Conversation] {
        let me = AuthService.shared.uid ?? ""
        return ConversationsRepository.shared.conversations
            .filter { canPost($0, me) && !DemoMode.isDemoConversation($0.id) }
    }
}

/// ⛔ MAY THIS PERSON PASS THIS STORY ON — owner's spec, 2026-09-11:
///
///   • Story audience = Everyone → show Share, Copy Story Link and Repost.
///   • The story's owner has blocked the viewer → hide all three completely.
///   • "Make sure this logic is enforced consistently in both the UI and the underlying story
///     permissions."
///
/// ⚠️ ONE ANSWER, ASKED BY EVERY SURFACE. That last line is the whole reason this is a type rather
/// than a condition written at each button. The viewer's footer, the long-press menu on a card, the
/// posted-stories grid and whatever comes next each have their own idea of what they are looking at,
/// and a rule spelled out four times is a rule that is three-quarters right within a month. Every
/// one of them calls `allows(_:)`.
///
/// ⚠️ AND IT IS NOT ONLY THE AUDIENCE. Two other flags on a story already say "do not copy this",
/// and a Share button that ignored them would be a hole underneath two settings the author has
/// already used:
///
///   • `oneTime` — each recipient may open it exactly once. A link that outlives that single view is
///     the opposite of the promise, and the server enforces the single view by removing people from
///     the audience, which a shared copy walks straight around.
///   • `captureProtected` — the author asked for this story not to be copied. Screenshots are only
///     as blockable as iOS allows (see `CaptureShield`), but a Share button is entirely ours to not
///     draw, and it would be strange to fight the screenshot and then offer the file.
///
/// ⚠️ MY OWN STORY IS ALWAYS SHAREABLE, whatever its audience. A private story of mine is private
/// from other people, not from me — sending my own picture on is a thing I am allowed to decide, and
/// the Posted Stories page has offered exactly that since it was built.
@MainActor enum StoryShareRights {
    /// The viewer's uid, or "" when signed out.
    private static var me: String { AuthService.shared.uid ?? "" }

    /// Has this author blocked me? Read from the conversation between us, which is where a block
    /// lives: `isBlockedByMe(them)` means "them blocked the other party", i.e. them blocked me.
    /// No conversation means no block — two people who have never spoken cannot have one.
    /// ⚠️ NOT `@MainActor`-ISOLATED, AND `ConversationsRepository` IS WHY IT DOES NOT NEED TO BE.
    /// That repository is a plain `@Observable final class`, so reading `conversations` carries no
    /// isolation requirement — and this has to be callable from a SwiftUI computed property that is
    /// not itself isolated (`StoryViewer.models`, which builds every story the viewer draws). An
    /// isolated version could only be reached with an `await`, and a view body cannot wait.
    static func authorHasBlockedMe(_ authorUid: String) -> Bool {
        guard !authorUid.isEmpty, authorUid != me else { return false }
        let cid = ChatService.convId(me, authorUid)
        guard let c = ConversationsRepository.shared.conversations.first(where: { $0.id == cid })
        else { return false }
        return c.isBlockedByMe(authorUid)
    }

    /// A public group: it has an @name and is switched public (`Conversation.isPublic`). A group in
    /// my chat list answers itself; another one answers by a kept public preview (2026-10-27).
    static func groupIsPublic(_ groupId: String) -> Bool {
        if let c = ConversationsRepository.shared.conversations.first(where: { $0.id == groupId }) {
            return c.isPublic
        }
        // owner 2026-10-27: someone NOT in the group may open a public group's story (search, a
        // link) and may share and repost it. The server answers a preview only for a public group,
        // so a kept preview is the answer for a group that is not in my list.
        return GroupDirectory.cachedPreview(name: nil, cid: groupId) != nil
    }

    /// The one question. True = Share, Copy Story Link and Repost may all be offered.
    static func allows(_ s: Story) -> Bool {
        // ⛔ A GROUP STORY IS PASSED ON ONLY FROM A PUBLIC GROUP (owner 2026-10-25: "public groups:
        // repost and share link"). Anybody can already find and open a public group; a private
        // group's story stays inside it. The same two "do not copy this" flags apply, and the
        // poster's block on me, as for any story.
        if let gid = s.groupId, !gid.isEmpty {
            guard groupIsPublic(gid), !s.oneTime, !s.captureProtected else { return false }
            return !authorHasBlockedMe(s.authorUid)
        }
        // The author's own copy, and the two flags that say "not this one" even then. A one-time
        // story I posted is still one-time for the people who got it, and passing it on would hand
        // it to somebody who is not in that count at all.
        // ⛔ AND ONLY IF IT WENT TO EVERYONE — owner, 2026-10-11: his own My Chats story offered
        // Share and Copy Story Link. "Only when Everyone was chosen before posting; My Chats or a
        // custom list never shows them, and never makes a link." A link to a story only some
        // people may watch is a link that tells everyone else it exists.
        if s.authorUid == me {
            return s.audienceLabel == StoryAudienceTag.everyone.label && !s.oneTime && !s.captureProtected
        }
        guard s.audienceLabel == StoryAudienceTag.everyone.label else { return false }
        guard !s.oneTime, !s.captureProtected else { return false }
        return !authorHasBlockedMe(s.authorUid)
    }
}

extension StoriesService {
    /// A COVER SMALL ENOUGH TO PUT IN THE DOCUMENT, which is what makes it impossible to be missing.
    ///
    /// The reference implementation's approach: every story carries thumbnail bytes inside its own data,
    /// so the viewer draws a blurred cover on the first frame of the first visit with no cache and no
    /// network. Ours had only a URL — and for a video that URL is a separately uploaded `thumb.jpg`
    /// which may not have landed, or may never land at all. When it was missing the viewer had
    /// nothing to hold the screen with and showed the canvas or black, which is the report he has
    /// filed more than any other.
    ///
    /// 30px on the long edge at quality 0.4 lands around 400-700 bytes of base64 — nothing against
    /// Firestore's 1 MB document limit, and it is written with the document rather than after it, so
    /// there is no window where the story exists without a cover. It is never drawn sharp: the veil
    /// puts it through `StoryCanvas.loadingVeil`, the same blur the real poster gets, which is
    /// exactly how the reference app uses theirs.
    /// Takes the ENCODED bytes, never a `UIImage`, and that is deliberate on both call sites: the
    /// photo path holds the picked file's data and the video path holds its poster's data, so a
    /// `UIImage` here would mean decoding a full-size picture at post time to throw all but 30
    /// pixels of it away. `CGImageSourceCreateThumbnailAtIndex` decodes straight to the size asked
    /// for, and honours the EXIF orientation while it does it, so a photo taken sideways gets a
    /// cover the right way up.
    static func blurThumbBase64(_ data: Data) -> String {
        guard !data.isEmpty,
              let src = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 30,
                  kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary)
        else { return "" }
        return UIImage(cgImage: cg).jpegData(compressionQuality: 0.4)?.base64EncodedString() ?? ""
    }
}

// A person's active (unexpired) stories — the unit behind a ring in the row + the viewer.
struct StoryGroup: Identifiable, Codable {
    let authorUid: String
    let name: String
    let photoUrl: String?
    var stories: [Story]          // oldest → newest
    var lastViewedAt: Date?
    var isMine: Bool

    var id: String { authorUid }

    /// A GROUP'S RING (owner 2026-10-23) keeps the group's key in `authorUid` ("g:" + conversation
    /// id): one ring per group, whoever of its admins posted. Code that would treat the key as a
    /// person (profile, 1:1 chat, notify) asks `groupConvId` first.
    static let groupKeyPrefix = "g:"
    var groupConvId: String? {
        authorUid.hasPrefix(Self.groupKeyPrefix) ? String(authorUid.dropFirst(Self.groupKeyPrefix.count)) : nil
    }

    // Unseen ⇔ ANY story I haven't watched yet (the standard rule: watching 1 of 5 no
    // longer greys the whole ring). A story counts as seen if I viewed that exact item on this
    // device (StoryPrefs flag) OR it's not newer than my synced watermark — `lastViewedAt` holds
    // the POST time of the newest story of theirs I've watched (covers reinstalls/other devices).
    // Applies to my own story too: colorful until I open it.
    var hasUnseen: Bool {
        stories.contains { !StoryPrefs.isStorySeen($0.id) && $0.createdAt > (lastViewedAt ?? .distantPast) }
    }
}

// One viewer of my story, for the "Seen by" sheet.
struct StoryViewerInfo: Identifiable {
    let id: String        // viewer uid
    let name: String
    let photoUrl: String?
    let viewedAt: Date
    let reaction: String?
}

/// WHAT THE OWNER'S FOOTER ACTUALLY NEEDS: a number, a number of hearts, and three faces.
///
/// The reference app's story object carries exactly this down with the story (`seenCount`,
/// `reactedCount`, a few recent peers) and asks for the LIST only when the list is opened. Ours had
/// no such thing, so every appearance of that one number read every viewer receipt on the story.
/// See `StoriesService.fetchViewSummary` and the `onStoryViewWritten` trigger that maintains it.
struct StoryViewSummary {
    var count: Int
    var reactionCount: Int
    /// Up to three, newest first. Faces only — the sheet is where a viewer becomes a row with a
    /// time and a reaction on it.
    var recent: [StoryViewerInfo]
    /// How many times it was reposted. On the author-only counter document, so only the author
    /// ever reads it (owner, 2026-10-11). Zero for a summary counted from the receipts.
    var repostCount: Int = 0

    /// The same summary worked out the old way, for a story whose counter does not exist yet.
    static func counted(from viewers: [StoryViewerInfo]) -> StoryViewSummary {
        StoryViewSummary(count: viewers.count,
                         reactionCount: viewers.filter { !($0.reaction ?? "").isEmpty }.count,
                         recent: Array(viewers.prefix(3)))
    }
}

/// THE LAST COUNT WE KNEW FOR EACH OF MY STORIES, KEPT ON DISK.
///
/// The owner's footer reads "N Views", and until the fetch for that story lands there is nothing to
/// read it from — so it read zero, which is not a placeholder, it is a number, and it is a wrong
/// one. His 2026-08-14 report: "Views count shows 0 when I first open the story, then updates a few
/// seconds later." The in-viewer cache that already existed only helped within one sitting, because
/// it is `@State` and dies with the screen; the FIRST open after every launch paid the round trip
/// with a zero painted over it.
///
/// Two integers and three uids per story, so what was true when he last looked is on screen in the
/// first frame and the network only ever corrects it.
///
/// ⚠️ UIDS, NOT NAMES OR PHOTOGRAPHS, AND THAT IS WHAT MAKES CACHING THE FACES CHEAP ENOUGH TO DO.
///
/// This used to keep the two integers alone, and said so: "names and photographs of other people are
/// worth more room than they save here, and the eye icon they fall back to is not a wrong answer the
/// way a 0 is." The objection was right and the conclusion did not follow — because a face is not
/// stored, it is RESOLVED. `fetchViewSummary` never downloads a name or a photograph either: it
/// reads uids off the counter document and looks them up in the chat list that is already in memory.
/// So the only thing the network was buying was the uids, and three of those per story is nothing.
/// Nobody's name or photograph is written to disk by this, which is the same privacy answer the old
/// note wanted, arrived at without the delay it cost.
///
/// That delay is the owner's 2026-08-16 report: the count appeared instantly (it was cached) while
/// the avatars beside it waited a Firestore round trip every single time.
///
/// ⚠️ THIS IS A CACHE, NOT A COUNTER. The real fix is the summary travelling down WITH the story, the
/// way the reference app's own story object carries it — a denormalised field on the story document,
/// which is a server change and the owner's call (it is item 3B of the open season). Until then the
/// first ever look at a story still pays one round trip, and every look after it is instant.
/// ⛔ WHO WATCHED A STORY, HELD BETWEEN OPENINGS OF THE VIEWERS SHEET (owner 2026-08-22: "viewers,
/// they have a cache, make it like that, cache each story").
///
/// Read from the reference on his instruction, and it is a small thing done in a particular place.
/// It keeps a live per-story list context in a dictionary keyed by story id, in memory, owned by the
/// STORY SCREEN — so dismissing the viewers sheet and pulling it up again shows the people at once,
/// and only closing the story entirely forgets them. Its promise replays the last value to any new
/// subscriber, which is what stops the shimmer appearing on a reopen.
///
/// ⚠️ WE ALREADY HAD EVERYTHING BUT THE LIFETIME. The sheet's coordinator held exactly this
/// dictionary, warmed the two neighbours the same way, showed a hit without a spinner and refused to
/// remember a failed read. But SwiftUI builds that coordinator fresh for every presentation, so every
/// reopen was a cold start. Moving the dictionary out here is the whole fix.
///
/// ⚠️ MEMORY ONLY, LIKE THEIRS, AND THAT IS A DECISION. A viewer list on disk would outlive the
/// story it belongs to — stories last a day — and the worst failure of a cache like this is showing
/// somebody a list of watchers that is quietly wrong. A relaunch clearing it is the cheapest possible
/// correctness guarantee.
///
/// ⚠️ THE COUNTS LIVE SOMEWHERE ELSE (`StoryCountCache`), and that split is theirs too: they persist
/// the numbers with the story item and keep only the people in memory. The numbers are small, they
/// are needed before the sheet is ever opened, and they are what the row draws.
enum StoryViewerListCache {
    private static var store: [String: [StoryViewerInfo]] = [:]

    static func get(_ storyId: String) -> [StoryViewerInfo]? { store[storyId] }

    /// ⚠️ ONLY EVER A REAL ANSWER. A failed read must not be written here as an empty list — that is
    /// how "No views yet" once appeared under a card reading one view, and it poisoned the entry for
    /// the rest of the sitting. The caller checks; this is the reminder for the next one.
    static func put(_ people: [StoryViewerInfo], for storyId: String) {
        // 2026-10-17: never hold an empty list while receipts are off; it is cleared on the flip
        // anyway, and an empty answer then is the one most likely to be wrong a moment later.
        if people.isEmpty && !StoryReceiptPrefs.isOn { return }
        store[storyId] = people
    }

    /// Drop one story's list. For the two moments its audience can genuinely change out from under
    /// the list — the story being deleted, or its audience edited.
    static func forget(_ storyId: String) { store.removeValue(forKey: storyId) }

    static func clear() { store.removeAll() }
}

enum StoryCountCache {
    /// ⚠️ v2 BECAUSE THE ENTRY GAINED THE UIDS. The v1 key is abandoned rather than migrated: it
    /// holds two integers per story that the next fetch replaces anyway, and stories live 24 hours,
    /// so there is nothing in it worth carrying across.
    private static let key = "storyViewCounts.v2"
    private static let orderKey = "storyViewCounts.v2.order"
    /// Stories live 24h; this is generous enough that nothing he can still open has been dropped.
    private static let capacity = 300

    private struct Entry: Codable {
        var count: Int
        var reactions: Int
        /// Up to three viewer UIDS, newest first — see the note on the type for why it is these and
        /// not the faces themselves.
        var recent: [String]
        /// Optional so an entry written before reposts were counted still decodes.
        var reposts: Int?
    }

    /// JSON rather than a plist dictionary because the entry is no longer all one type. Read and
    /// written whole, which is what it always did — this runs on a story change, not in a loop.
    private static var store: [String: Entry] {
        get {
            guard let d = UserDefaults.standard.data(forKey: key),
                  let s = try? JSONDecoder().decode([String: Entry].self, from: d) else { return [:] }
            return s
        }
        set {
            guard let d = try? JSONEncoder().encode(newValue) else { return }
            UserDefaults.standard.set(d, forKey: key)
        }
    }

    /// ⚠️ THE FACES ARE REBUILT HERE, FROM MEMORY, AND THAT IS WHY THIS IS INSTANT. The chat list is
    /// seeded synchronously from its own disk cache at launch (`ConversationsDiskCache`), so by the
    /// time a story can be opened the names and photo urls are already in hand — and `AvatarView`
    /// seeds its image synchronously from the image cache in its initialiser. Uid on disk to a face
    /// on screen therefore costs no network and no frame.
    ///
    /// A uid that is not in the chat list resolves to "Someone" with a letter, exactly as the
    /// network path resolves it — the two cannot disagree, because they are the same function.
    static func summary(for storyId: String) -> StoryViewSummary? {
        guard let e = store[storyId] else { return nil }
        return StoryViewSummary(count: e.count, reactionCount: e.reactions,
                                recent: StoriesService.faces(for: e.recent),
                                repostCount: e.reposts ?? 0)
    }

    /// Drop one story's remembered numbers. Used when the thing they were counted against has
    /// changed under them — see `StoriesService.updateStoryAudience`.
    static func forget(_ storyId: String) {
        var s = store
        guard s.removeValue(forKey: storyId) != nil else { return }
        var order = UserDefaults.standard.stringArray(forKey: orderKey) ?? []
        order.removeAll { $0 == storyId }
        store = s
        UserDefaults.standard.set(order, forKey: orderKey)
    }

    static func put(_ storyId: String, count: Int, reactions: Int, recent: [String], reposts: Int = 0) {
        // 2026-10-17: same rule as `StoryViewerListCache.put`, no remembered zero while receipts are off.
        if count == 0 && !StoryReceiptPrefs.isOn { return }
        var s = store
        var order = UserDefaults.standard.stringArray(forKey: orderKey) ?? []
        if s[storyId] == nil { order.append(storyId) }
        s[storyId] = Entry(count: count, reactions: reactions, recent: recent, reposts: reposts)
        // Oldest first, and only ever a few at a time — this runs on a story change, not in a loop.
        while order.count > capacity {
            let dropped = order.removeFirst()
            s.removeValue(forKey: dropped)
        }
        store = s
        UserDefaults.standard.set(order, forKey: orderKey)
    }

    /// 2026-10-17: every number goes when the receipts switch flips; each was counted under the other
    /// setting (the frozen list while off, the full one while on).
    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
        UserDefaults.standard.removeObject(forKey: orderKey)
    }
}

/// ⛔ STORY VIEW RECEIPTS, PER ACCOUNT (owner 2026-10-17).
///
/// The switch used to be the local key alone, so a second phone, a reinstall or a sign-in elsewhere
/// had its own answer, and views made with it off were never written anywhere and could not come back.
/// Now `users/{me}/private/storyPrefs {receipts, offAt}` is the answer and the local key is its cache
/// (every existing reader still reads the key, missing = on).
///
/// OFF: my views go to `users/{me}/hiddenStoryViews` (mine alone), not onto the author's story. My
/// own stories show only the viewers who were there when I turned it off (`firstAt <= offAt`), never
/// anyone new. ON again: the server (`onStoryPrefsWritten`) turns my hidden views on stories still up
/// into real receipts, and my own lists open up to everyone who watched meanwhile. Nothing is deleted
/// because of OFF.
enum StoryReceiptPrefs {
    static let key = "storyViewReceipts"
    static let offAtKey = "storyViewReceiptsOffAt"

    static var isOn: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
    /// When it was turned off. Nil while on, or for an account that was off before this existed and
    /// has not been seen by the server yet (`start` writes one for it).
    static var offAt: Date? { UserDefaults.standard.object(forKey: offAtKey) as? Date }

    private static var authHandle: AuthStateDidChangeListenerHandle?
    private static var prefsWatch: ListenerRegistration?
    private static var watchedUid = ""

    private static func ref(_ uid: String) -> DocumentReference {
        FirestoreHub.db.collection("users").document(uid)
            .collection("private").document("storyPrefs")
    }

    /// The Settings switch. Local first so the next read on this phone already has it; the write is
    /// queued by Firestore when offline and lands later.
    static func set(_ on: Bool) {
        guard on != isOn else { return }
        apply(on: on, offAt: on ? nil : Date())
        guard let uid = Auth.auth().currentUser?.uid else { return }
        write(uid: uid, on: on)
    }

    private static func write(uid: String, on: Bool) {
        let offAt: Any = on ? NSNull() : FieldValue.serverTimestamp()
        ref(uid).setData(["receipts": on, "offAt": offAt])
    }

    private static func apply(on: Bool, offAt: Date?) {
        let d = UserDefaults.standard
        let changed = on != isOn || offAt != self.offAt
        d.set(on, forKey: key)
        if let offAt { d.set(offAt, forKey: offAtKey) } else { d.removeObject(forKey: offAtKey) }
        guard changed else { return }
        // Both caches were filled under the other setting; neither may outlive the flip.
        StoryViewerListCache.clear()
        StoryCountCache.clear()
    }

    /// Called once at launch. Follows the signed-in account and keeps the local key equal to the
    /// account's switch, so a flip on another phone arrives here too.
    static func start() {
        guard authHandle == nil else { return }
        authHandle = Auth.auth().addStateDidChangeListener { _, user in
            StoryReceiptPrefs.watch(uid: user?.uid ?? "")
        }
        // 2026-10-20 (owner): after `FirestoreHub.swap` the watch belongs to the stuck client. Let
        // go of it off-main and watch the same account again on the fresh one.
        swapObserver = NotificationCenter.default.addObserver(
            forName: FirestoreHub.swapped, object: nil, queue: .main) { _ in
            typealias P = StoryReceiptPrefs
            guard !P.watchedUid.isEmpty else { return }
            let uid = P.watchedUid
            FirestoreHub.drop([P.prefsWatch])
            P.prefsWatch = nil
            P.watchedUid = ""
            P.watch(uid: uid)
        }
    }
    private static var swapObserver: NSObjectProtocol?

    private static func watch(uid: String) {
        guard uid != watchedUid else { return }
        prefsWatch?.remove()
        prefsWatch = nil
        watchedUid = uid
        guard !uid.isEmpty else { return }
        prefsWatch = ref(uid).addSnapshotListener { snap, _ in
            typealias P = StoryReceiptPrefs
            guard let snap, P.watchedUid == uid else { return }
            if let data = snap.data(), let on = data["receipts"] as? Bool {
                // A pending local write has no server time yet; keep the local one until it lands.
                let serverOff = (data["offAt"] as? Timestamp)?.dateValue()
                P.apply(on: on, offAt: on ? nil : (serverOff ?? P.offAt ?? Date()))
            } else if !snap.metadata.isFromCache {
                // No document on the server: this account has only ever had the local switch.
                // Carry it up once, so the other phones and the server know it.
                let on = P.isOn
                if !on && P.offAt == nil { P.apply(on: false, offAt: Date()) }
                P.write(uid: uid, on: on)
            }
        }
    }
}

/// ⛔ WHAT TIME IT IS ACCORDING TO THE SERVER, WHICH IS NOT ALWAYS WHAT THE PHONE THINKS.
///
/// A story's whole life is 24 hours, and every client-side judgement about whether one is still
/// alive was `expiresAt > Date()`. A phone whose clock is wrong — set by hand, a flat battery, a bad
/// timezone rollover — therefore hid stories that had hours left, or kept showing ones that were
/// already gone. The server is never confused about this: the create rule pins `expiresAt` to within
/// 30 hours of ITS clock and the sweeper deletes against ITS clock, so the phone is the only party
/// that can disagree with everybody else.
///
/// ⚠️ THE ANCHOR IS THE AUTH TOKEN, and it is the cheapest true one available. A forced refresh
/// mints a token on Google's servers at that moment, so `issuedAtDate` IS the server's clock — the
/// difference against the local one is the phone's error, measured to within a round trip. Nothing
/// is written, nothing is polled, and the SDK refreshes this token on its own schedule anyway.
///
/// ⚠️ IT FAILS TO ZERO. No token, no network, no answer: the offset stays nought and every reader
/// behaves exactly as it did before. A correction that cannot be measured must never become one that
/// is guessed.
enum ServerClock {
    private static let lock = NSLock()
    private static var offset: TimeInterval = 0

    /// Now, as the server would say it.
    static var now: Date {
        lock.lock(); defer { lock.unlock() }
        return Date().addingTimeInterval(offset)
    }

    /// Learn the phone's error. Once per sign-in, off the main thread.
    static func sync() async {
        guard let user = Auth.auth().currentUser,
              let result = try? await user.getIDTokenResult(forcingRefresh: true) else { return }
        let delta = result.issuedAtDate.timeIntervalSince(Date())
        // Under a couple of seconds is the round trip, not the clock. Ignoring it keeps `now` steady
        // instead of moving by whatever the network did this launch.
        guard abs(delta) > 2 else { return }
        lock.lock(); offset = delta; lock.unlock()
    }
}

/// HOW A PHOTO STORY BECOMES A FILE. One canvas, ONE encode, a size check, upload.
///
/// ⚠️ IT USED TO BE ENCODED TWICE. The editor's `flatten` produced a JPEG at 0.9, and this
/// service then handed that straight to `ChatService.downscaledJPEG`, which decoded it, capped the
/// long edge at 1600 and re-encoded it at 0.72. Two lossy passes over the same pixels for nothing,
/// and the cap quietly shrank every composed story: the card is about 1080×1920, so anything with
/// text, a sticker, a pen stroke or a zoom on it posted at 900×1600 instead. That rule came from
/// chat photos, where an arbitrary camera file has to be brought down to something sendable. A
/// story frame is not an arbitrary file — it is a canvas this app drew, at the size it should be
/// posted at.
///
/// The shape here is the reference app's, because it is the right shape for a client that encodes
/// its own media: a fixed quality, and RESOLUTION gives way when a frame does not fit the budget.
/// Their media constraints step 4096 → 3072 → 2048 → 1600 → 1024 → 768 → 512 against 1.5 MB at
/// quality 75. Ours starts at the story canvas instead of a camera's full resolution, so the ladder
/// is shorter and the first rung is nearly always the answer.
enum StoryPhoto {
    /// The story canvas. Every composed frame is rendered at exactly this width, and 9:16 of it is
    /// 1080×1920 — the size a story is posted at everywhere. On a short phone the card is squatter
    /// than 9:16 and the file follows it, which is the same trade `flatten` has always made.
    static let canvasWidth: CGFloat = 1080
    /// The reference app's standard-quality budget, and for the same reason: a predictable upload
    /// on a phone that may be on one bar.
    static let budget = 1_500_000
    /// Fixed, like theirs. When a frame will not fit, pixels give way rather than quality — a
    /// smaller sharp picture beats a full-size mushy one.
    static let quality: CGFloat = 0.85
    /// Tried in order. The first rung is the canvas itself and almost always wins.
    static let widthLadder: [CGFloat] = [1080, 900, 720, 540]

    /// The one encode. Returns the first rung that fits the budget, or the smallest if none do.
    /// `q`: a repost card asks for more (0.93): its picture was already a JPEG once, and a second
    /// pass at 0.85 is the visible loss he reported (2026-10-12). Same budget and ladder either way.
    static func encode(_ image: UIImage, quality q: CGFloat = quality) -> Data {
        var last = Data()
        for w in widthLadder {
            guard let d = fit(image, toWidth: w).jpegData(compressionQuality: q) else { continue }
            last = d
            if d.count <= budget { return d }
        }
        return last
    }

    /// ⚠️ NEVER UPSCALES. A picture already at or under the rung is handed back untouched, which
    /// is what keeps the normal path to exactly one encode: the composer renders at 1080 wide, so
    /// the first rung resamples nothing.
    private static func fit(_ image: UIImage, toWidth w: CGFloat) -> UIImage {
        let px = image.size.width * image.scale
        guard px > w, image.size.width > 0, image.size.height > 0 else { return image }
        let k = w / px
        let size = CGSize(width: px * k, height: image.size.height * image.scale * k)
        let f = UIGraphicsImageRendererFormat.default()
        f.scale = 1                                    // the numbers above are already pixels
        return UIGraphicsImageRenderer(size: size, format: f).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    /// The net under the upload, for bytes that did NOT come from the composer.
    ///
    /// Every caller today hands over `flatten`'s output, which is already encoded by `encode` above
    /// and carries no camera metadata because it is drawn from pixels rather than copied. So this
    /// decodes NOTHING on the normal path — it is a length check. ⚠️ A future caller that passes a
    /// camera file straight through would keep its EXIF, GPS included: hand it to `encode` first.
    static func ensureWithinBudget(_ data: Data) -> Data {
        guard data.count > budget, let img = UIImage(data: data) else { return data }
        return encode(img)
    }
}

/// One wait in the story post queue, opened by whichever comes first: the post ahead finishing, or a
/// Firestore swap (`StoriesService.waitBehind`). Opening twice is harmless.
private final class StoryQueueGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false

    var isOpen: Bool { lock.lock(); defer { lock.unlock() }; return opened }

    func arm(_ c: CheckedContinuation<Void, Never>) {
        lock.lock()
        if opened { lock.unlock(); c.resume(); return }
        continuation = c
        lock.unlock()
    }

    func open() {
        lock.lock()
        let c = continuation
        continuation = nil
        opened = true
        lock.unlock()
        c?.resume()
    }
}

@Observable
final class StoriesService {
    static let shared = StoriesService()
    private init() {
        // 2026-10-20 (owner): a swapped Firestore client (`FirestoreHub.swap`). See `leaveStuckPosts`.
        swapObserver = NotificationCenter.default.addObserver(
            forName: FirestoreHub.swapped, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                let service = StoriesService.shared
                service.leaveStuckPosts()
                // The viewers sheet's watcher, on the same story, on the fresh client.
                let watching = service.viewCountWatchId
                if !watching.isEmpty {
                    FirestoreHub.drop([service.viewCountWatch])
                    service.viewCountWatch = nil
                    service.viewCountWatchId = ""
                    service.watchViewCount(storyId: watching)
                }
            }
        }
    }
    @ObservationIgnored private var swapObserver: NSObjectProtocol?

    // MARK: - Posts across a Firestore swap (2026-10-20)

    /// Posts whose upload has begun, keyed by placeholder id, each with the way to hand it back to
    /// its outbox ticket. Cleared when the post ends (`finishRunning`).
    @ObservationIgnored private var runningPosts: [String: (photo: Bool, handBack: @MainActor () -> Void)] = [:]
    /// Posts left behind on a swap: when (if ever) their old task returns, it touches nothing.
    @ObservationIgnored private var leftBehind: Set<String> = []

    @MainActor private func markRunning(_ pendingId: String, photo: Bool, handBack: @escaping @MainActor () -> Void) {
        runningPosts[pendingId] = (photo, handBack)
    }

    /// The post's task has returned. True when it was left behind on a swap, and the caller must then
    /// leave the ticket, the placeholder and the error alone (the retry owns them now).
    @MainActor private func finishRunning(_ pendingId: String) -> Bool {
        runningPosts[pendingId] = nil
        return leftBehind.remove(pendingId) != nil
    }

    /// ⛔ A POST STUCK ON THE OLD CLIENT MUST NOT HOLD THE QUEUE FOR EVER. Owner 2026-10-20 ("fix it
    /// so I never have to refresh"). Posts queue behind each other (`uploadTask`), so one post whose
    /// write waits on the stuck client blocked every later post until a restart. On the swap:
    /// - every post that was waiting its turn is let go (`waitBehind` watches the generation);
    /// - a new post no longer queues behind anything from before the swap;
    /// - a post that was mid-upload is handed back to its outbox ticket and sent again on the fresh
    ///   client: a photo through `StoryOutbox.retry` (the reconnect door), a video from its ticket
    ///   with the same story ids. Its placeholder goes; the retry draws its own.
    @MainActor private func leaveStuckPosts() {
        let stuck = runningPosts
        runningPosts = [:]
        for pid in stuck.keys {
            leftBehind.insert(pid)
            queuedUploads[pid] = nil
            inFlight.removeAll { $0.id == pid }
        }
        refreshUploading()
        uploadTask = nil
        currentUploadToken = nil
        guard !stuck.isEmpty else { return }
        DiagLog.add("stories: \(stuck.count) post(s) handed back to the outbox after the swap")
        for entry in stuck.values { entry.handBack() }
        if stuck.values.contains(where: { $0.photo }), let me = AuthService.shared.uid {
            StoryOutbox.retry(for: me)
        }
    }

    /// Waits for the post ahead in the queue, or for a Firestore swap after `generation`, whichever
    /// comes first. The post ahead may be waiting on the stuck client and never finish.
    private static func waitBehind(_ previous: Task<Void, Never>?, generation: Int) async {
        guard let previous else { return }
        let gate = StoryQueueGate()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            gate.arm(c)
            Task { await previous.value; gate.open() }
            Task { @MainActor in
                while !gate.isOpen, FirestoreHub.generation == generation {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
                gate.open()
            }
        }
    }

    private var db: Firestore { FirestoreHub.db }
    private var uid: String { Auth.auth().currentUser?.uid ?? "" }

    // Optimistic upload state — drives the "Uploading…" indicator + spinner ring in the story row.
    var uploading = false
    /// Groups with a group story going up (owner 2026-10-23: the progress ring belongs on that
    /// group's page, not on My Story). `uploading` above counts my own stories only.
    var uploadingGroups: Set<String> = []
    private func refreshUploading() {
        uploading = inFlight.contains { $0.tag.groupId == nil }
        uploadingGroups = Set(inFlight.compactMap { $0.tag.groupId })
    }

    /// WHICH HALF OF THE POST IS RUNNING, because they are not the same kind of wait and must not
    /// look the same.
    ///
    /// `.preparing` is work on THIS phone: squeezing the picture or transcoding the video. It has to
    /// block, because until it finishes there is no story — nothing to send and nothing to watch.
    /// This is another mainstream messenger's "Preparing…" box.
    ///
    /// `.sending` is the upload. It does NOT need the person, because their own copy is already
    /// finished and already playable from local bytes. That app shows a quiet "Adding status…" line
    /// here, with no spinner, and lets you open and watch it immediately.
    ///
    /// We used to run one spinning ring across BOTH, so a photo whose local work took ~0.3s still
    /// showed a busy ring for the ~2.9s the server took (owner measured it). The story was watchable
    /// that whole time; the ring was the only thing saying otherwise.
    enum UploadPhase { case preparing, sending }
    var uploadPhase: UploadPhase = .preparing

    /// A real `@MainActor` method rather than an inline `MainActor.run { self.… }`, because both
    /// callers are non-isolated `async` functions and one of them would have had to reach for `self`
    /// from inside a `@Sendable` closure to do it. Calling an isolated method on self is the version
    /// with no capture question at all.
    @MainActor private func markSending() { uploadPhase = .sending }

    var uploadError: String?   // set when a post fails so the UI can show it (was swallowed → "dead silent")
    private var uploadTask: Task<Void, Never>?

    /// ONE POST STILL IN THE AIR. There can be several, and that is the whole reason this type
    /// exists (owner 2026-08-07: "when I upload multiple images, every time I can see only the last
    /// one uploading — I need to see all, when I click right or left each one must be uploading").
    ///
    /// Posts have ALWAYS queued rather than replaced each other — the task chain below has done that
    /// since a second post silently destroyed the first — but the state describing them was a single
    /// image, a single url and a single start time, overwritten by whichever post was newest. So
    /// three pictures were three real uploads behind ONE placeholder: the two waiting their turn had
    /// nowhere to be drawn, and the viewer had nothing to page between.
    struct PendingUpload: Identifiable {
        let id: String                  // this post's synthetic story id — unique per post
        var image: UIImage?             // the picture, or a video's poster frame (filled off-main)
        let url: String                 // the synthetic media url its bytes are cached under
        let startedAt: Date
        let tag: StoryAudienceTag
        // The caption rides on the placeholder from frame one (his report: a caption typed before
        // posting only appeared once the upload finished — the synthetic item simply never carried it).
        let caption: String
        /// A repost carries its credit from frame one too, so the uploading card shows whose story
        /// it is instead of gaining the credit only when the post lands (2026-10-12).
        var repostOf: StoryRepost? = nil
        /// ⛔ THE REAL STORY ID(S) THIS POST WILL LAND AS — owner 2026-10-16: a first single story
        /// flashed the two-card stack. When the post lands it is in `mine.stories` for a moment while
        /// this card is still up, so the row stacked the story behind itself. The row leaves these
        /// out of "already posted". A video can land as several parts, hence a list.
        var docIds: [String] = []
    }
    /// Oldest first, which is the order stories are read in — so the placeholders sit at the end of
    /// my bucket in the same order they will land as real stories.
    private(set) var inFlight: [PendingUpload] = []

    // Synthetic story items shown while an upload runs, so an uploading photo appears INSIDE the
    // real story viewer (real progress bars, header, swipe to my older posted stories) instead of a
    // separate placeholder screen. Its image is served from URLCache (pre-stored on upload start);
    // its id marks it so the viewer shows the "Uploading…" bar and blocks delete.
    ///
    /// A PREFIX, not the id itself, since there can be several at once. Everything that used to ask
    /// `id == uploadingStoryId` asks `isPending(id)` instead.
    static let uploadingStoryId = "story.uploading.placeholder"
    static func isPending(_ storyId: String) -> Bool { storyId.hasPrefix(uploadingStoryId) }

    /// A NEW STORY'S ID: 10 random letters and digits, not a 36-character UUID, so its link is short
    /// (owner, 2026-10-11). 62^10 is about 8e17, far past any collision a 24-hour story could meet.
    /// ⛔ AN UNCHANGED REPOST IS COPIED ON THE SERVER, NOT UPLOADED AGAIN (owner, 2026-10-12; the
    /// reference app sends an unmodified repost by reference). The original story to copy from,
    /// when this repost carries its media untouched: not edited, not a card (a card is a new
    /// picture), and not a repost of a repost (the editor marks those modified). Nil otherwise.
    static func serverCopySource(_ r: StoryRepost?) -> String? {
        guard let r, !r.modified, r.card != true, !r.storyId.isEmpty else { return nil }
        return r.storyId
    }

    /// Ask the server to copy the original's media files into `stories/{to}/`. The server checks the
    /// original is public and unprotected and that `to` is this account's story. False on any
    /// failure, and the caller then uploads as it always did.
    func copyRepostMedia(from: String, to: String) async -> Bool {
        do {
            _ = try await Functions.functions(region: "me-central1")
                .httpsCallable("copyRepostMedia").call(["from": from, "to": to])
            return true
        } catch {
            return false
        }
    }

    static func newStoryId() -> String {
        let chars = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
        var rng = SystemRandomNumberGenerator()
        return String((0..<10).map { _ in chars[Int(rng.next(upperBound: UInt64(chars.count)))] })
    }

    /// The newest post's picture — what the story ROW draws on its single "Uploading…" card. The row
    /// has one slot for my story whatever is happening behind it; the viewer is where they are all
    /// visible.
    var uploadingImage: UIImage? { inFlight.last?.image }

    /// The custom list's device-local name for a placeholder: the real story's name is filed under
    /// its document id, which does not exist yet while it is uploading.
    func uploadingAudienceName(for storyId: String) -> String {
        inFlight.first { $0.id == storyId }?.tag.name ?? ""
    }

    /// Every post in the air, as story items. Each carries ITS OWN audience (a story posted to a
    /// custom list used to wear "My Friends" until the real document arrived) and its own picture.
    var uploadingStories: [Story] {
        inFlight.compactMap { p in
            guard p.image != nil, p.tag.groupId == nil else { return nil }   // a group post is the group's
            var s = Story(id: p.id, authorUid: uid, createdAt: p.startedAt,
                         expiresAt: p.startedAt.addingTimeInterval(24 * 3600),
                         mediaUrl: p.url, allowsReplies: false,
                         caption: p.caption,
                         audienceLabel: p.tag.label, oneTime: p.tag.oneTime)
            s.repostOf = p.repostOf
            return s
        }
    }

    // Fire-and-forget post: pop back to chat immediately, upload in the background, show progress.
    @MainActor func postStoryBackground(image: Data, caption: String = "", stickers: [StoryTapTarget] = [], excluded: Set<String> = [], included: Set<String> = [], everyone: Bool = false, allowsReplies: Bool = true, tag: StoryAudienceTag = .friends, captureProtected: Bool = false, repostOf: StoryRepost? = nil, storyDocId: String? = nil, resumed: Bool = false) {
        // One id for this post from the start, kept in the ticket, so a resume writes the same story.
        let docId = storyDocId ?? Self.newStoryId()
        // Don't cancel an in-flight post (that silently DESTROYED the 1st story when a 2nd was
        // posted) — QUEUE instead: the new task waits for the previous one, so both post in order.
        let previous = uploadTask
        let queuedOn = FirestoreHub.generation   // a swap frees this post from the queue (`waitBehind`)
        // PER-POST, not a constant, and the url must be fresh per post as well as unique: StoryUI's
        // ImageLoader keeps decoded images in StoryMemoryCache keyed by absoluteString, so a reused
        // path could serve post A's picture as post B's placeholder (for a video, A's poster: his
        // "shows a different video that was already in my Story" report). A fresh path misses every
        // cache by construction. The PATH must vary, not a query — the disk cache ignores queries.
        let pending = PendingUpload(id: "\(Self.uploadingStoryId).\(UUID().uuidString)",
                                    image: nil,   // filled by `prep`, off the main actor
                                    url: "https://fariin.local/uploading-\(UUID().uuidString).jpg",
                                    startedAt: Date(),
                                    tag: tag,   // the header says the chosen audience from frame one
                                    caption: caption,
                                    repostOf: repostOf,
                                    docIds: [docId])
        let pendingId = pending.id
        let pendingURL = pending.url
        let me = uid
        // ⛔ EVERY HEAVY THING A QUEUED POST DOES NOW HAPPENS OFF THE MAIN ACTOR.
        //
        // This function is `@MainActor` and the share sheet enqueues a whole post in ONE turn — up
        // to twenty items, one call each. Each call used to decode the picked photo at full camera
        // resolution, write those bytes into two caches, and write the outbox ticket's JPEG to disk:
        // all synchronous, all on the main thread. Twenty items is twenty full-resolution decodes
        // and forty blocking file writes before the UI gets a frame back, which is the owner's
        // "the whole app lags while a story uploads".
        //
        // None of it has to be there. The only thing the UI needs at once is the placeholder row,
        // which is `inFlight.append` below, and that can draw for a moment without a picture.
        //
        // ⚠️ THE TICKET IS STILL WRITTEN BEFORE THE FIRST BYTE MOVES. The upload task awaits this,
        // so the durable record exists before anything is sent — it is simply not built on the main
        // thread any more. See `StoryOutbox`.
        let prep = Task.detached(priority: .userInitiated) { () -> (UIImage?, String) in
            // Pre-store the picked bytes under the synthetic URL so the injected uploading item
            // renders instantly in the viewer. BOTH CACHES, not URLCache alone: nothing on any
            // server answers a `fariin.local` url, so an eviction has nowhere to fall back to.
            if let u = URL(string: pendingURL) { StoryImageSeed.seed(image, for: u) }
            // A DURABLE RECORD. The queue below is a `Task` and an array, both of which die with
            // the process — swipe the app away mid-upload and the post was simply gone, with
            // nothing to retry. The ticket is torn up the moment the story lands or is cancelled.
            let ticket = StoryOutbox.remember(image: image, caption: caption, stickers: stickers,
                                              excluded: excluded, included: included, everyone: everyone,
                                              allowsReplies: allowsReplies, tag: tag,
                                              captureProtected: captureProtected,
                                              // Whose post this is. The folder outlives a sign-out.
                                              ownerUid: me,
                                              // 2026-09-24 audit: and whose story it reposts, so a
                                              // resumed repost keeps its credit.
                                              repostOf: repostOf,
                                              storyDocId: docId)
            // The card's thumbnail is NOT made here any more — see `quick` below.
            return (nil, ticket)
        }
        // ⛔ THE PICTURE FIRST, ON ITS OWN — owner, 2026-10-11: "while preparing it shows grey, show
        // me the image I'm uploading". The thumbnail used to come out of `prep`, after the cache
        // seed, the outbox ticket written to disk and a FULL-resolution decode, so the row stayed
        // grey for the whole "Preparing…". ImageIO decodes straight to 420px, which is a few
        // milliseconds, and nothing else waits on it.
        let quick = Task.detached(priority: .userInitiated) { StoryImage.decode(image, maxPixels: 420) }
        Task { @MainActor in
            guard let card = await quick.value,
                  let i = self.inFlight.firstIndex(where: { $0.id == pendingId }),
                  self.inFlight[i].image == nil else { return }
            self.inFlight[i].image = card
        }
        inFlight.append(pending)
        refreshUploading()
        // Audit #15: only the FIRST post in a queue starts on "Preparing" — a picture added while
        // another is already sending must not set the row back to it.
        if inFlight.count <= 1 { uploadPhase = .preparing }
        // Each post owns a token; the completion below only touches shared state if it's STILL the
        // owner. Without this, a cancel-then-repost (or a quick second post) let the FIRST task's
        // completion run last and wipe the SECOND upload's spinner + task handle (so it couldn't be
        // cancelled) — the "Uploading…" ring vanished mid-upload.
        let token = UUID()
        currentUploadToken = token
        uploadTask = Task {
            // The thumbnail and the ticket, both built off the main actor — see `prep`. Awaited
            // here so the durable record still exists before the first byte moves.
            let (card, ticket) = await prep.value
            if let card {
                await MainActor.run {
                    if let i = self.inFlight.firstIndex(where: { $0.id == pendingId }) {
                        self.inFlight[i].image = card
                    }
                }
            }
            await Self.waitBehind(previous, generation: queuedOn)   // chain behind any in-flight post (posts queue, never cancel each other)
            // On a Firestore swap this post is handed back to its outbox ticket (`leaveStuckPosts`).
            await self.markRunning(pendingId, photo: true) {
                StoryOutbox.release(ticket)
            }
            var failure: String?
            var cancelled = false
            do {
                try await postStory(image: image, caption: caption, stickers: stickers, excluded: excluded, included: included, everyone: everyone, allowsReplies: allowsReplies, tag: tag, captureProtected: captureProtected, repostOf: repostOf, storyId: docId, replaceExisting: resumed)
                if await self.finishRunning(pendingId) { return }   // left behind on a swap: the retry owns it
                StoryOutbox.forget(ticket)   // it landed; there is nothing to resume
            }
            catch is CancellationError {
                if await self.finishRunning(pendingId) { return }
                cancelled = true              // user hit cancel → postStory removed the doc
                StoryOutbox.forget(ticket)    // …and a cancelled post must not come back next launch
            }
            catch {
                if await self.finishRunning(pendingId) { return }
                // ⚠️ A RULE REFUSAL DOES NOT GET A SECOND CHANCE — see `isPermanentPostFailure`. The
                // ticket is torn up here, or the next launch resumes a post the server has already
                // refused and shows the same alert again, forever.
                failure = Self.friendlyPostError(error)
                if Self.isPermanentPostFailure(error) { StoryOutbox.forget(ticket) }
                // 2026-09-24 decision D18: a kept ticket is no longer a running post, so a retry
                // (reconnect or "Try Again") may pick it up in this same session.
                else { StoryOutbox.release(ticket) }
            }
            // ⚠️ A PLAIN FAILURE KEEPS ITS TICKET. That is the whole point: no connection now is the
            // case worth remembering, and the next sign-in puts it back through this same door.
            if !cancelled && failure == nil { await StoriesRepository.shared.load(force: true) }
            await MainActor.run {
                self.queuedUploads[pendingId] = nil   // finished or cancelled: nothing left to cancel
                // ⚠️ OUTSIDE THE TOKEN GUARD, and that is the point of keeping them separate. This
                // post is finished whoever is newest, so its placeholder must go — under the guard,
                // an older post completing while a newer one is still uploading would never clear
                // its own entry and the row would show an upload that had already landed.
                self.inFlight.removeAll { $0.id == pending.id }
                self.refreshUploading()
                // ⚠️ A FAILURE IS REPORTED BY WHICHEVER POST FAILED, NOT ONLY BY THE NEWEST, AND
                // THIS IS OUTSIDE THE GUARD FOR THE SAME REASON THE LINE ABOVE IT IS.
                //
                // A post of five items enqueues all five in one turn, so the token belongs to item
                // five before item one has sent a byte. Under the guard, items one to four could
                // fail and their error was thrown away — while `inFlight.removeAll` above still ran,
                // so their placeholders vanished exactly as if they had landed. Three of five could
                // silently not exist, with the documents already rolled back by `postStory`'s catch.
                //
                // Nothing CLEARS the error here any more either. Success used to write `nil`, and
                // since the items complete in order that meant item five landing wiped item one's
                // report a moment after it was made. The alert's own OK button owns the clearing
                // (`StoriesRowUIKit`), which is the only place that knows the person has read it.
                if let failure { self.uploadError = failure }
                guard self.currentUploadToken == token else { return }   // a newer post owns the rest
                self.uploadTask = nil
            }
        }
        if let t = uploadTask { queuedUploads[pendingId] = t }   // cancellable on its own, by its placeholder id
    }
    private var currentUploadToken: UUID?

    /// CANCEL ONE POST, the one whose X was tapped (owner, 2026-10-14: three stories uploading,
    /// the X on one cancelled all three). Every other post keeps going.
    ///
    /// The queue still holds: a post waiting behind this one awaits its task, which ends at once —
    /// `postStory` checks cancellation before its first write — so the next post simply starts.
    /// Cancelling a post that is mid-upload rolls its documents back exactly as before.
    @MainActor func cancelUpload(id: String) {
        queuedUploads[id]?.cancel()
        queuedUploads[id] = nil
        inFlight.removeAll { $0.id == id }
        refreshUploading()
    }
    /// Every post task still in the air (including the one currently uploading), keyed by its
    /// placeholder id, so the X on one story reaches that story only. Entries are dropped as they finish.
    private var queuedUploads: [String: Task<Void, Never>] = [:]

    // Snapshot contacts on the MAIN actor (live-mutated there) and resolve the audience:
    //  • included non-empty -> only those; • excluded non-empty -> everyone minus those; • else everyone.
    // 1:1 contacts only (a group's otherUid is an arbitrary member → leak). Exclude anyone I've
    // BLOCKED — `isBlockedByMe`, NOT `leaksBlocked`: the latter is a chat-list freeze test (true only
    // if they messaged AFTER the block), so a quietly-blocked contact was slipping into the audience.
    /// WHY A POST WAS REFUSED, in words the composer can show. A story that reaches nobody is worse
    /// than a story that did not go: `recipientUids` is pinned immutable by the rules, so there is no
    /// repair afterwards and no way for him to find out. See `resolveAudience`.
    /// ⛔ IS THIS FAILURE WORTH KEEPING A TICKET FOR?
    ///
    /// The outbox exists for one case: the post could not go out NOW and will go out later — no
    /// signal, a dropped connection, the app killed mid-upload. A rule refusal is the opposite. It
    /// will refuse again on the next launch, and the next, and the ticket makes it try forever:
    /// every re-entry resumes the post, the server says no, and the alert comes back. That is the
    /// owner's report — the same message over and over with no way out but hitting the limit's own
    /// clock.
    ///
    /// So a permission failure discards the ticket. The post did not happen and is not coming back.
    static func isPermanentPostFailure(_ error: Error) -> Bool {
        // ⛔ OUR OWN REFUSALS ARE ANSWERED FIRST, because they are not `NSError`s and would
        // otherwise fall out of the bottom of this function as "try again later" — which for a
        // ticketed post means the outbox keeps it and every launch replays a post the app has
        // already decided against, re-showing the same alert forever. That is the failure the
        // comment at the call site warns about, arrived at from the other direction.
        //
        // ⚠️ ONLY THE ONE THAT CANNOT COME RIGHT ON ITS OWN. The split is whether WAITING could
        // change the answer:
        //   · `glowAudienceEmpty` — you have no Glows. Retrying tonight does not fix it; picking a
        //     different audience does. Permanent, ticket torn up.
        //   · `glowAudienceUnknown` — the glow listeners had not landed. That is a connection, and
        //     the next launch is exactly the retry the outbox exists for. NOT permanent.
        //   · `audienceUnavailable` — the same shape, and it keeps the behaviour it shipped with.
        //   · `signedOut` — the ticket carries `ownerUid`, so the next sign-in is the retry.
        // Anything not named here keeps its ticket, which is the safe direction: a kept ticket is
        // at worst one repeated alert, a torn-up one is a lost post.
        // Pattern-matched rather than compared: `PostRefusal` declares no `Equatable` conformance,
        // and `if case` needs none.
        if let refusal = error as? PostRefusal {
            if case .glowAudienceEmpty = refusal { return true }
            return false
        }
        let ns = error as NSError
        // The gRPC status codes, by number rather than through the SDK's enum: these are the wire
        // values and they do not move, where the Swift enum has been renamed and re-nested more than
        // once across Firebase versions. 3 invalidArgument · 7 permissionDenied · 9 failedPrecondition
        // · 16 unauthenticated — every one of them a "no" that will be a "no" again tomorrow.
        if ns.domain == FirestoreErrorDomain { return [3, 7, 9, 16].contains(ns.code) }
        // Storage: -13021 is unauthorized, its own equivalent of a rule refusal.
        if ns.domain == StorageErrorDomain { return ns.code == -13021 }
        return false
    }

    /// 2026-09-24 decision D20: an open viewer listens to the story on screen, and `onGone` runs
    /// when it is deleted or I can no longer read it (audience changed, blocked). Returns the stop.
    ///
    /// ⚠️ A PERMISSION ERROR ON `stories/{id}` IS NOT YET "GONE". An "Everyone" story reached from a
    /// profile is read through the author's `publicStories` mirror, and `stories/{id}` refuses a
    /// stranger by design. So a refusal moves the watch to the mirror, which answers for itself:
    /// missing, or refused (the author blocked me), is gone.
    ///
    /// Cache snapshots are ignored: a document the cache has never held reads as missing offline.
    /// Firestore delivers these callbacks on the main queue, which is where the box is touched.
    func watchStoryGone(_ storyId: String, authorUid: String,
                        onGone: @escaping @MainActor () -> Void) -> () -> Void {
        final class Box {
            var reg: ListenerRegistration?; var stopped = false; var fired = false
            var swapObserver: NSObjectProtocol?
        }
        let box = Box()
        let gone: () -> Void = {
            guard !box.stopped, !box.fired else { return }
            box.fired = true
            Task { @MainActor in onGone() }
        }
        let denied: (Error) -> Bool = { e in
            let ns = e as NSError
            return ns.domain == FirestoreErrorDomain && ns.code == 7
        }
        // Both references built at attach time, from the client in use then (see the swap below).
        func attach() {
            let db = FirestoreHub.db
            let mirror = db.collection("users").document(authorUid)
                .collection("publicStories").document(storyId)
            box.reg = db.collection("stories").document(storyId).addSnapshotListener { snap, error in
                guard !box.stopped else { return }
                if let error {
                    guard denied(error) else { return }
                    box.reg?.remove()
                    box.reg = mirror.addSnapshotListener { snap, error in
                        if let error { if denied(error) { gone() }; return }
                        guard let snap, !snap.metadata.isFromCache else { return }
                        if !snap.exists { gone() }
                    }
                    return
                }
                guard let snap, !snap.metadata.isFromCache else { return }
                if !snap.exists { gone() }
            }
        }
        attach()
        // 2026-10-20 (owner): after `FirestoreHub.swap` the watch belongs to the stuck client. Let go
        // of it off-main and watch again on the fresh one. Removed by the stop below.
        box.swapObserver = NotificationCenter.default.addObserver(
            forName: FirestoreHub.swapped, object: nil, queue: .main) { _ in
            guard !box.stopped else { return }
            FirestoreHub.drop([box.reg])
            box.reg = nil
            attach()
        }
        return {
            box.stopped = true
            box.reg?.remove()
            box.reg = nil
            if let o = box.swapObserver { NotificationCenter.default.removeObserver(o) }
            box.swapObserver = nil
        }
    }

    /// What to SAY about it. "Missing or insufficient permissions" is Firestore describing a rule to
    /// another program; on this screen it is the only thing standing between somebody and an answer.
    /// The one rule a story create can realistically break is the hourly cap, so that is what it is
    /// reported as.
    static func friendlyPostError(_ error: Error) -> String {
        // ⛔ OUR OWN REFUSALS ALREADY CARRY THEIR OWN SENTENCE, and they have to be answered before
        // the guard below or one of them comes out wearing somebody else's.
        //
        // The guard reads "not permanent → its own description", which was true of every
        // `PostRefusal` until `glowAudienceEmpty` became permanent — and a permanent one now falls
        // THROUGH into the block beneath, which exists to explain a RULES refusal and reports the
        // daily or hourly story ceiling. So "you have no Glows yet" would have been announced as
        // "you've posted 30 stories today". The two changes have to travel together; see
        // `isPermanentPostFailure`.
        if let refusal = error as? PostRefusal {
            return refusal.errorDescription ?? refusal.localizedDescription
        }
        guard isPermanentPostFailure(error) else { return error.localizedDescription }
        // ⚠️ WHICH CEILING REFUSED IT — the day's or the hour's. A rules refusal is opaque:
        // permission-denied says no and never why. But the counters are ours to read, and the app
        // has already read the daily one, so the sentence can be the true one instead of a guess.
        //
        // The day is tested first because it is the longer window: if the day is spent, "wait a
        // little" is a lie that has him back here in ten minutes to be refused again.
        // ⛔ IS THE FEATURE OFF AT ALL, asked first, because it is the only one of these that is not
        // about this person. `composeStory` catches it at the tap and this catches everything that
        // gets past there: a build that predates the switch, a phone whose listener had not answered
        // when the button was pressed, or the switch being thrown mid-upload.
        guard AppLimits.shared.storiesEnabled else { return AppLimits.storiesOffMessage }
        let budget = StoriesService.shared
        if budget.dailyLimitReached {
            return "You've posted \(dailyStoryLimit) stories today, which is the daily limit. "
                 + "You can post again in about \(budget.dailyLimitHoursLeft) hours."
        }
        // The day is not spent, so the hour is what refused it — that is the reasoning above, and it
        // is why the number can be named. It is read from the same place the rule reads its own, so
        // the sentence cannot go stale when the ceiling is raised on the server.
        // owner 2026-10-23: "says 40 an hour, I posted 3". A rules refusal does not say which rule,
        // and this used to name the hour whatever refused it (his group story; counters read 3/40).
        // The sentence now names both honest possibilities, and the real error goes to the log.
        DiagLog.add("STORYPOST# refused \((error as NSError).domain) \((error as NSError).code) \(error.localizedDescription.prefix(160))")
        DiagLog.flagForUpload()
        return "This story couldn't be posted. If you've posted a lot in the last hour (the limit is "
             + "\(AppLimits.shared.storiesPerHour)), wait a little and try again."
    }

    enum PostRefusal: LocalizedError {
        case audienceUnavailable
        /// The edit would take a story people are currently watching down to no audience at all.
        case audienceEmpty
        /// Somebody else's story, or nobody's — the session went away mid-sheet.
        case notMine
        /// A one-time story's audience is spent as it is watched; see `updateStoryAudience`.
        case oneTimeAudienceFrozen
        /// A Glowers post whose glow relationship is empty. Refused rather than broadcast — see
        /// `StoryAudienceTag.emptyMeansNobody`.
        case glowAudienceEmpty
        /// A Glowers post attempted before the glow listeners have landed. Distinct from the case
        /// above because the two need different words: one is "you have nobody yet", the other is
        /// "we do not know yet", and telling somebody they have no glows when the answer simply has
        /// not arrived is a lie the app would tell on every cold launch.
        case glowAudienceUnknown
        /// ⚠️ NOBODY IS SIGNED IN, AND THIS HAS TO BE A REFUSAL RATHER THAN A QUIET RETURN. The post
        /// paths used to `return` here, and a plain return IS SUCCESS to the caller: the background
        /// poster took its success branch, tore up the outbox ticket, and left `uploadError` nil. A
        /// post queued behind another one while the person signed out therefore evaporated along
        /// with the only record that could have brought it back.
        case signedOut
        /// A group story for a group I am no longer allowed to post in (owner 2026-10-23).
        case groupNotAllowed
        case groupStoryFixed
        var errorDescription: String? {
            switch self {
            case .audienceUnavailable:
                "Couldn't load your chats, so this story would reach nobody. Check your connection and try again."
            case .audienceEmpty:
                "Nobody in that list can see this story any more. Pick another audience."
            case .notMine:
                "You're not signed in to the account that posted this story."
            case .oneTimeAudienceFrozen:
                "A one-time story keeps the audience it was sent to."
            case .glowAudienceEmpty:
                "You don't have any Glows yet, so this story would reach nobody. Pick another audience."
            case .glowAudienceUnknown:
                "Couldn't load your Glows, so this story would reach nobody. Check your connection and try again."
            case .signedOut:
                "You're logged out, so this story wasn't posted. Log in and try again."
            case .groupNotAllowed:
                "You can't post stories in this group any more."
            case .groupStoryFixed:
                "A group story is always seen by the group's members."
            }
        }
    }

    /// A GROUP STORY GOES TO THE GROUP'S MEMBERS AS THE SERVER HAS THEM, read fresh rather than from
    /// the chat list, so somebody removed a minute ago is not in it. Refused here when I may no longer
    /// post, which the rules refuse anyway (`groupStoryOK`). EVERY member, however many (owner
    /// 2026-10-23: "2,000 members, all 2,000"): the rules cap a group story by its group's size, not
    /// 1000, and 2,000 tokens are ~130 KB of the document's 1 MB.
    func groupStoryAudience(me: String, groupId: String) async throws -> Set<String> {
        let snap = try await db.collection("conversations").document(groupId).getDocument(source: .server)
        guard let c = snap.data().map({ Conversation(id: snap.documentID, data: $0) }),
              GroupStoryRights.canPost(c, me) else { throw PostRefusal.groupNotAllowed }
        let blocked = await MainActor.run { Set(BlockList.snapshot.entries.keys) }
        return Set(c.users.filter { $0 != me && !blocked.contains($0) })
    }

    /// What a group story adds to its document: which group, and the name and photo its members' row
    /// shows when their chat list has not caught up. Never public. Empty for every other story.
    static func groupStoryFields(_ tag: StoryAudienceTag) async -> [String: Any] {
        guard let gid = tag.groupId else { return [:] }
        let photo = await MainActor.run { () -> String in
            let me = AuthService.shared.uid ?? ""
            return ConversationsRepository.shared.conversations.first { $0.id == gid }?.displayPhoto(me) ?? ""
        }
        // posterCountry: which country's group-story minimum applies (rules `groupStoryMin`).
        return ["groupId": gid, "groupName": String(tag.name.prefix(128)), "groupPhoto": photo, "public": false,
                "posterCountry": (Locale.current.region?.identifier ?? "").uppercased()]
    }

    /// `applyHiddenFrom` is TRUE only for an Everyone post. The hide list is Everyone's own — see
    /// `StoryAudience.appliesGlobalHide`. It used to be subtracted from the pool for every audience,
    /// which is the upload-time half of the leak the sheet had: hiding somebody from the crowd also
    /// removed them from a My Friends post they belonged in.
    private func resolveAudience(me: String, excluded: Set<String>, included: Set<String>,
                                 applyHiddenFrom: Bool,
                                 tag: StoryAudienceTag) async throws -> (Set<String>, String) {
        if let gid = tag.groupId { return (try await groupStoryAudience(me: me, groupId: gid), "group") }
        // ⛔ AN AUDIENCE THAT IS ITS OWN LIST MUST NOT FALL THROUGH TO THE POOL. The three lines at
        // the bottom of this function read a non-empty `included` first, a non-empty `excluded`
        // second, and otherwise hand back everybody — so a Glowers post that resolved to nothing was
        // delivered to the author's entire chat list while still labelled Glowers, with
        // `recipientUids` pinned immutable afterwards. The whole reasoning, and the three routes
        // that reached it, are on `StoryAudienceTag.emptyMeansNobody`.
        //
        // ⚠️ TWO REFUSALS, NOT ONE, AND THE ORDER MATTERS. "We have not loaded your glows yet" is
        // not "you have no glows", and the loaded flag is the only thing that can tell them apart.
        // Asked first, so a cold launch never tells somebody their glow list is empty when the
        // answer simply has not arrived — which is the case `GlowService.hasLoaded` was written for
        // and which, until now, had ZERO callers anywhere in the app.
        if tag.emptyMeansNobody && included.isEmpty {
            let loaded = await MainActor.run { GlowService.shared.hasLoaded }
            throw loaded ? PostRefusal.glowAudienceEmpty : PostRefusal.glowAudienceUnknown
        }
        // BLOCKING IS SYMMETRIC FOR BROADCAST CONTENT, and it was not.
        //
        // This filtered `isBlockedByMe` — chats where I blocked THEM — and never asked the other
        // question. `blockedBy` is a map keyed by whoever did the blocking, so somebody who blocked
        // ME was still in my audience and my stories kept arriving in their tray. Every other
        // messenger treats a block as ending the broadcast in both directions.
        // ⚠️ WAIT FOR THE CHAT LIST BEFORE ASKING IT WHO YOUR FRIENDS ARE.
        //
        // This read the array straight out, and the array is filled by a snapshot listener with no
        // synchronous seed. Post in the first moment after a cold launch — which is exactly when
        // somebody opens the app to post — and `conversations` is still empty, so `pool` is empty,
        // `recipients` comes back as the empty set, and `postStory` accepts that on purpose
        // ("Empty recipients is OK"). The story uploads, appears on your own row with a normal
        // ring, and reaches NOBODY. There is no error and no repair: `recipientUids` is pinned
        // immutable by the update rule, so the only cure is delete and post again, which requires
        // knowing it happened at all.
        //
        // `hasLoaded` is the same flag the chat list uses to stop showing its skeleton, and it is
        // guaranteed to flip: the repository sets it after 3s whether or not a snapshot arrived. So
        // the wait is bounded by the repository's own promise, and the cap below is only a belt
        // against that promise being changed later. Ten ticks of 0.5s reads as instant on a warm
        // launch, because the flag is already true and the loop never runs once.
        for _ in 0..<10 {
            if await MainActor.run(body: { ConversationsRepository.shared.hasLoaded }) { break }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        // ⚠️ AND `hasLoaded` IS NOT PROOF THAT A LIST ARRIVED, WHICH IS THE HOLE THE LOOP ABOVE LEFT
        // OPEN. The repository raises it after 3 seconds "whether or not a snapshot arrived"
        // (`ConversationsRepository.start`), precisely so the chat list's skeleton can never spin for
        // ever — so offline, or on a blocked realtime channel, the wait ends with an EMPTY list and
        // every branch below resolves an empty audience. The story then uploads, wears a normal ring
        // on his own row, and reaches nobody; `recipientUids` is pinned immutable by the rules, so
        // there is no repair and nothing tells him.
        //
        // The account's own history is what separates the two empties, and the repository already
        // keeps that answer for its own skeleton: `expectsChats` is the per-uid "this account has
        // shown a non-empty chat list on this device before" flag, written the first time a real list
        // lands and never cleared. So:
        //   · no history + empty list  = a genuinely new account, which is the case the "empty
        //     recipients is OK" rule was written for. Allowed, unchanged.
        //   · history + empty list     = the list did not load. Refused, with a message.
        // Both readings of "empty" used to take the first branch, which is why this could only ever
        // be found by somebody noticing that a story had gone a whole day with no views.
        let listMissing = await MainActor.run {
            ConversationsRepository.shared.conversations.isEmpty
                && ConversationsRepository.shared.expectsChats
        }
        if listMissing { throw PostRefusal.audienceUnavailable }
        let allContacts = await MainActor.run {
            Set(ConversationsRepository.shared.conversations
                .filter { c in
                    // Never a demo chat (2026-09-24 audit): with "Demo chats" on, a post pinned
                    // "demo-hooyo" and the rest into the immutable `recipientUids`.
                    guard !c.isGroup, !DemoMode.isDemoConversation(c.id) else { return false }
                    // Not an unanswered message request, in either direction (owner 2026-10-12).
                    guard !MessageRequests.isUnansweredRequest(c) else { return false }
                    let them = c.otherUid(me)
                    return !c.isBlockedByMe(me) && !c.isBlockedByMe(them) && !them.isEmpty
                }
                .map { $0.otherUid(me) })
        }
        // The global hide list, applied here as well as at the picker. This function is the one
        // place that resolves an audience against the LIVE chat list at upload time, so a story
        // queued before somebody was hidden must not reach them when it finally goes up.
        let hidden = applyHiddenFrom ? await MainActor.run { StoryAudienceStore.shared.hiddenFrom }
                                     : Set<String>()
        let pool = allContacts.subtracting(hidden)
        // ⚠️ AN EXPLICIT LIST IS NOT FILTERED BY THE HIDE LIST — `allContacts`, not `pool`. This is
        // the upload-time half of the same rule `StoryAudienceStore.recipients` carries, and the two
        // must agree or the sheet promises an audience the post does not deliver. Naming somebody
        // beats a standing rule about crowds; a block still beats everything, and blocks are already
        // out of `allContacts` in both directions.
        // ⛔ A GLOW IS A REACH OF ITS OWN — his Glow feature, 2026-09-02. Every audience above ends
        // up inside `allContacts` because every one of them describes people you have a chat with.
        // Glow exists precisely so two people who have NEVER chatted can reach each other, so an
        // explicitly included person who is in the glow relationship has to survive this line.
        //
        // ⚠️ WITHOUT THIS, A GLOWERS STORY IS THE SILENT-EMPTY BUG THIS FUNCTION ALREADY DOCUMENTS
        // TWICE: the intersection would drop exactly the people the audience was built for, an
        // empty recipient set is an ACCEPTED post ("Empty recipients is OK"), and the story would
        // upload, wear a normal ring on his own row, and reach nobody — with `recipientUids` pinned
        // immutable so there is no repair and nothing to tell him.
        //
        // ⚠️ BLOCKS STILL BEAT IT, IN BOTH DIRECTIONS. `allContacts` has blocked people filtered
        // out already; the glow set has not, because a glow needs no conversation and therefore has
        // no block record on one. So the block map is read separately here and subtracted — a glow
        // must not become the way around a block.
        let blockedEither = await MainActor.run {
            Set(ConversationsRepository.shared.conversations
                .filter { c in
                    // Never a demo chat (2026-09-24 audit): with "Demo chats" on, a post pinned
                    // "demo-hooyo" and the rest into the immutable `recipientUids`.
                    guard !c.isGroup, !DemoMode.isDemoConversation(c.id) else { return false }
                    let them = c.otherUid(me)
                    return !them.isEmpty && (c.isBlockedByMe(me) || c.isBlockedByMe(them))
                }
                .map { $0.otherUid(me) })
                // 2026-09-26 block rebuild: a glow needs no chat, and neither does a block now.
                .union(BlockList.snapshot.entries.keys)
        }
        let glowReach = await MainActor.run { GlowService.shared.realGlowRelationship }
            .subtracting(blockedEither)
        if !included.isEmpty { return (included.intersection(allContacts.union(glowReach)), "only") }
        if !excluded.isEmpty { return (pool.subtracting(excluded), "except") }
        return (pool, "all")
    }


    /// THE PUBLIC FACE OF AN "EVERYONE" STORY — media only, never the audience.
    ///
    /// The story document itself is no longer readable by strangers, because it carries
    /// `recipientUids` and a Firestore rule cannot grant a document while hiding one field of it. So
    /// one read of one public story used to hand over the author's whole contact list. This mirror
    /// is what a stranger reaching the profile actually reads: the picture, the caption, when it
    /// expires, and nothing about who else can see it.
    ///
    /// Written only for `public` stories, and only once the media URL is known — a mirror pointing
    /// at an empty url is a black card on somebody else's profile.
    ///
    /// ⚠️ `createdAt` IS PASSED IN WHEN THE STORY ALREADY EXISTS, and leaving it out is not a detail.
    /// This is a `setData`, so re-writing a mirror for a story whose audience has just been changed
    /// would stamp it with `serverTimestamp()` all over again — the mirror would claim to have been
    /// posted at the moment the author changed its audience, and a story that is an hour old would
    /// appear on the profile as brand new. A post has no document yet and keeps the server's clock.
    private func writePublicMirror(storyId: String, me: String, mediaUrl: String, thumbUrl: String,
                                   blurThumb: String = "", stickers: [StoryTapTarget] = [],
                                   type: String, caption: String, duration: Double,
                                   expiresAt: Date, allowsReplies: Bool,
                                   captureProtected: Bool = false,
                                   // The credit line has to reach the mirror too, or a stranger
                                   // finding a repost on a profile reads it as an original.
                                   repostOf: StoryRepost? = nil,
                                   createdAt: Date? = nil) async {
        // Built as a variable for the same reason the story document is: a repost adds one key and
        // an ordinary post must not carry it AT ALL. `FieldValue.delete()` is not a way to leave a
        // key out of a `setData` — it throws, and the throw is an Objective-C exception from inside
        // Firestore's validation that `try?` cannot catch. See the note on the story write.
        var mirror: [String: Any] = [
                "authorUid": me,
                "createdAt": createdAt.map { Timestamp(date: $0) } ?? FieldValue.serverTimestamp(),
                "expiresAt": Timestamp(date: expiresAt),
                "mediaUrl": mediaUrl,
                "thumbUrl": thumbUrl,
                // THE COVER TRAVELS WITH THE MIRROR TOO. `parse` reads the same field names for both
                // collections, so leaving it out was a stranger opening a public video story onto
                // nothing while a friend opening the very same story got a picture. See
                // `blurThumbBase64`.
                "blurThumb": blurThumb,
                // ⚠️ THE KEY MUST BE ON THE RULE'S `hasOnly` LIST OR THIS WHOLE WRITE FAILS, and it
                // fails silently — `try?` above swallows it and the story simply stops appearing on
                // its author's public profile. That is exactly what `blurThumb` cost once already;
                // `firestore.rules` names both.
                "stickers": stickers.map(\.asDictionary),
                "type": type,
                "caption": caption,
                "duration": duration,
                "allowsReplies": allowsReplies,
                // ⚠️ AND THIS KEY IS ON THE RULE'S `hasOnly` LIST TOO. Left off, the mirror either
                // fails silently or publishes the story to strangers with the author's protection
                // stripped off it, which is the worse of the two.
                "captureProtected": captureProtected,
        ]
        if let repostOf { mirror["repostOf"] = repostOf.asData }
        try? await db.collection("users").document(me)
            .collection("publicStories").document(storyId)
            .setData(mirror)
    }

    /// ⛔ COUNT THIS POST AGAINST THE HOUR'S ALLOWANCE. See the rate limit in `firestore.rules`.
    ///
    /// The counter is one document, `users/{me}/limits/stories`, holding the window it is counting
    /// and how many have gone inside it. Its own write rules are where the teeth are — a window can
    /// only be opened once the last one has genuinely expired, and inside a window the count may only
    /// go up by one — so this cannot lower it, reset it, or move the window forward to escape a full
    /// one. All it can do is the honest thing.
    ///
    /// ⚠️ BEST EFFORT, ALWAYS, AND THE FAILURE DIRECTION IS DELIBERATE. Every write here is `try?`:
    /// a bump that does not land leaves the count LOWER than the truth, and the create rule treats a
    /// low or missing count as allowed. So a network blip can never turn into a person who cannot
    /// post — which is the only outcome worth being careful about, since the limit exists to stop a
    /// runaway loop rather than to police a person.
    ///
    /// The window is read against `ServerClock`, not the phone's own, for the same reason expiry is.
    /// ⛔ THE DAY'S ALLOWANCE, HELD WHERE A BUTTON CAN ASK IT WITHOUT WAITING.
    ///
    /// The rules are the enforcement and always will be; this is so the app can say no BEFORE the
    /// picker opens (owner, 2026-08-20: "as soon as the user taps Add Story … do not open the media
    /// picker"). Finding out after choosing twenty photos and pressing Upload is the version of this
    /// that wastes the most of somebody's time.
    ///
    /// ⛔ IT IS NOT A CONSTANT ANY MORE — the owner sets it on the server (2026-08-21). 50 a day,
    /// 100 with a badge, until `config/limits` says otherwise. See AppLimits.swift for the whole
    /// arrangement and why it is shaped the way the reference app shapes it.
    ///
    /// ⚠️ STILL MUST MATCH `firestore.rules`, which now means the FALLBACKS must match: both halves
    /// read the same document, but each carries its own copy of the numbers to use before that
    /// document exists. A rule cannot read Swift. If those two sets drift, the app refuses at a
    /// different point than the database does.
    static var dailyStoryLimit: Int { AppLimits.shared.storiesPerDay }

    private(set) var dailyStoriesUsed = 0
    private(set) var dailyWindowStart: Date?

    /// ⚠️ FAILS OPEN, exactly like the rule. An unknown window — never loaded, never posted, no
    /// connection — is not a full one, and a person who cannot be counted must still be able to
    /// post. The database is what actually holds the line.
    var dailyLimitReached: Bool {
        guard let start = dailyWindowStart,
              ServerClock.now.timeIntervalSince(start) <= 86_400 else { return false }
        return dailyStoriesUsed >= Self.dailyStoryLimit
    }

    /// Whole hours until the window rolls, for the sentence shown when it is full. At least one, so
    /// it never says "in 0 hours".
    var dailyLimitHoursLeft: Int {
        guard let start = dailyWindowStart else { return 0 }
        let left = 86_400 - ServerClock.now.timeIntervalSince(start)
        return max(1, Int(ceil(left / 3600)))
    }

    /// Read the day's counter. Cheap, one document, and worth doing whenever the story row appears
    /// so the button's answer is already in hand when it is pressed.
    func refreshDailyBudget() async {
        let me = uid
        guard !me.isEmpty else { return }
        let snap = try? await db.collection("users").document(me)
            .collection("limits").document("storiesDaily").getDocument()
        let data = snap?.data()
        let started = (data?["windowStart"] as? Timestamp)?.dateValue()
        await MainActor.run {
            self.dailyWindowStart = started
            self.dailyStoriesUsed = (data?["count"] as? NSNumber)?.intValue ?? 0
        }
    }

    private func countStoryAgainstBudget() async {
        let me = uid
        guard !me.isEmpty else { return }
        // ⛔ TWO COUNTERS, AND THEY ANSWER DIFFERENT QUESTIONS. The hour bounds how FAST stories
        // can go out; the day bounds how MANY. Forty an hour is nine hundred and sixty a day, so an
        // account posting steadily under the hourly ceiling never meets a limit at all — which is
        // why the second one exists (owner, 2026-08-20). Both are enforced in `firestore.rules`;
        // these writes only keep the count honest.
        await bumpBudget("stories", window: 3600)
        await bumpBudget("storiesDaily", window: 86_400)
    }

    /// One counter's window and count. `name` and `window` must match the pair in the rules, which
    /// derive the window from the document's own name.
    private func bumpBudget(_ name: String, window: TimeInterval) async {
        let me = uid
        guard !me.isEmpty else { return }
        let ref = db.collection("users").document(me).collection("limits").document(name)
        let opened = ((try? await ref.getDocument())?.data()?["windowStart"] as? Timestamp)?.dateValue()
        // A window that has run out is replaced whole; one that is still open takes one more.
        // `increment` rather than a read-modify-write, so two posts a second apart cannot both write
        // the same number.
        let inWindow = opened.map { ServerClock.now.timeIntervalSince($0) <= window } ?? false
        if inWindow {
            try? await ref.updateData(["count": FieldValue.increment(Int64(1))])
        } else {
            try? await ref.setData(["windowStart": FieldValue.serverTimestamp(), "count": 1])
        }
        // The cached answer moves with the write, so the fiftieth post closes the button without
        // waiting for anything to be read back. `refreshDailyBudget` corrects it from the server
        // whenever the row appears; this only keeps it from lagging a whole sitting behind.
        guard name == "storiesDaily" else { return }
        let start = inWindow ? opened : ServerClock.now
        let used = inWindow ? dailyStoriesUsed + 1 : 1
        await MainActor.run {
            self.dailyWindowStart = start
            self.dailyStoriesUsed = used
        }
    }

    /// The mirror goes when the story does. Harmless if there never was one.
    /// ⛔ IT THROWS NOW, AND THE ONE CALLER THAT CAN ACT ON IT DOES.
    ///
    /// This swallowed its own failure with `try?`. The mirror is the copy a STRANGER reads off the
    /// author's profile, so a dropped request here — offline, a blip — left the story playing in
    /// public while the story itself was deleted everywhere else, with nothing to notice it and
    /// nothing to retry it. A delete that only mostly deletes is the one kind this feature cannot
    /// have.
    ///
    /// Deleting a document that does not exist SUCCEEDS in Firestore, so this is safe to call for a
    /// story that never had a mirror, which is most of them.
    private func deletePublicMirror(storyId: String, authorUid: String) async throws {
        try await db.collection("users").document(authorUid)
            .collection("publicStories").document(storyId).delete()
    }

    // Post a photo to "My Status": chosen audience can see it for 24h.
    func postStory(image: Data, caption: String = "", stickers: [StoryTapTarget] = [], expiryHours: Double = 24,
                   excluded: Set<String> = [], included: Set<String> = [], everyone: Bool = false, allowsReplies: Bool = true, tag: StoryAudienceTag = .friends,
                   captureProtected: Bool = false,
                   repostOf: StoryRepost? = nil,
                   storyId fixedId: String? = nil, replaceExisting: Bool = false) async throws {
        let me = uid
        // A quiet `return` here read as SUCCESS to the background poster — see `PostRefusal.signedOut`.
        guard !me.isEmpty else { throw PostRefusal.signedOut }
        try Task.checkCancellation()   // bail before any write if the user already cancelled
        // ⚠️ COUNTED ALONGSIDE THE POST, NEVER IN FRONT OF IT. This is a read and a write against a
        // document nobody is waiting for, and awaiting it would put a whole round trip between his
        // tap and the first byte of his photograph — on the one path in this feature where he has
        // complained about delay more than any other.
        //
        // The cost of not waiting is that a burst can be counted a little late, and the create rule
        // then reads a number lower than the truth. That direction is already the designed one: the
        // limit exists to stop a runaway loop, and it fails open everywhere else for the same reason.
        Task.detached { [weak self] in await self?.countStoryAgainstBudget() }
        var postId = fixedId ?? Self.newStoryId()
        // ⛔ A RESUMED POST TAKES BACK ITS OWN HALF-WRITTEN STORY (outbox, 2026-10-12). The id was
        // fixed when the ticket was made, so a post the app died in the middle of may already have
        // its document here with an empty `mediaUrl`. Deleting it first (the author may delete
        // their own story) leaves no orphan behind.
        // ⚠️ AND THE NEW POST TAKES A NEW ID (audit H2, 2026-10-23). Under the same id the server's
        // onStoryDeleted for the old doc ran late and deleted `stories/<id>/photo.jpg`, which by then
        // was the NEW upload: a story broken for 24 hours. The outbox tracks its slot, not this id.
        if replaceExisting {
            try? await db.collection("stories").document(postId).delete()
            postId = Self.newStoryId()
        }
        let storyId = postId
        let path = "stories/\(storyId)/photo.jpg"   // {storyId}/ segment so Storage rules can audience-scope reads

        // THE PHOTO STARTS MOVING FIRST. Everything below used to be strictly serial — resolve the
        // audience, write the story doc, compress, and only THEN send the first byte — so two full
        // network round trips sat in front of the slowest step in the whole operation.
        //
        // The justification for that order was written in a comment here: "the Storage READ rule for
        // downloadURL() checks this doc's authorUid, so it must exist before we resolve the URL". THAT
        // IS NO LONGER TRUE, and storage.rules says so in as many words: "Writes happen at upload time
        // (before the story doc exists), so write is just auth + size + type", and read is now plain
        // `request.auth != null` with no Firestore lookup at all. The rule was relaxed because the
        // audience check was denying the AUTHOR's own getDownloadURL; the ordering here was never
        // updated to match, so the code kept paying for a constraint that had been removed.
        //
        // The UPLOAD now runs CONCURRENTLY with the audience resolve and the doc write, so the chain
        // is as long as its slowest branch rather than the sum of both. (Compression used to be in
        // that branch too; see the note on the hoist just below.)
        let docRef = db.collection("stories").document(storyId)
        let ref = Storage.storage().reference().child(path)

        // Decoding, resizing and re-encoding a 12MP photo is real work, and it belongs BEFORE the doc
        // write rather than after it. HOISTED OUT of the `async let` below on purpose: the phase flip
        // has to happen the instant this returns, and doing that from inside a `@Sendable` closure
        // would mean capturing `self` there. The cost is that ~0.3s of CPU no longer overlaps the
        // audience resolve, which is a local main-actor hop — nothing worth capturing a class for.
        // ONE ENCODE, DONE IN THE COMPOSER. This was `ChatService.downscaledJPEG(image)`, a second
        // lossy pass that also capped the frame at 1600px. See `StoryPhoto`.
        let jpeg = StoryPhoto.ensureWithinBudget(image)
        // THE PHONE'S HALF IS OVER. Everything past this line is the network, and this person's own
        // copy is already complete — so the ring comes down here, not at the end.
        await markSending()

        // ⚠️ THE AUDIENCE IS RESOLVED BEFORE THE FIRST BYTE MOVES, AND THE ORDER IS DELIBERATE.
        //
        // It used to sit AFTER the `async let` below, so the two overlapped. That was free while this
        // could not fail — and it can now: an account whose chat list did not load is refused here
        // rather than posting to nobody (see `resolveAudience`). A throw from inside the overlap
        // escapes BEFORE the `do`/`catch` that cleans Storage up, so the refusal would have left the
        // uploaded bytes behind with no document to own them, and nothing ever deletes an orphan.
        //
        // What the old order bought was one main-actor hop of overlap on the warm path (the wait loop
        // does not run when the list is already there), which is not worth an orphaned file.
        let recipients: Set<String>, mode: String
        do {
            (recipients, mode) = try await resolveAudience(me: me, excluded: excluded, included: included,
                                                           applyHiddenFrom: everyone, tag: tag)
        } catch {
            DiagLog.add("STORYPOST# step=audience gid=\(tag.groupId ?? "-") \((error as NSError).domain) \((error as NSError).code)")
            throw error
        }
        // Which write a refusal came from (owner 2026-10-23: group story refused, the rules replay passes).
        var step = "create"

        // An unchanged repost is copied on the server after the doc exists (see `serverCopySource`);
        // only if that copy fails are the bytes sent from here.
        let copyFrom = Self.serverCopySource(repostOf)
        async let uploadedJPEG: Void = {
            guard copyFrom == nil else { return }
            try Task.checkCancellation()
            let meta = StorageMetadata(); meta.contentType = "image/jpeg"
            _ = try await ref.putDataAsync(jpeg, metadata: meta)
        }()
        // Made once and used twice — the document and, for an "Everyone" story, the public mirror.
        // It is a resize and a JPEG encode, so asking for it twice is real work for one string.
        let cover = Self.blurThumbBase64(image)
        // ⚠️ ONE DEADLINE, EVALUATED ONCE. The mirror used to compute its own `Date()` AFTER the
        // upload finished, so it was stamped to die later than the story it mirrors — by exactly
        // however long the transfer took. On a slow connection that is minutes of a story that has
        // expired everywhere except on the author's public profile.
        let expiresAt = Date().addingTimeInterval(expiryHours * 3600)

        // Empty recipients is OK: it's still MY OWN story (the `mine` query loads by authorUid, so I
        // always see it) — just with no other viewers yet (e.g. a brand-new account with no contacts).
        // The audience sheet already warns when you HAVE contacts but narrowed the audience to none, so
        // reaching here with empty recipients means "own story only", which is valid — don't block it.
        do {
            // ⛔ BUILT AS A VARIABLE SO A REPOST CAN ADD ONE KEY — and `FieldValue.delete()` is NOT
            // how you leave a key out. That was the first version of this and it crashed the app on
            // every single story post, shipped in build 744:
            //
            //     FIRInvalidArgumentException — FieldValue.delete() can only be used with
            //     updateData() and setData() with merge:true
            //
            // This is a plain `setData` (a create), so Firestore validates the dictionary by
            // enumerating it and throws an Objective-C exception from inside the bridge, which is
            // not catchable by `try` and aborts the process. An absent key is an absent key; there
            // is no sentinel for it here.
            var payload: [String: Any] = [
                "authorUid": me,
                "createdAt": FieldValue.serverTimestamp(),
                "expiresAt": Timestamp(date: expiresAt),
                "type": "image",
                "mediaPath": path,
                "mediaUrl": "",
                // THE COVER THAT TRAVELS WITH THE STORY. See `blurThumbBase64`.
                "blurThumb": cover,
                "caption": caption,
                // LINK AND LOCATION STICKERS. Empty for the great majority of stories, and an empty
                // array costs nothing. See `StoryTapTarget` for why the picture cannot carry this.
                "stickers": stickers.map(\.asDictionary),
                "audience": ["mode": everyone ? "everyone" : mode, "listId": "my-story"],
                // THE LABEL, and only the label. See StoryAudienceTag: the custom NAME never comes
                // here, because a recipient reads this document.
                "audienceLabel": tag.label,
                "oneTime": tag.oneTime,
                "captureProtected": captureProtected,
                // Public ("Everyone") stories are viewable by anyone who finds your profile — the
                // read rules gate on this flag. Contacts still get it in their tray via
                // recipientUids below.
                "public": everyone,
                "allowsReplies": allowsReplies,
                "replyCount": 0,
                // ⚠️ TOKENS, NOT UIDS — see `StoryAudienceToken`. The field name stays because the tray's
            // `array-contains` query, the read rule and the Cloud Function all key on it, and a
            // rename would have to land in three places at the same instant.
            "recipientUids": StoryAudienceToken.tokens(recipients),
            ]
            // A repost carries where it came from; an ordinary post carries no such key at all.
            if let repostOf { payload["repostOf"] = repostOf.asData }
            payload.merge(await Self.groupStoryFields(tag)) { _, new in new }
            try await docRef.setData(payload)
            StoryPrefs.rememberAudienceName(storyId: storyId, tag: tag)
            StoryAudienceStore.shared.linkStory(storyId, tag: tag)

            // Both halves were in flight together; wait for the photo to land before asking for its
            // URL. If the doc write above threw, this child task is cancelled and awaited on the way
            // out, and the catch deletes whatever reached Storage.
            step = "upload"
            try await uploadedJPEG   // `jpeg` is already in scope; this only waits for the transfer
            if let copyFrom, !(await copyRepostMedia(from: copyFrom, to: storyId)) {
                let meta = StorageMetadata(); meta.contentType = "image/jpeg"
                _ = try await ref.putDataAsync(jpeg, metadata: meta)
            }
            try Task.checkCancellation()   // cancelled during upload → undo
            step = "url"
            let url = try await ref.downloadURL().absoluteString
            step = "media"
            try await docRef.updateData(["mediaUrl": url])
            // The story is up: tell the people its caption mentions (`StoryMentions`).
            StoryMentions.send(storyId: storyId, caption: caption, thumbUrl: url, recipients: recipients, me: me)
            // The stranger-facing copy, media only. See `writePublicMirror`.
            if everyone {
                await writePublicMirror(storyId: storyId, me: me, mediaUrl: url, thumbUrl: "",
                                        blurThumb: cover, stickers: stickers,
                                        type: "image", caption: caption, duration: 0,
                                        expiresAt: expiresAt,
                                        allowsReplies: allowsReplies,
                                        captureProtected: captureProtected,
                                        repostOf: repostOf)
            }
            // Warm the cache the My Story card reads from (DiskImageCache), so the final card shows the
            // image instantly as the "Uploading…" placeholder morphs into it — no blank-then-fetch.
            if let img = UIImage(data: jpeg) { DiskImageCache.shared.store(img, data: jpeg, for: url) }
            // ALSO warm URLCache — the STORY VIEWER (StoryUI's ImageLoader) reads from URLCache first,
            // NOT DiskImageCache. Without this, opening the just-posted story re-downloaded the image
            // from Storage (~3s of shimmer). The uploaded bytes ARE what the URL returns, so cache them
            // under that URL and the viewer shows it instantly.
            if let u = URL(string: url) {
                let resp = URLResponse(url: u, mimeType: "image/jpeg",
                                       expectedContentLength: jpeg.count, textEncodingName: nil)
                URLCache.shared.storeCachedResponse(CachedURLResponse(response: resp, data: jpeg),
                                                    for: URLRequest(url: u))
            }
        } catch {
            // Undo BOTH halves. Either can have got somewhere before the other failed, now that they
            // run together, so neither cleanup is optional. Storage deletes are `allow delete: if
            // false` for clients, so that one fails harmlessly and onStoryDeleted sweeps the bytes
            // when the doc goes; it stays here so the intent is on the record.
            DiagLog.add("STORYPOST# step=\(step) gid=\(tag.groupId ?? "-") rcpt=\(recipients.count) "
                        + "\((error as NSError).domain) \((error as NSError).code)")
            try? await docRef.delete()
            try? await ref.delete()
            throw error
        }
    }

    // Fire-and-forget VIDEO post — same shape as postStoryBackground. `thumbnail` is the poster
    // frame the editor already generated; it drives the uploading ring/placeholder immediately
    // while the transcode + upload run in the background.
    @MainActor func postVideoStoryBackground(videoURL: URL, thumbnail: Data, muted: Bool = false,
                                             burn: StoryBurnIn? = nil,
                                             trim: ClosedRange<Double>? = nil, caption: String = "",
                                             stickers: [StoryTapTarget] = [],
                                             excluded: Set<String> = [], included: Set<String> = [], everyone: Bool = false, allowsReplies: Bool = true, tag: StoryAudienceTag = .friends,
                                             captureProtected: Bool = false,
                                             repostOf: StoryRepost? = nil,
                                             resumeTicket: String? = nil, storyIds resumeIds: [String]? = nil,
                                             done: Set<String> = []) {
        // ⛔ A VIDEO POST SURVIVES THE APP BEING KILLED (owner, 2026-10-12). The clip, its burn-in and
        // every setting go to `VideoStoryOutbox` before the first byte moves, with one fixed story id
        // per part; a resume comes back here with those ids and the parts already landed.
        let ticketId: String
        let partIds: [String]
        let replaceExisting: Bool
        if let resumeTicket, let resumeIds {
            VideoStoryOutbox.claim(resumeTicket)
            ticketId = resumeTicket; partIds = resumeIds; replaceExisting = true
        } else {
            let r = VideoStoryOutbox.remember(videoURL: videoURL, thumbnail: thumbnail, muted: muted, burn: burn,
                                              trim: trim, caption: caption, stickers: stickers,
                                              excluded: excluded, included: included, everyone: everyone,
                                              allowsReplies: allowsReplies, tag: tag,
                                              captureProtected: captureProtected, repostOf: repostOf,
                                              ownerUid: uid)
            ticketId = r.ticket; partIds = r.storyIds; replaceExisting = false
        }
        // Same queueing as postStoryBackground: never cancel an in-flight post, chain behind it.
        let previous = uploadTask
        let queuedOn = FirestoreHub.generation   // a swap frees this post from the queue (`waitBehind`)
        // Its own entry in the queue, exactly as a photo post takes one — see `PendingUpload`.
        // THE PLACEHOLDER WEARS THE CANVAS THE EXPORT IS ABOUT TO BAKE. His report: "when is
        // uploading it's showing blur, when upload finished it's showing different color… use one is
        // better". The uploading card drew the raw poster, which letterboxes BLACK, while the file
        // that lands carries the gradient — so the story visibly changed colour at the hand-over.
        // Same sampler, same gradient, one function; a 9:16 clip is returned untouched.
        // ...and the burn with it (owner, 2026-10-12): a shrunken or card-shaped clip, and the text
        // and chip over it, show on the placeholder as they will on the posted story.
        let placeholder = UIImage(data: thumbnail).map { VideoTranscoder.storyPlaceholderPoster($0, burn: burn) }
        let pending = PendingUpload(id: "\(Self.uploadingStoryId).\(UUID().uuidString)",
                                    image: placeholder,
                                    url: "https://fariin.local/uploading-\(UUID().uuidString).jpg",
                                    startedAt: Date(),
                                    tag: tag,
                                    caption: caption,
                                    repostOf: repostOf,
                                    docIds: partIds)
        // ⚠️ THE SAME BYTES, or the composed picture above is wasted. StoryUI's ImageLoader reads
        // URLCache FIRST, so seeding the raw poster here would win over `pending.image` and put the
        // black-letterboxed frame back on screen.
        if let u = URL(string: pending.url) {
            // BOTH CACHES — the url is invented, so URLCache evicting it leaves the card with
            // nothing to draw and no server to ask. See `StoryImageSeed`.
            StoryImageSeed.seed(placeholder?.jpegData(compressionQuality: 0.9) ?? thumbnail, for: u)
        }
        inFlight.append(pending)
        refreshUploading()
        uploadPhase = .preparing   // video starts on the phone's half too — and it is the long one
        let token = UUID()
        currentUploadToken = token
        uploadTask = Task {
            await Self.waitBehind(previous, generation: queuedOn)   // chain behind any in-flight post (posts queue, never cancel each other)
            // On a Firestore swap this post starts again from its own ticket, same story ids, as a
            // launch resume would (`leaveStuckPosts`). The parts already landed are written again
            // over themselves (same ids), never twice.
            await self.markRunning(pending.id, photo: false) { [weak self] in
                VideoStoryOutbox.release(ticketId)
                self?.postVideoStoryBackground(videoURL: videoURL, thumbnail: thumbnail, muted: muted, burn: burn,
                                               trim: trim, caption: caption, stickers: stickers,
                                               excluded: excluded, included: included, everyone: everyone,
                                               allowsReplies: allowsReplies, tag: tag,
                                               captureProtected: captureProtected, repostOf: repostOf,
                                               resumeTicket: ticketId, storyIds: partIds, done: done)
            }
            var failure: String?
            var cancelled = false
            do {
                try await postVideoStory(videoURL: videoURL, muted: muted, trim: trim, burn: burn, caption: caption, stickers: stickers, excluded: excluded, included: included, everyone: everyone, allowsReplies: allowsReplies, tag: tag, captureProtected: captureProtected, repostOf: repostOf,
                                         storyIds: partIds, done: done, replaceExisting: replaceExisting,
                                         onPartDone: { VideoStoryOutbox.markDone(ticketId, storyId: $0) })
                if await self.finishRunning(pending.id) { return }   // left behind on a swap: the restart owns it
                VideoStoryOutbox.forget(ticketId)          // it landed; nothing to resume
            }
            catch is CancellationError {
                if await self.finishRunning(pending.id) { return }
                cancelled = true; VideoStoryOutbox.forget(ticketId)
            }
            catch {
                if await self.finishRunning(pending.id) { return }
                failure = Self.friendlyPostError(error)
                // A refusal that will never succeed is dropped; anything else waits for next launch.
                if Self.isPermanentPostFailure(error) { VideoStoryOutbox.forget(ticketId) }
                else { VideoStoryOutbox.release(ticketId) }
            }
            if !cancelled && failure == nil { await StoriesRepository.shared.load(force: true) }
            await MainActor.run {
                self.queuedUploads[pending.id] = nil   // finished or cancelled: nothing left to cancel
                self.inFlight.removeAll { $0.id == pending.id }   // outside the guard — see the photo path
                self.refreshUploading()
                if let failure { self.uploadError = failure }   // any post reports — see the photo path
                guard self.currentUploadToken == token else { return }
                self.uploadTask = nil
            }
        }
        // IN THE CANCEL CHAIN, like the photo path always was. This append was missing here, so
        // with video A uploading and B queued, the X reached only B — A finished and POSTED the
        // thing the user watched themselves cancel. The exact bug the photo path's comment says
        // was fixed once already; it had been re-introduced for video-first chains.
        if let t = uploadTask { queuedUploads[pending.id] = t }
    }

    /// A long video becomes SEVERAL stories, in order, instead of being cut down to the first 90
    /// seconds (owner's spec, 2026-08-04, modelled on another mainstream messenger's status feature). 45s is one story; two minutes is
    /// 90 + 30; five minutes is four. Nothing the user picked is thrown away and they do nothing
    /// extra to get it.
    ///
    /// SEQUENTIAL ON PURPOSE, not parallel. Each story's place in the queue is its `createdAt`, and
    /// the only way to be sure segment 2 sorts after segment 1 is to write it after segment 1. Three
    /// uploads racing would land in whatever order the network felt like, which is a jumbled story.
    ///
    /// A FAILURE DOES NOT RESTART THE WHOLE THING. Each segment retries on its own, twice, and if one
    /// still will not go the error says which — the segments already posted stay posted, because
    /// making somebody re-upload four minutes because the fifth chunk timed out is the opposite of
    /// what this feature is for.
    func postVideoStory(videoURL: URL, muted: Bool = false, trim: ClosedRange<Double>? = nil, burn: StoryBurnIn? = nil,
                        caption: String = "", stickers: [StoryTapTarget] = [], expiryHours: Double = 24,
                        excluded: Set<String> = [], included: Set<String> = [], everyone: Bool = false, allowsReplies: Bool = true, tag: StoryAudienceTag = .friends,
                        captureProtected: Bool = false,
                        repostOf: StoryRepost? = nil,
                        storyIds: [String] = [], done: Set<String> = [], replaceExisting: Bool = false,
                        onPartDone: @escaping (String) -> Void = { _ in }) async throws {
        // Part i posts under storyIds[i] when given (`VideoStoryOutbox`); a part already landed is skipped.
        func partId(_ i: Int) -> String? { i < storyIds.count ? storyIds[i] : nil }
        let full = (try? await AVURLAsset(url: videoURL).load(.duration).seconds) ?? 0
        // A hand trim decides where the material starts and how much of it there is; the split then
        // works on THAT, not on the original file. Trim to 20s and you get one story, not the first
        // 90 seconds of something you already cut.
        let offset = max(0, trim?.lowerBound ?? 0)
        let total = max(0, min(trim?.upperBound ?? full, full) - offset)
        let cap = Double(Limits.storyVideoSeconds)
        guard total > cap + 0.5 else {
            let range = trim.map { _ in
                CMTimeRange(start: CMTime(seconds: offset, preferredTimescale: 600),
                            duration: CMTime(seconds: total, preferredTimescale: 600))
            }
            // Short enough to be one story: the ordinary path, no segmenting, no behaviour change.
            if let id = partId(0), done.contains(id) { return }
            try await postVideoSegment(videoURL: videoURL, range: range, caption: caption, muted: muted, burn: burn,
                                       stickers: stickers,
                                       expiryHours: expiryHours, excluded: excluded,
                                       included: included, everyone: everyone, allowsReplies: allowsReplies, tag: tag,
                                       captureProtected: captureProtected, repostOf: repostOf,
                                       fixedId: partId(0), replaceExisting: replaceExisting)
            if let id = partId(0) { onPartDone(id) }
            return
        }

        let count = Int(ceil(min(total, Double(Limits.storyVideoPickSeconds)) / cap))
        for i in 0..<count {
            try Task.checkCancellation()
            let start = offset + Double(i) * cap
            let len = min(cap, (offset + total) - start)
            guard len > 0.05 else { break }
            if let id = partId(i), done.contains(id) { continue }   // landed before the app died
            let range = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                    duration: CMTime(seconds: len, preferredTimescale: 600))
            // The caption belongs to the story, not to every slice of it: repeating it on all seven
            // reads as a stutter. It rides the FIRST segment, which is the one people see first.
            var lastError: Error?
            for attempt in 0..<3 {
                do {
                    try await postVideoSegment(videoURL: videoURL, range: range,
                                               caption: i == 0 ? caption : "", muted: muted, burn: burn,
                                               // Only the FIRST segment of a long clip keeps them:
                                               // the tap areas were placed against one frame, and a
                                               // 90-second split posts several.
                                               stickers: i == 0 ? stickers : [],
                                               expiryHours: expiryHours, excluded: excluded,
                                               included: included, everyone: everyone, allowsReplies: allowsReplies, tag: tag,
                                               captureProtected: captureProtected, repostOf: repostOf,
                                               fixedId: partId(i),
                                               // A retry of the same part may find its own half-written doc.
                                               replaceExisting: replaceExisting || attempt > 0)
                    if let id = partId(i) { onPartDone(id) }
                    lastError = nil
                    break
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // A refusal stays a refusal (audit 06 F4): no retries, and the real error goes up
                    // so the outbox forgets the post instead of re-sending it on every launch.
                    if Self.isPermanentPostFailure(error) { throw error }
                    lastError = error
                    if attempt < 2 { try? await Task.sleep(nanoseconds: UInt64(1_500_000_000 * (attempt + 1))) }
                }
            }
            if let lastError {
                throw NSError(domain: "Fariin", code: 2, userInfo: [
                    NSLocalizedDescriptionKey:
                        "Part \(i + 1) of \(count) didn't upload. The parts before it were posted — try again to send the rest.",
                    NSUnderlyingErrorKey: lastError,
                ])
            }
        }
    }

    // Post ONE story from a video: transcode to 720p H.264 (optionally just the slice `range`),
    // upload the poster thumb + the mp4, then fill both URLs atomically (the repository skips docs
    // with an empty mediaUrl, so nobody sees a half-uploaded story).
    private func postVideoSegment(videoURL: URL, range: CMTimeRange?, caption: String, muted: Bool, burn: StoryBurnIn? = nil,
                                  stickers: [StoryTapTarget] = [],
                                  expiryHours: Double, excluded: Set<String>, included: Set<String>,
                                  everyone: Bool, allowsReplies: Bool, tag: StoryAudienceTag,
                                  captureProtected: Bool = false,
                                  repostOf: StoryRepost? = nil,
                                  fixedId: String? = nil, replaceExisting: Bool = false) async throws {
        let me = uid
        // A quiet `return` here read as SUCCESS to the background poster — see `PostRefusal.signedOut`.
        guard !me.isEmpty else { throw PostRefusal.signedOut }
        try Task.checkCancellation()

        // Transcode BEFORE creating the doc — a failed/cancelled transcode leaves zero server state.
        // The editor's text, pen and crop ride the SAME export the trim and the 90-second split
        // already use, so a long edited clip is burned in once per segment rather than re-encoded a
        // second time on top of itself.
        // `storyBackdrop`: a square/landscape clip gets a gradient canvas BAKED into the
        // file, so the posted story looks like the editor everywhere. Costs those clips the fast
        // copy path (they re-encode); 9:16 clips are untouched. See `VideoTranscoder.prepare`.
        // ⛔ A REPOST KEEPS ITS QUALITY (owner, 2026-10-12: "reposted video and images lose quality";
        // the reference app re-exports a modified repost at 720x1280 and 3.7-5.8 Mbps). A repost
        // re-encodes a clip that was already compressed once, so it renders at full 1080x1920 and
        // may use ~6 Mbps; ordinary stories keep their sizes. An unedited full-screen repost that
        // already fits is still copied, not re-encoded (the passthrough path).
        let repostQuality = repostOf != nil
        // Bounded by the 25 MB story upload cap in storage.rules: ~6 Mbps, or whatever keeps the
        // segment under ~23 MB, whichever is lower.
        var repostRate: Double? = nil
        if repostQuality {
            let seconds: Double = if let range { range.duration.seconds }
                else { ((try? await AVURLAsset(url: videoURL).load(.duration))?.seconds) ?? Double(Limits.storyVideoSeconds) }
            repostRate = min(750_000, 23_000_000 / max(1, min(seconds, Double(Limits.storyVideoSeconds))))
        }
        guard let prepared = await VideoTranscoder.prepare(videoURL, maxSeconds: Double(Limits.storyVideoSeconds), stripAudio: muted, hd: repostQuality, range: range,
                                                           overlay: burn?.overlay, cropRect: burn?.cropRect,
                                                           canvasAspect: burn?.canvasAspect,
                                                           contentScale: burn?.contentScale ?? 1,
                                                           backdrop: burn?.backdrop,
                                                           storyBackdrop: true,
                                                           brightness: burn?.brightness ?? 0,
                                                           holeCorner: burn?.holeCorner ?? 0,
                                                           bytesPerSecond: repostRate) else {
            throw NSError(domain: "Fariin", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Couldn't process this video"])
        }
        // THE PHONE'S HALF IS OVER — and on video it is the long half. Past here it is upload only,
        // and the clip is already playable from the local file, so the ring must stop. See
        // `uploadPhase`.
        await markSending()
        try Task.checkCancellation()

        Task.detached { [weak self] in await self?.countStoryAgainstBudget() }   // never in front of the post
        var postId = fixedId ?? Self.newStoryId()
        // A resumed or retried part takes back its own half-written story first, and posts under a
        // NEW id (audit H2; see the photo path).
        if replaceExisting {
            try? await db.collection("stories").document(postId).delete()
            postId = Self.newStoryId()
        }
        let storyId = postId
        let videoPath = "stories/\(storyId)/video.mp4"
        let thumbPath = "stories/\(storyId)/thumb.jpg"
        let (recipients, mode) = try await resolveAudience(me: me, excluded: excluded, included: included,
                                                     applyHiddenFrom: everyone, tag: tag)
        // Made once and used twice — the document and, for an "Everyone" story, the public mirror.
        let cover = Self.blurThumbBase64(prepared.thumbnail)
        // ONE DEADLINE, EVALUATED ONCE — see the photo path for what two of them cost.
        let expiresAt = Date().addingTimeInterval(expiryHours * 3600)

        let docRef = db.collection("stories").document(storyId)
        var payload: [String: Any] = [
            "authorUid": me,
            "createdAt": FieldValue.serverTimestamp(),
            "expiresAt": Timestamp(date: expiresAt),
            "type": "video",
            "mediaPath": videoPath,
            "mediaUrl": "",
            "thumbUrl": "",
            // ⚠️ THIS IS THE ONE THAT MATTERS MOST, because a video's `thumbUrl` stays empty until
            // its second upload finishes and can fail on its own. Written with the DOCUMENT, before
            // a single byte of media is uploaded, so a viewer reaching this story at any point after
            // it exists has a picture to show. See `blurThumbBase64`.
            "blurThumb": cover,
            "stickers": stickers.map(\.asDictionary),   // see the photo path and `StoryTapTarget`
            "duration": prepared.duration,
            // ⚠️ THE CLIP'S OWN SHAPE AND SIZE, WHICH THIS DOCUMENT HAS NEVER CARRIED.
            //
            // The reference app ships all of this on the media itself (`w`, `h`, `duration`,
            // `supports_streaming` and a server-computed `preload_prefix_size`), and it is what lets
            // it size a placeholder correctly before a byte arrives and fetch a PREFIX of a
            // neighbour instead of the whole file. Ours discovers the size at runtime from
            // `AVPlayerItem.presentationSize` — which is to say, after the download.
            //
            // Written now even though nothing reads them yet, and that is deliberate rather than
            // sloppy: a story expires in 24 hours, so a field first written on the day the reader
            // ships would have no story to describe. `preloadPrefix` is the byte count worth
            // fetching to start playback — our exports are `shouldOptimizeForNetworkUse`, so the
            // moov atom is at the FRONT and a prefix is genuinely playable. 1.5MB is ~3.5 seconds
            // at the ~3.4 Mbps the encoder produces (512KB was one second; owner 2026-10-12, "video
            // stories take time"), and the whole file when the file is smaller than that.
            "width": prepared.width,
            "height": prepared.height,
            "bytes": prepared.data.count,
            "preloadPrefix": min(prepared.data.count, 1536 * 1024),
            "caption": caption,
            "audience": ["mode": everyone ? "everyone" : mode, "listId": "my-story"],
            // The label only — the custom name stays on this device. See StoryAudienceTag.
            "audienceLabel": tag.label,
            "oneTime": tag.oneTime,
            "captureProtected": captureProtected,
            "public": everyone,
            "allowsReplies": allowsReplies,
            "replyCount": 0,
            // ⚠️ TOKENS, NOT UIDS — see `StoryAudienceToken`. The field name stays because the tray's
            // `array-contains` query, the read rule and the Cloud Function all key on it, and a
            // rename would have to land in three places at the same instant.
            "recipientUids": StoryAudienceToken.tokens(recipients),
        ]
        // A video repost carries its credit exactly as a photo repost does (owner 2026-10-11).
        if let repostOf { payload["repostOf"] = repostOf.asData }
        payload.merge(await Self.groupStoryFields(tag)) { _, new in new }
        try await docRef.setData(payload)
        StoryPrefs.rememberAudienceName(storyId: storyId, tag: tag)
        StoryAudienceStore.shared.linkStory(storyId, tag: tag)

        do {
            try Task.checkCancellation()
            // THE TWO PUTS RUN TOGETHER, and the URL asks run together after them. This chain was
            // strictly serial — thumb, then video, then two downloadURL round trips one at a time —
            // so every video story paid the thumb's upload and ~two extra round trips on top of the
            // one transfer that matters. Same relaxation the photo path already uses (storage.rules
            // stopped requiring the doc first; see the note there). The doc write above has already
            // happened, so recipients' listeners still see either the full story or nothing.
            let thumbRef = Storage.storage().reference().child(thumbPath)
            let videoRef = Storage.storage().reference().child(videoPath)
            // An unchanged full-screen repost (no burn-in, no mute, whole clip) is copied on the
            // server: its original video and poster land in this story's folder with no upload.
            var copied = false
            if let from = Self.serverCopySource(repostOf), burn == nil, !muted, range == nil {
                copied = await copyRepostMedia(from: from, to: storyId)
            }
            if !copied {
            async let thumbPut: Void = {
                let thumbMeta = StorageMetadata(); thumbMeta.contentType = "image/jpeg"
                _ = try await thumbRef.putDataAsync(prepared.thumbnail, metadata: thumbMeta)
            }()
            async let videoPut: Void = {
                let videoMeta = StorageMetadata(); videoMeta.contentType = "video/mp4"
                // ⛔ FROM A FILE, NOT FROM MEMORY (reference-app research, 2026-10-12). A data upload
                // starts over from zero after any drop; the SDK's file-backed upload can resume the
                // same session from where it got to, which is what a story on a weak network needs.
                // The bytes are written once to a private file and removed when the put is done.
                let file = FileManager.default.temporaryDirectory
                    .appendingPathComponent("story-up-\(UUID().uuidString).mp4")
                if (try? prepared.data.write(to: file, options: .atomic)) != nil {
                    defer { try? FileManager.default.removeItem(at: file) }
                    _ = try await videoRef.putFileAsync(from: file, metadata: videoMeta)
                } else {
                    _ = try await videoRef.putDataAsync(prepared.data, metadata: videoMeta)
                }
            }()
            _ = try await (thumbPut, videoPut)
            }
            try Task.checkCancellation()
            async let tURL = thumbRef.downloadURL()
            async let vURL = videoRef.downloadURL()
            let (thumbUrl, videoUrl) = try await (tURL.absoluteString, vURL.absoluteString)
            // One atomic update: recipients' listeners either see the full story or nothing.
            try await docRef.updateData(["mediaUrl": videoUrl, "thumbUrl": thumbUrl])
            // The story is up: tell the people its caption mentions (`StoryMentions`).
            StoryMentions.send(storyId: storyId, caption: caption, thumbUrl: thumbUrl, recipients: recipients, me: me)
            // The stranger-facing copy, media only. See `writePublicMirror`.
            if everyone {
                await writePublicMirror(storyId: storyId, me: me, mediaUrl: videoUrl,
                                        thumbUrl: thumbUrl,
                                        blurThumb: cover, stickers: stickers,
                                        type: "video", caption: caption,
                                        duration: prepared.duration,
                                        expiresAt: expiresAt,
                                        allowsReplies: allowsReplies,
                                        captureProtected: captureProtected,
                                        repostOf: repostOf)
            }
            // Warm both caches with the poster so my-story cards + the viewer's first frame are instant.
            if let img = UIImage(data: prepared.thumbnail) {
                DiskImageCache.shared.store(img, data: prepared.thumbnail, for: thumbUrl)
            }
            if let u = URL(string: thumbUrl) {
                let resp = URLResponse(url: u, mimeType: "image/jpeg",
                                       expectedContentLength: prepared.thumbnail.count, textEncodingName: nil)
                URLCache.shared.storeCachedResponse(CachedURLResponse(response: resp, data: prepared.thumbnail),
                                                    for: URLRequest(url: u))
            }
            // AND THE VIDEO ITSELF. Only the poster was warmed, so opening the just-posted story
            // re-downloaded the 4-23MB file the phone had JUST finished uploading, on the same
            // connection — the poster sat under a spinner for the whole round trip, which is his
            // "after the upload finishes it keeps showing the loading state". The uploaded bytes
            // ARE what the URL returns; put them where StoryUI's video cache looks and the story
            // plays with zero network.
            if let u = URL(string: videoUrl) { StoryVideoSeed.seed(prepared.data, for: u) }
        } catch {
            try? await docRef.delete()
            try? await Storage.storage().reference().child(videoPath).delete()
            try? await Storage.storage().reference().child(thumbPath).delete()
            throw error
        }
    }

    /// ⚠️ WHO CAN SEE A STORY THAT IS ALREADY UP — the SAME story, never a new one.
    ///
    /// His 2026-08-18 ask, and the reference app's own behaviour: the visibility of an active story
    /// can be changed after it was posted, without deleting it and posting it again. So this writes
    /// the audience fields and nothing else — the id, the posting time, the media, the caption, the
    /// view receipts and the reactions all stay exactly where they are, which is the whole point of
    /// it. Nothing here re-uploads a byte.
    ///
    /// The audience is resolved HERE, against the LIVE chat list, for the same reason `postStory`
    /// resolves it at post time rather than storing a list id on the story: a list holding somebody
    /// who has since been blocked must not reach them. See `resolveAudience`, and the note on
    /// `StoryAudienceTag` for why the custom name never travels to Firestore.
    ///
    /// ⚠️ THE PUBLIC MIRROR FOLLOWS IN BOTH DIRECTIONS, and neither half is optional.
    /// `users/{me}/publicStories/{id}` is the copy a STRANGER reads off the profile. A story moved
    /// off Everyone that kept its mirror would still be public — the exact opposite of what was
    /// asked for — and a story moved on to Everyone with no mirror would not be public at all.
    /// Neither failure has anywhere to show itself on screen, which is why both are done here.
    ///
    /// ⚠️ A ONE-TIME STORY IS REFUSED. Being taken out of `recipientUids` is precisely how a single
    /// view is spent (`onStoryConsumed` does the taking), so rewriting that list would hand somebody
    /// a second look at a story they have already burned. The menu does not offer it either; this is
    /// the half that cannot be got round.
    func updateStoryAudience(_ story: Story, excluded: Set<String>, included: Set<String>,
                                        everyone: Bool, allowsReplies: Bool,
                                        tag: StoryAudienceTag) async throws {
        let me = uid
        // ⚠️ IT THROWS RATHER THAN RETURNS. These three were a plain `return`, which the sheet reads
        // as success: it dismissed with "Viewers updated" over a story whose audience had not moved.
        // Signed out mid-sheet, or somehow reached on somebody else's story, and he would have been
        // told the opposite of what happened.
        guard !me.isEmpty, story.authorUid == me else { throw PostRefusal.notMine }
        // A group story's audience is its group, and the rules pin `groupId` (owner 2026-10-23).
        if story.groupId != nil || tag.groupId != nil { throw PostRefusal.groupStoryFixed }
        // A one-time story's audience is spent as it is watched — see the note above, and the rule
        // that refuses it on the server whatever this does.
        guard !story.oneTime else { throw PostRefusal.oneTimeAudienceFrozen }
        let (recipients, mode) = try await resolveAudience(me: me, excluded: excluded, included: included,
                                                     applyHiddenFrom: everyone, tag: tag)
        // ⛔ AN EDIT MUST NOT QUIETLY AIM A LIVE STORY AT NOBODY. The post path refuses this case
        // (`resolveAudience` throws when the chat list has not loaded); this one can still resolve to
        // an empty set from a list whose members have all been blocked or have left. Posting to
        // nobody is a valid state for a NEW story — it is still your own — but taking a story people
        // are already watching and narrowing it to nobody, silently, is not something to do on a tap
        // labelled Update. The sheet asks the same question before it gets here; this is the half
        // that cannot be skipped by a caller.
        if recipients.isEmpty, !everyone, story.recipientsLeft > 0 {
            throw PostRefusal.audienceEmpty
        }
        let docRef = db.collection("stories").document(story.id)
        // NARROWING TAKES THE MIRROR DOWN FIRST. If the document write then fails, a story that is
        // still public has lost its public copy, and that is the harmless direction to be wrong in.
        // The other order leaves a story whose document says friends-only and which anybody who
        // opens the profile can still watch.
        if !everyone { try await deletePublicMirror(storyId: story.id, authorUid: me) }
        try await docRef.updateData([
            "audience": ["mode": everyone ? "everyone" : mode, "listId": "my-story"],
            // The LABEL only — the custom list's name stays on this device. See `StoryAudienceTag`.
            "audienceLabel": tag.label,
            "public": everyone,
            "allowsReplies": allowsReplies,
            // ⚠️ TOKENS, NOT UIDS — see `StoryAudienceToken`. A recipient can read this document, so
            // the audience travels as hashes here exactly as it does at post time.
            "recipientUids": StoryAudienceToken.tokens(recipients),
        ])
        StoryPrefs.rememberAudienceName(storyId: story.id, tag: tag)
        StoryAudienceStore.shared.linkStory(story.id, tag: tag)
        // ⚠️ THE REMEMBERED COUNT AND FACES FOR THIS STORY ARE DROPPED, NOT UPDATED.
        //
        // `StoryCountCache` is what the owner bar paints from before the server answers, and the
        // audience it was counted against has just changed. Leaving it would draw yesterday's number
        // under a story that now reaches a different set of people, for as long as it takes the
        // counter document to be read again.
        //
        // ⚠️ THE RECEIPTS THEMSELVES ARE LEFT ALONE, AND THAT IS A DECISION RATHER THAN AN OMISSION.
        // Somebody who watched this story DID watch it; narrowing the audience afterwards does not
        // make that untrue, and deleting their receipt would take a real view out of the author's own
        // history. Seen-by is a record of what happened, not a mirror of who can still open it.
        StoryCountCache.forget(story.id)
        // The people list goes with the numbers. Narrowing an audience does not change who already
        // watched — the note above says why the receipts stay — but the LIST the sheet shows is
        // filtered by audience, so a held one would answer the old question.
        StoryViewerListCache.forget(story.id)
        if everyone {
            await writePublicMirror(storyId: story.id, me: me, mediaUrl: story.mediaUrl,
                                    thumbUrl: story.thumbUrl, blurThumb: story.blurThumb,
                                    stickers: story.stickers,
                                    type: story.isVideo ? "video" : "image",
                                    caption: story.caption, duration: story.duration,
                                    expiresAt: story.expiresAt, allowsReplies: allowsReplies,
                                    captureProtected: story.captureProtected,
                                    createdAt: story.createdAt)
        }
    }

    // Record that I viewed a story: always bump my own seen-ring marker; only send a
    // view receipt (so the author sees I viewed) if I have view receipts ON.
    func markViewed(_ story: Story) async {
        let me = uid
        guard !me.isEmpty, story.authorUid != me else { return }
        // A demo person exists only on this device (see `demoGroups`). Their story ids match no
        // document, so a receipt or a watermark for one is a write that can only ever fail — and it
        // would fail against the REAL database, under the real account, for a story that is not there.
        guard !StoriesRepository.isDemoAuthor(story.authorUid) else { return }
        // Nor for Fariin: not an account, and its stories are not in `stories`. Seen stays local, and
        // the view goes to the official story's own count instead (owner 2026-10-18, see
        // `OfficialStoryViews`).
        if OfficialChannel.isOfficial(story.authorUid) { await OfficialStoryViews.record(story); return }
        // Advance my per-author watermark to this story's POST time — never backwards, one write
        // per advance. (Was a wall-clock serverTimestamp, which made watching 1 of 5 stories mark
        // the whole ring seen; the watermark now means "the newest story of theirs I've watched".)
        // A group story's watermark is the group ring's (`ringKey`), so it never greys the poster's own.
        if await StoriesRepository.shared.advanceServerWatermark(story.ringKey, to: story.createdAt) {
            try? await db.collection("users").document(me)
                .collection("storyContexts").document(story.ringKey)
                .setData(["lastViewedAt": Timestamp(date: story.createdAt)], merge: true)
        }

        if StoryReceiptPrefs.isOn {
            // merge: a re-view must NOT wipe a previously-set "reaction" off this receipt.
            try? await db.collection("stories").document(story.id)
                .collection("views").document(me)
                .setData(["viewedAt": FieldValue.serverTimestamp()], merge: true)
        } else {
            // 2026-10-17 (owner): OFF no longer throws the view away. It is noted on MY side only,
            // where the author cannot read it, and the server turns it into a real receipt if I
            // switch back on while the story is still up. See `StoryReceiptPrefs`.
            try? await db.collection("users").document(me)
                .collection("hiddenStoryViews").document(story.id)
                .setData(["storyId": story.id, "authorUid": story.authorUid,
                          "at": FieldValue.serverTimestamp(),
                          "expiresAt": Timestamp(date: story.expiresAt)])
        }
        if story.oneTime { await consumeOneTime(story) }
    }

    /// BURN A ONE-TIME STORY, for me.
    ///
    /// ⚠️ A SEPARATE SUBCOLLECTION FROM THE VIEW RECEIPT, ON PURPOSE, AND NOT AN OPTIMISATION TO
    /// UNDO. A view receipt is optional — "Story View Receipts" is a setting, and with it off no
    /// receipt is written at all. Consumption cannot be optional, or turning that switch off would
    /// turn a one-time story into an ordinary one. And it must not be written INTO the receipt
    /// either, because that would put somebody with receipts off into the author's Seen-by list.
    ///
    /// This write is what the server watches. `onStoryConsumed` takes me out of the story's
    /// `recipientUids`, which is the actual enforcement: the tray query stops matching, a direct read
    /// is refused by the existing rule, and no client can put me back — the story update rule pins
    /// `recipientUids` to its current value for everybody.
    ///
    /// WHAT THIS DOES NOT DO, said plainly: the media file in Storage is readable by any signed-in
    /// user who already has its URL. Someone who captured the URL during their one view could fetch
    /// the file again outside the app. Closing that needs per-story Storage rules or signed URLs, and
    /// it is not this change.
    ///
    /// THE COST HE SHOULD KNOW: the author can tell who has opened a one-time story, because their
    /// uid leaves `recipientUids` and the author can read their own story. That is inherent to
    /// enforcing it at the audience — another mainstream app behaves the same way — and it is not affected by the
    /// viewer's receipt setting.
    func consumeOneTime(_ story: Story) async {
        let me = uid
        guard !me.isEmpty, story.oneTime, story.authorUid != me else { return }
        await MainActor.run { StoryPrefs.markOneTimeUsed(story.id) }
        try? await db.collection("stories").document(story.id)
            .collection("consumed").document(me)
            .setData(["at": FieldValue.serverTimestamp()])
    }

    // Set my reaction emoji on my view receipt (shows in the author's "Seen by" list).
    func setStoryReaction(_ story: Story, emoji: String) async {
        let me = uid
        guard !me.isEmpty, story.authorUid != me else { return }
        let receiptsOn = UserDefaults.standard.object(forKey: "storyViewReceipts") as? Bool ?? true
        guard receiptsOn else { return }
        try? await db.collection("stories").document(story.id)
            .collection("views").document(me)
            .setData(["viewedAt": FieldValue.serverTimestamp(), "reaction": emoji], merge: true)
    }

    // Remove my reaction from my view receipt (un-like) so the author's "Seen by" stops
    // showing a heart I took back.
    /// ⚠️ `setData(merge:)`, NOT `updateData`, AND THE RECEIPT MAY GENUINELY NOT EXIST.
    ///
    /// `updateData` fails outright on a document that is not there, and `try?` swallowed it. A
    /// receipt is missing more often than it looks: view receipts are a setting, and for months
    /// every non-public story's receipt was refused outright by a rule still asking for a raw uid.
    /// So un-liking could leave the heart cleared on this phone and still set on the author's list.
    ///
    /// Merging writes the view mark and takes the reaction off in one go, which is the truth either
    /// way — the story WAS watched. Gated on the receipts setting for the same reason
    /// `setStoryReaction` is: with receipts off there should be no receipt to correct.
    func clearStoryReaction(_ story: Story) async {
        let me = uid
        guard !me.isEmpty, story.authorUid != me else { return }
        guard UserDefaults.standard.object(forKey: "storyViewReceipts") as? Bool ?? true else { return }
        try? await db.collection("stories").document(story.id)
            .collection("views").document(me)
            .setData(["viewedAt": FieldValue.serverTimestamp(),
                      "reaction": FieldValue.delete()], merge: true)
    }

    /// THE COUNT WITHOUT THE LIST — one small document instead of every viewer receipt.
    ///
    /// The footer needs three things: how many, how many reacted, and three faces. Reading the whole
    /// `views` subcollection to work them out is what this replaces; `onStoryViewWritten` keeps this
    /// document, and `stories/{id}/meta` is readable by the author alone (see firestore.rules).
    ///
    /// Nil means "no counter for this story", which is a normal answer rather than an error: every
    /// story posted before the trigger existed has none, and the caller falls back to counting the
    /// receipts as it always did.
    /// A UID TURNED INTO A FACE, FROM WHAT IS ALREADY IN MEMORY — the one place that mapping lives.
    ///
    /// Pure, and takes the chat list rather than reading it, so the same function serves the network
    /// path (which hops to the main actor to collect its arguments) and the cache's rehydration
    /// (which is already there). `viewedAt` is not carried: the footer never shows a time, and
    /// inventing one here would put a wrong time on the sheet if these ever merged.
    static func face(uid: String, convs: [Conversation], me: String) -> StoryViewerInfo {
        let (name, photo) = who(uid, convs: convs, me: me)
        return StoryViewerInfo(id: uid, name: name, photoUrl: photo, viewedAt: Date(), reaction: nil)
    }

    /// A viewer's name and face: our 1:1 chat first, else a group we share (its names/photos maps).
    /// A group story is watched by members I have never messaged; they read "Someone" (2026-10-23).
    static func who(_ uid: String, convs: [Conversation], me: String) -> (String, String?) {
        if let c = convs.first(where: { !$0.isGroup && $0.otherUid(me) == uid }) {
            return (c.name(for: me), c.photoUrl(for: me))
        }
        if let g = convs.first(where: { $0.isGroup && $0.names[uid] != nil }) {
            return (g.names[uid] ?? "Someone", g.photos[uid].flatMap { $0.isEmpty ? nil : $0 })
        }
        return ("Someone", nil)
    }

    /// The same mapping for a caller that holds nothing but uids — the footer's remembered faces.
    /// Reading the chat list here is a synchronous look at memory, which is the whole point: it is
    /// what makes a cached face cost no frame. Not actor-annotated, which is how the rest of the app
    /// reads this repository from synchronous code (`ThreadRepository`, `CallService`, `ChatService`
    /// all do exactly this); the callers are the story footer's own main-thread paths.
    static func faces(for uids: [String]) -> [StoryViewerInfo] {
        let convs = ConversationsRepository.shared.conversations
        let me = Auth.auth().currentUser?.uid ?? ""
        return uids.map { face(uid: $0, convs: convs, me: me) }
    }

    func fetchViewSummary(storyId: String) async -> StoryViewSummary? {
        guard !uid.isEmpty else { return nil }
        // Reciprocal, exactly as `fetchViewers` is: with receipts off you do not see who watched
        // yours, and a count is who watched yours with the names taken off.
        // 2026-10-17 (owner): off now means "nobody NEW", not "nobody". The count is the frozen list
        // `fetchViewers` gives while off, so the number and the names cannot disagree.
        guard StoryReceiptPrefs.isOn else {
            guard let frozen = await fetchViewers(storyId: storyId) else { return nil }
            let meta = try? await db.collection("stories").document(storyId)
                .collection("meta").document("views").getDocument()
            return StoryViewSummary(count: frozen.count,
                                    reactionCount: frozen.filter { !($0.reaction ?? "").isEmpty }.count,
                                    recent: Array(frozen.prefix(3)),
                                    repostCount: meta?.data()?["repostCount"] as? Int ?? 0)
        }
        let snap = try? await db.collection("stories").document(storyId)
            .collection("meta").document("views").getDocument()
        guard let data = snap?.data(),
              let count = data["count"] as? Int ?? (data["repostCount"] is Int ? 0 : nil) else { return nil }
        let recentUids = (data["recent"] as? [String] ?? []).prefix(3)
        let (convs, me) = await MainActor.run { (ConversationsRepository.shared.conversations, uid) }
        // Same resolution as `fetchViewers`, so a face in the footer and the same face in the sheet
        // cannot come out differently named — and the same one the CACHE rehydrates through, so a
        // remembered face and a fetched one cannot disagree either.
        let recent = recentUids.map { Self.face(uid: $0, convs: convs, me: me) }
        return StoryViewSummary(count: count,
                                reactionCount: data["reactionCount"] as? Int ?? 0,
                                recent: Array(recent),
                                repostCount: data["repostCount"] as? Int ?? 0)
    }

    // Who viewed a story I posted (author-only per rules) → for the "Seen by" sheet.
    /// WATCH ONE STORY'S VIEW COUNTER WHILE ITS OWNER IS LOOKING AT IT.
    ///
    /// ⚠️ THE NUMBERS USED TO BE A SNAPSHOT FROM THE MOMENT THE SHEET OPENED. The footer's count, the
    /// preview cards' counts and the viewers list were all fetched once; somebody watching his story
    /// while he had the sheet up appeared nowhere until he closed it and opened it again. Theirs
    /// updates in place, which for a story you have just posted is most of what the screen is for.
    ///
    /// One listener on ONE small document — the counter the server already keeps
    /// (`stories/{id}/meta/views`, author-readable) — rather than a listener on the receipts, so a
    /// story with two hundred viewers costs the same as one with two. The caller attaches it for the
    /// story on screen and drops it when the sheet closes.
    ///
    /// Returns nil when there is nothing to watch (signed out, or receipts off — the same reciprocal
    /// rule the one-shot reads follow).
    func observeViewCount(storyId: String, onChange: @escaping (StoryViewSummary) -> Void) -> ListenerRegistration? {
        guard !uid.isEmpty, !storyId.isEmpty, !Self.isPending(storyId) else { return nil }
        // Off: the list is frozen at `offAt`, so there is nothing new to listen for.
        guard StoryReceiptPrefs.isOn else { return nil }
        return db.collection("stories").document(storyId)
            .collection("meta").document("views")
            .addSnapshotListener { snap, _ in
                // A counter holding only a repost count (nobody has watched yet) is zero views.
                guard let data = snap?.data(),
                      let count = data["count"] as? Int ?? (data["repostCount"] is Int ? 0 : nil) else { return }
                // The same resolution the one-shot read uses, so a face that arrives live and the
                // same face fetched a moment earlier cannot come out differently named.
                let recent = (data["recent"] as? [String] ?? []).prefix(3).map { Self.faces(for: [$0])[0] }
                onChange(StoryViewSummary(count: count,
                                          reactionCount: data["reactionCount"] as? Int ?? 0,
                                          recent: Array(recent),
                                          repostCount: data["repostCount"] as? Int ?? 0))
            }
    }

    /// ⚠️ THE LIVE VIEWERS LIST, ACTUALLY DRIVEN. `observeViewCount` above was written, documented
    /// and correct, and nothing in the app ever called it — grep found it in its own definition and
    /// in two comments, nowhere else. The viewers sheet's `refreshTick` therefore sat at its default
    /// 0 for the life of the process, so `Coordinator.refresh` returned on `guard tick != lastTick`
    /// every single time and `fill(force:)` was unreachable. The list was fetched once when the sheet
    /// opened and then frozen for the whole sitting, which is the opposite of what both files claim.
    ///
    /// One watcher, following whichever story the sheet is showing. The tick is all the sheet wants:
    /// it re-asks for the list itself, and the count under the card has its own path already.
    var viewCountTick = 0
    @ObservationIgnored private var viewCountWatch: ListenerRegistration?
    @ObservationIgnored private var viewCountWatchId = ""

    /// Point the watcher at `storyId`. Idempotent on purpose — asking for the story it is already on
    /// does nothing at all, so this is safe to call from a SwiftUI update pass, which is where the
    /// sheet's active story changes.
    func watchViewCount(storyId: String) {
        guard viewCountWatchId != storyId else { return }
        stopWatchingViewCount()
        guard !storyId.isEmpty else { return }
        viewCountWatchId = storyId
        viewCountWatch = observeViewCount(storyId: storyId) { [weak self] _ in
            // The id test is not paranoia: `remove()` does not promise that a snapshot already in
            // flight will not still be delivered, and a tick attributed to the wrong story would
            // make the sheet re-ask for a list it is no longer showing.
            guard let self, self.viewCountWatchId == storyId else { return }
            self.viewCountTick &+= 1
        }
    }

    /// Called when the sheet closes and when the viewer goes away. A listener that outlives the sheet
    /// is a read charge for a screen nobody is looking at.
    func stopWatchingViewCount() {
        viewCountWatch?.remove()
        viewCountWatch = nil
        viewCountWatchId = ""
    }

    /// NIL means the read failed and the question is still open; `[]` means nobody has watched it.
    /// See the note inside — one dropped request used to be indistinguishable from an empty list, and
    /// the sheet remembered it.
    /// How many viewers the Seen-by list reads at most (2026-09-24 audit, see `fetchViewers`).
    static let viewerListCap = 500

    func fetchViewers(storyId: String) async -> [StoryViewerInfo]? {
        guard !uid.isEmpty else { return [] }
        // RECIPROCAL, as the Stories settings footer promises ("If disabled, you won't see when
        // others view your stories"). The gate existed only on the SENDING half — your views were
        // hidden from others while their full Seen-by list, timestamps and reactions still showed
        // to you (audit). the reference app's rule, and the one the copy already claims.
        // 2026-10-17 (owner): OFF keeps the viewers who were there when I turned it off and hides
        // only the new ones; it no longer answers [] (which read "No views yet" over real views).
        // `firstAt` is set once by the server; a receipt from before it existed falls back to
        // `viewedAt`. No `offAt` known yet means nothing counts as "before".
        let receiptsOn = StoryReceiptPrefs.isOn
        let cutoff = StoryReceiptPrefs.offAt ?? .distantPast
        // ⚠️ A FAILED READ IS NOT AN EMPTY LIST, AND TREATING IT AS ONE IS WHY HE SAW "No views yet"
        // UNDER A CARD READING ONE VIEW.
        //
        // This was `try?` into `snap?.documents ?? []`, so a blip returned the same value as a story
        // nobody has watched — and the sheet's coordinator then CACHED that empty answer for the rest
        // of the session (`cache[id] = people`), so the panel never asked again. One dropped request
        // showed "nobody watched this" for as long as the sheet stayed open, beside a count that had
        // been fetched successfully a moment earlier.
        //
        // Nil now means "ask again". The callers decide what to draw for it; what they may not do is
        // remember it.
        // 2026-09-24 audit: NEWEST FIRST AND CAPPED. This read every receipt the story had, and the
        // open sheet asks again whenever the count moves, so a widely watched Everyone story pulled
        // its whole viewer list again for each new view. The sheet already lists newest first (the
        // sort below), so the cap only drops the oldest names past the first 500; the COUNT on the
        // card comes from `meta/views`, not from this list, and stays the true total. Every receipt
        // write sets `viewedAt`, so ordering by it leaves none out.
        // ⚠️ SERVER ONLY (2026-10-11, his "one view but No views yet" on plane wifi). The default
        // source falls back to the phone's cached copy of this query when the network is down, and
        // that copy was saved before anybody had watched, so it answered an empty list as if it were
        // true, beside a count that was right. Offline is now nil, which the sheet retries.
        guard let snap = try? await db.collection("stories").document(storyId)
            .collection("views")
            .order(by: "viewedAt", descending: true)
            .limit(to: Self.viewerListCap)
            .getDocuments(source: .server) else { return nil }
        let docs = receiptsOn ? snap.documents : snap.documents.filter { d in
            let data = d.data()
            let stamp = (data["firstAt"] as? Timestamp) ?? (data["viewedAt"] as? Timestamp)
            let first = stamp?.dateValue()
            return first.map { $0 <= cutoff } ?? false
        }
        let (convs, me) = await MainActor.run { (ConversationsRepository.shared.conversations, uid) }
        return docs.map { d in
            let u = d.documentID
            let (name, photo) = Self.who(u, convs: convs, me: me)
            return StoryViewerInfo(
                id: u,
                name: name,
                photoUrl: photo,
                viewedAt: (d.data()["viewedAt"] as? Timestamp)?.dateValue() ?? Date(),
                reaction: d.data()["reaction"] as? String
            )
        }.sorted { $0.viewedAt > $1.viewedAt }
    }

    /// Delete one of my stories. TRUE when the DOCUMENT is really gone.
    ///
    /// ⚠️ IT REPORTS NOW, AND EVERY CALLER HAS TO READ THE ANSWER. This used to swallow every error
    /// with `try?` and remove the story from the row regardless — so an offline delete looked like it
    /// worked, the document survived, and the next `load(force:)` brought the story back with no
    /// explanation. A delete that cannot be done has to say so; the row is only allowed to forget a
    /// story the server has actually forgotten.
    @discardableResult
    func deleteStory(_ id: String) async -> Bool {
        // Delete the Storage media FIRST (while the doc still exists, so rules pass), then the
        // doc — else an early delete (before expiry) leaks the media forever (cleanup only
        // handles EXPIRED docs). Read the doc's REAL mediaPath: videos live at video.mp4 +
        // thumb.jpg — the old hardcoded photo.jpg leaked both files on every video delete.
        let data = (try? await db.collection("stories").document(id).getDocument())?.data()
        // ⚠️ A READ THAT FAILED IS NOT A PHOTO, AND GUESSING THAT IT WAS LEAKED EVERY VIDEO.
        //
        // `data` is nil whenever that one read fails — offline, a blip, a rules hiccup — and the old
        // fallback then guessed `photo.jpg`, which for a video is a path that does not exist: the
        // mp4 and its thumb stayed in Storage for ever, and `authorUid` being nil meant the PUBLIC
        // MIRROR was never deleted either, so an "Everyone" story he had just deleted went on
        // playing on his own profile to every stranger who opened it.
        //
        // Nothing here needs the document. Only my own stories can be deleted (the rules say so, and
        // every caller is the owner), so the author is `me`; and the three paths a story's media can
        // occupy are known from its id. Deleting a path that does not exist is a no-op, so asking for
        // all three costs one round trip each and cannot leave anything behind.
        let me = uid
        if let author = data?["authorUid"] as? String, !author.isEmpty, author != me {
            // A group admin's takedown (GroupStoryStaff): the files are the poster's, and the
            // server's onStoryDeleted removes them with the document. A group story has no mirror.
            do { try await db.collection("stories").document(id).delete() } catch { return false }
            await StoriesRepository.shared.removeLocally(id)
            return true
        }
        let knownPaths = data.flatMap { $0["mediaPath"] as? String }.map { [$0] }
            ?? ["stories/\(id)/photo.jpg", "stories/\(id)/video.mp4"]
        // The public mirror goes with it, or a deleted story keeps playing on the author's profile
        // to every stranger who opens it. `me` rather than the document's author for the same reason
        // as above: a failed read must not cost the mirror its deletion.
        let author = (data?["authorUid"] as? String) ?? me
        // ⚠️ FIRST, AND IT CAN STOP THE WHOLE DELETE. The mirror is the public copy; if it survives,
        // the story goes on playing to every stranger who opens the profile even though it is gone
        // from the author's own row and from every recipient's tray. Refusing here leaves BOTH
        // copies in place, which is a state the user can see and retry from — the old silent `try?`
        // left the one state nobody can see or repair.
        if !author.isEmpty {
            do { try await deletePublicMirror(storyId: id, authorUid: author) }
            catch { return false }
        }
        for p in knownPaths { try? await Storage.storage().reference().child(p).delete() }
        // The poster sits beside the mp4 for a video, and for a photo this path simply does not
        // exist. Asked unconditionally when the type is unknown, for the same reason.
        if data == nil || data?["type"] as? String == "video" {
            try? await Storage.storage().reference().child("stories/\(id)/thumb.jpg").delete()
        }
        do {
            try await db.collection("stories").document(id).delete()
        } catch {
            // ⚠️ THE ROW KEEPS THE STORY. Removing it locally here is what made a failed delete look
            // like a successful one until the next refresh put it back.
            return false
        }
        // Drop it from the live row immediately — callers check "was that my last story?"
        // right after this, which must not race the listener's delete event.
        await StoriesRepository.shared.removeLocally(id)
        return true
    }

    /// Flag a story for review (App Store 1.2 — abuse reporting).
    func reportStory(_ story: Story) async {
        guard !uid.isEmpty else { return }
        let filed = try? await db.collection("reports").addDocument(data: [
            "type": "story",
            "storyId": story.id,
            "authorUid": story.authorUid,
            "reporterUid": uid,   // the rule requires reporterUid (was "reporter" → create denied)
            "createdAt": FieldValue.serverTimestamp(),
        ])
        // 2026-09-24 fix-all: counted for the rules' daily report limit, only once it has landed.
        if filed != nil { await MessageRequests.countDaily("reports") }
    }

    /// Delete EVERY story I've posted. Called on account deletion so nothing I shared
    /// stays visible after I'm gone (App Store 5.1.1(v) — deletion must remove my data).
    /// Removes the Storage image first (while the doc still exists, so the rules' author
    /// check passes), then the story doc itself.
    /// ⚠️ THE MIRRORS NOBODY WAS DELETING. A mirror is removed on an explicit delete and on account
    /// deletion, and on NOTHING ELSE — ordinary 24-hour expiry leaves it behind, readable by any
    /// signed-in account, carrying the author's uid, media url and caption for as long as the account
    /// exists. That is a privacy leak with an App Store rule attached to it, and a cost: every
    /// profile visit used to read the whole pile.
    ///
    /// Only the author can write here, so only the author can clean it. Run once per session, off
    /// the critical path, bounded, and failures are ignored — the reader already filters by expiry,
    /// so this is housekeeping rather than correctness.
    /// ⚠️ PAGED UNTIL IT DRAINS, BECAUSE ONE PAGE OF 40 NEVER DID.
    ///
    /// This asked for 40 expired mirrors, deleted them and stopped. It runs once per session, so an
    /// account that ever got more than 40 behind — a stretch of posting to Everyone, a few days
    /// without opening the app — could never catch up: every session cleared 40 and left the rest,
    /// and every expired mirror left behind is a story still readable by any signed-in stranger long
    /// after it should have gone.
    ///
    /// No cursor is needed and using one would be wrong: the page just deleted is gone, so asking the
    /// same query again returns the NEXT forty. The loop ends on a short page, which is the normal
    /// exit, and `maxPages` is a backstop against a page whose deletes all failed handing back the
    /// same documents for ever — not a budget. A thousand mirrors is far past any real backlog.
    func sweepExpiredMirrors() async {
        let me = uid
        guard !me.isEmpty else { return }
        let pageSize = 40
        let maxPages = 25
        for _ in 0..<maxPages {
            guard let snap = try? await db.collection("users").document(me)
                .collection("publicStories")
                .whereField("expiresAt", isLessThan: Timestamp(date: Date()))
                .limit(to: pageSize)
                .getDocuments(), !snap.documents.isEmpty else { return }
            for d in snap.documents { try? await d.reference.delete() }
            if snap.documents.count < pageSize { return }
        }
    }

    func deleteAllMine() async {
        let me = uid
        guard !me.isEmpty,
              let snap = try? await db.collection("stories")
                  .whereField("authorUid", isEqualTo: me).getDocuments() else { return }
        for d in snap.documents {
            if let path = d.data()["mediaPath"] as? String {
                try? await Storage.storage().reference().child(path).delete()
            }
            // Videos also have a poster thumb next to the mp4 — delete it too or it leaks.
            if d.data()["type"] as? String == "video" {
                try? await Storage.storage().reference().child("stories/\(d.documentID)/thumb.jpg").delete()
            }
            // AND THE PUBLIC MIRROR, which is a SEPARATE document in a subcollection and does not
            // go with the story. An "Everyone" story writes one at post time; nothing here removed
            // it, and its read rule is signed-in-only, so it outlived the story it mirrors.
            // Best-effort here on purpose: this is the expiry sweep, it runs again next launch, and
            // one unreachable mirror must not stop it clearing the rest.
            try? await deletePublicMirror(storyId: d.documentID, authorUid: me)
            try? await d.reference.delete()
        }
    }
}

// Cold-start warm cache for the stories ROW (the chat-list trick): the last BUILT row is
// persisted per-account and re-seeded synchronously on launch, so friends' cards render
// immediately instead of ~1.7s late — a cold rebuild otherwise blocks on unknown-author
// profile fetches over the network (user stopwatch, 2026-07-22). Listeners reconcile after.
private enum StoryRowCache {
    struct CachedProfile: Codable { let name: String; let photo: String? }
    struct Blob: Codable {
        let uid: String
        let mine: StoryGroup?
        let others: [StoryGroup]
        let profiles: [String: CachedProfile]
    }
    private static let key = "storyRowCache.v1"
    static func save(uid: String, mine: StoryGroup?, others: [StoryGroup],
                     profiles: [String: (String, String?)]) {
        let blob = Blob(uid: uid, mine: mine, others: others,
                        profiles: profiles.mapValues { CachedProfile(name: $0.0, photo: $0.1) })
        if let d = try? JSONEncoder().encode(blob) { UserDefaults.standard.set(d, forKey: key) }
    }
    static func load(uid: String) -> Blob? {
        guard let d = UserDefaults.standard.data(forKey: key),
              let b = try? JSONDecoder().decode(Blob.self, from: d), b.uid == uid else { return nil }
        return b
    }
    static func clear() { UserDefaults.standard.removeObject(forKey: key) }
}

// Loads the stories I can see (mine + others' that include me), unexpired, grouped by
// person, with my seen-state attached. LIVE: snapshot listeners (same pattern as the chat
// list) push new/deleted stories and my seen-watermarks straight into the row — a friend's
// new ring slides in while you're sitting on the screen, no pull-to-refresh.
@Observable
final class StoriesRepository {
    static let shared = StoriesRepository()
    private init() {
        // 2026-10-20 (owner): after `FirestoreHub.swap` the four listeners belong to the stuck
        // client. Let go of them off-main and attach again on the fresh one for the same account.
        // The row stays as it is: `start` resets the "server has spoken" flags, so the fresh client's
        // empty first cache answer is ignored, not drawn (`ignoreColdEmpty`).
        swapObserver = NotificationCenter.default.addObserver(
            forName: FirestoreHub.swapped, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                let repo = StoriesRepository.shared
                guard let me = repo.listeningUid else { return }
                FirestoreHub.drop([repo.othersReg, repo.othersLegacyReg, repo.mineReg, repo.ctxReg])
                repo.othersReg = nil
                repo.othersLegacyReg = nil
                repo.mineReg = nil
                repo.ctxReg = nil
                repo.othersLegacyFromServer = false   // `stop` leaves this one; the fresh cache is empty
                repo.start(me)
            }
        }
    }
    @ObservationIgnored private var swapObserver: NSObjectProtocol?

    private var db: Firestore { FirestoreHub.db }
    var mine: StoryGroup?            // my own story (the "My Status" cell)
    var others: [StoryGroup] = []    // friends' stories, unseen-first
    // True once rebuild() has PUBLISHED at least once — i.e. the groups above are real knowledge,
    // not just "nothing arrived yet". The story-reply card in a chat flips to "Story unavailable"
    // when a quoted story is absent from the groups, and absence is only meaningful after this:
    // an unloaded repo is empty too, and treating that as "deleted" would mark every quoted story
    // unavailable for the first beat of a cold start.
    private(set) var didLoad = false
    // Bumped on every publish. ThreadView keys its row-signature cache on it, so a story dying
    // (deleted or expired) re-signs and re-MEASURES the story-reply rows — the card (140pt) and
    // the "Story unavailable" line differ in height, and a hosted cell only re-measures through
    // the signature path.
    private(set) var storiesVersion = 0

    /// Is this exact story still live (visible to me, unexpired)? The same resolution the reply
    /// card's tap uses to open it — so what the card SHOWS and what the tap DOES cannot disagree.
    func hasLive(storyId: String, author: String) -> Bool {
        (others + [mine].compactMap { $0 })
            .contains { $0.authorUid == author && $0.stories.contains { $0.id == storyId } }
    }

    // Live inputs. Listener callbacks arrive on the MAIN queue (Firestore default); rebuild()
    // snapshots them there and regroups off-main.
    private var othersReg: ListenerRegistration?
    /// ⚠️ THE SECOND HALF OF THE TRAY, AND IT IS TEMPORARY. `array-contains` takes one value, and for
    /// up to 24 hours after the audience was tokenised there are stories of both kinds in flight:
    /// ones posted by an older build holding raw uids, and ones holding tokens. Two listeners merged
    /// by id is the only way to see both without a round trip per story.
    ///
    /// ⚠️ SAFE TO DELETE ONCE EVERY STORY POSTED BEFORE THE TOKEN CHANGE HAS EXPIRED — a day after
    /// the build carrying it reaches the LAST phone, not a day after it ships. Removing it early
    /// makes an older friend's story silently absent, which is the hardest kind of bug to notice.
    private var othersLegacyReg: ListenerRegistration?
    private var mineReg: ListenerRegistration?
    private var ctxReg: ListenerRegistration?
    private var listeningUid: String?               // re-attach when the signed-in user changes
    /// ⚠️ WHICH REBUILD IS ALLOWED TO PUBLISH. Bumped by every rebuild as it starts; a rebuild only
    /// writes its result if it is still the newest one when it finishes.
    ///
    /// All three snapshot listeners end with `Task { await rebuild() }`, so three of them race into
    /// the same function, and `rebuild` awaits a network fetch for authors who are not in my chats.
    /// That is a real round trip, so a rebuild that STARTED with older data can FINISH after a newer
    /// one — the newer one finds those profiles already cached and returns fast — and the stale
    /// result lands last and wins. Symptom: a story you just deleted flickering back, or one you just
    /// posted vanishing for a beat, and only when somebody outside your chats has a story, which is
    /// what would have made it look random.
    ///
    /// The account guard below is NOT this guard: it catches switching user, and both of these
    /// rebuilds belong to the same account.
    private var rebuildGeneration = 0
    private var othersStories: [Story] = []
    /// The two audience listeners' raw results, merged into `othersStories` by `mergeOthers`.
    private var othersByToken: [Story] = []
    private var othersByLegacyUid: [Story] = []
    private var mineStories: [Story] = []
    /// ⚠️ HAS THE SERVER ANSWERED THIS LISTENER YET, in this session.
    ///
    /// The empty-cached-snapshot guard below exists for the COLD START and nothing else: offline at
    /// launch, Firestore answers from an empty cache and the row would blank out before the seeded
    /// one could be seen. Without knowing whether the server had ever spoken, that guard could not
    /// tell that opening case apart from a real emptying, so it swallowed both — and the one story
    /// that empties a query is the LAST one, which is exactly the case somebody notices. Delete your
    /// only story with a poor connection and the card stayed on the row.
    ///
    /// Once the server has answered once, an empty snapshot means empty. See `start`.
    private var mineFromServer = false
    private var othersFromServer = false
    private var othersLegacyFromServer = false
    private var profileCache: [String: (String, String?)] = [:]   // unknown-author name/photo
    private var expiryTask: Task<Void, Never>?      // wakes at the next expiresAt → drop that card

    /// Sign-out/delete: drop this account's story state; listeners re-attach for the
    /// next account on its first load().
    func reset() {
        othersReg?.remove(); othersReg = nil
        othersLegacyReg?.remove(); othersLegacyReg = nil
        mineReg?.remove(); mineReg = nil
        ctxReg?.remove(); ctxReg = nil
        listeningUid = nil
        expiryTask?.cancel(); expiryTask = nil
        othersStories = []; mineStories = []
        othersByToken = []; othersByLegacyUid = []
        profileCache = [:]
        mine = nil; others = []
        didLoad = false          // the next account starts unknown, not "everything deleted"
        // ⚠️ AND THE WATERMARKS, which were the one piece of story state this did not clear.
        //
        // `serverWatermarks` is "the newest item of X's I have already watched", keyed by author and
        // NOT by account. Signing out and into a second account on the same phone therefore handed
        // the new person the old person's history: any author they both know showed a grey
        // already-watched ring on stories the new account had never opened. Worse, it swallowed
        // their first real view — `advanceServerWatermark` refuses a date older than the one it
        // holds, so the `storyContexts` write never fired and their seen state never reached the
        // server or their other devices.
        serverWatermarks = [:]
        storiesVersion &+= 1
        StoryRowCache.clear()   // the next account must never see this account's story row
    }

    /// Drop `uid` from the audience of every story I currently have live. Called when I block them:
    /// the audience is written once at post time, so without this a freshly blocked person keeps
    /// seeing (and view-receipting) my active stories until they expire.
    /// `publicOnly` narrows the sweep to EVERYONE stories. Hiding somebody uses it: the hide list
    /// belongs to the Everyone audience (see `StoryAudience.appliesGlobalHide`), so it must not reach
    /// into a live custom or one-time story that named that person on purpose. A BLOCK still sweeps
    /// everything, because a block is not an audience rule.
    func revokeAudience(for uid: String, publicOnly: Bool = false) async {
        let me = AuthService.shared.uid ?? ""
        guard !me.isEmpty, !uid.isEmpty else { return }
        guard let snap = try? await db.collection("stories")
            .whereField("authorUid", isEqualTo: me).getDocuments() else { return }
        let now = ServerClock.now
        for doc in snap.documents {
            // Only live ones — expired docs are cleaned up on their own schedule.
            if let exp = (doc.data()["expiresAt"] as? Timestamp)?.dateValue(), exp <= now { continue }
            if publicOnly, (doc.data()["public"] as? Bool ?? false) == false { continue }
            // ONLY the audience list. NOT the `public` flag: clearing that would pull the story from
            // every other non-contact's profile ring as well, which is not what blocking one person
            // means. An "Everyone" story stays public, and the blocked person is turned away at read
            // time instead — see the block gate in publicStoryGroup.
            // BOTH FORMS. A story posted before the audience was tokenised still holds raw uids,
            // and it has up to 24 hours left to live — removing only the token would leave a blocked
            // person watching it for the rest of the day. `arrayRemove` ignores what is not there.
            try? await doc.reference.updateData([
                "recipientUids": FieldValue.arrayRemove([StoryAudienceToken.token(uid), uid])
            ])
        }
    }

    // Fetch a specific user's active PUBLIC ("Everyone") story group — powers the story ring on their
    // PROFILE, so anyone who finds them can watch. Non-contacts are allowed this read because the query
    // is constrained to `public == true`, which is exactly what the Firestore read rule gates on.
    // Returns nil if they have no active public story. Name/photo are passed in (the profile has them).
    func publicStoryGroup(for uid: String, name: String, photoUrl: String?) async -> StoryGroup? {
        let me = AuthService.shared.uid ?? ""
        guard !uid.isEmpty, uid != me else { return nil }   // my own ring is handled by the tray, not the profile
        // BLOCK GATE (audit). resolveAudience deliberately strips people I've blocked from every
        // story I post, but an "Everyone" story also carries public == true, and this read gated
        // only on that flag — so someone the AUTHOR blocked could still watch it from the author's
        // profile, and a rules-refused view write means it need not land in Seen-by to be watched.
        // The block is recorded on the shared conversation doc, which both clients can read.
        // 2026-09-26 block rebuild: somebody I BLOCKED shows me nothing either. And whether the
        // author blocked ME is the server's to know, not mine: the mirror's read rule now refuses
        // it (account list, chat or no chat), the fetch below fails, and there is simply no ring.
        if BlockList.snapshot.contains(uid) { return nil }
        let cid = ChatService.convId(me, uid)
        if let snap = try? await db.collection("conversations").document(cid).getDocument(),
           ((snap.data()?["blockedBy"] as? [String: Any])?[uid] as? Bool) == true {
            return nil   // the AUTHOR blocked me the old way (a copy still on the chat)
        }
        // READS THE MIRROR, NOT THE STORY COLLECTION. The story documents carry `recipientUids` and
        // are no longer readable by anyone outside the audience — because granting them to strangers
        // so this query could work is exactly what leaked the author's contact list. The mirror at
        // `users/{uid}/publicStories` holds the media and nothing about who else can see it, which
        // is all a profile visitor ever needed. `parse` reads the same field names either way.
        // ⚠️ BOUNDED, BECAUSE NOTHING DELETES A MIRROR WHEN ITS STORY EXPIRES.
        //
        // `deletePublicMirror` is reached only from an explicit delete or from account deletion, so
        // ordinary expiry leaves the mirror standing forever. This read had no `where` and no
        // `limit`, so a daily poster's mirror collection grew without end and EVERY profile visit
        // paid a document read per mirror that had ever existed, then threw almost all of them away
        // in the filter below. The filter stays as the belt; the query is what stops the bill.
        let now = ServerClock.now
        let snap = try? await db.collection("users").document(uid)
            .collection("publicStories")
            .whereField("expiresAt", isGreaterThan: Timestamp(date: now))
            .limit(to: 50)
            .getDocuments()
        let stories = parse(snap?.documents)
            .filter { $0.expiresAt > now }
            .sorted { $0.createdAt < $1.createdAt }
        guard !stories.isEmpty else { return nil }
        return StoryGroup(authorUid: uid, name: name, photoUrl: photoUrl,
                          stories: stories, lastViewedAt: nil, isMine: false)
    }

    /// A GROUP STORY OPENED FROM ITS LINK by somebody it was not sent to (owner 2026-10-25: a public
    /// group's story may be shared). Read straight from `stories/{id}`, which the rules grant for a
    /// story of a public group (see the report of 2026-10-25 for that clause); until they do, the
    /// read is refused and this is nil. One story, in its group's ring.
    func linkedGroupStory(_ storyId: String) async -> StoryGroup? {
        guard !storyId.isEmpty, !storyId.contains("/"),
              let snap = try? await db.collection("stories").document(storyId).getDocument(source: .server),
              let data = snap.data(),
              let story = parse(id: snap.documentID, data: data, me: Auth.auth().currentUser?.uid ?? ""),
              let gid = story.groupId, story.expiresAt > ServerClock.now else { return nil }
        return StoryGroup(authorUid: StoryGroup.groupKeyPrefix + gid, name: story.groupName ?? "",
                          photoUrl: story.groupPhoto, stories: [story], lastViewedAt: nil,
                          isMine: story.authorUid == (Auth.auth().currentUser?.uid ?? ""))
    }

    /// ⛔ A PUBLIC GROUP'S STORIES FOR A VISITOR (owner 2026-10-27): the ring on its page, never in
    /// the visitor's Stories row. The server names the live ones (`publicGroupStoryIds`; the rules
    /// let a visitor read one by id but not list them) and each is read through the rules, so one a
    /// blocked author posted is simply missing. Nil when there are none.
    func publicGroupStories(cid: String, name: String, photoUrl: String?) async -> StoryGroup? {
        guard !cid.isEmpty,
              let res = try? await Functions.functions(region: "me-central1")
                .httpsCallable("publicGroupStoryIds").call(["cid": cid]),
              let ids = (res.data as? [String: Any])?["ids"] as? [String], !ids.isEmpty else { return nil }
        let me = Auth.auth().currentUser?.uid ?? ""
        var stories: [Story] = []
        for id in ids where !id.contains("/") {
            guard let snap = try? await db.collection("stories").document(id).getDocument(),
                  let data = snap.data(),
                  let s = parse(id: snap.documentID, data: data, me: me),
                  s.groupId == cid, s.expiresAt > ServerClock.now else { continue }
            stories.append(s)
        }
        guard !stories.isEmpty else { return nil }
        return StoryGroup(authorUid: StoryGroup.groupKeyPrefix + cid, name: name, photoUrl: photoUrl,
                          stories: stories, lastViewedAt: nil, isMine: false)
    }

    private func parse(_ docs: [QueryDocumentSnapshot]?) -> [Story] {
        // WHOSE PHONE THIS IS, read once. `uid` is StoriesService's own private property and this is
        // StoriesRepository, which is what the compiler caught; asking Auth inside the loop would
        // also be one lookup per story rather than one per query.
        let me = Auth.auth().currentUser?.uid ?? ""
        return (docs ?? []).compactMap { d in parse(id: d.documentID, data: d.data(), me: me) }
    }

    /// One story document, from a query or a single read. Nil for one that cannot be shown.
    private func parse(id docId: String, data: [String: Any], me: String) -> Story? {
        guard let author = data["authorUid"] as? String,
              let url = data["mediaUrl"] as? String, !url.isEmpty,   // skip the pre-upload window (empty URL froze the viewer)
              let exp = (data["expiresAt"] as? Timestamp)?.dateValue() else { return nil }
        // A ONE-TIME STORY I HAVE ALREADY OPENED IS GONE, and it goes here because this is the
        // one place every story list is built. The server is removing me from its recipients as
        // this runs; this is what makes "immediately" true on the tap rather than a beat later.
        // Never applied to my OWN stories — the author keeps theirs until it expires.
        if (data["oneTime"] as? Bool ?? false), author != me, StoryPrefs.isOneTimeUsed(docId) {
            return nil
        }
        let created = (data["createdAt"] as? Timestamp)?.dateValue() ?? Date()
        return Story(id: docId, authorUid: author, createdAt: created,
                     expiresAt: exp, mediaUrl: url,
                     allowsReplies: data["allowsReplies"] as? Bool ?? true,
                     caption: data["caption"] as? String ?? "",
                     isVideo: data["type"] as? String == "video",
                     duration: data["duration"] as? Double ?? 0,
                     thumbUrl: data["thumbUrl"] as? String ?? "",
                     blurThumb: data["blurThumb"] as? String ?? "",
                     // Absent on everything posted before stickers existed, which reads as none.
                     stickers: (data["stickers"] as? [[String: Any]] ?? []).compactMap(StoryTapTarget.from),
                     // Written by the uploader since 2026-08-12; absent on everything older,
                     // which reads as zero and lets the lookahead use its own default.
                     preloadPrefix: (data["preloadPrefix"] as? NSNumber)?.int64Value ?? 0,
                     // Stories posted before this field existed fall back to "friends", which is
                     // what they were: the audience list is newer than the story collection, and
                     // a public story is caught by the `public` flag below it.
                     audienceLabel: data["audienceLabel"] as? String
                        ?? ((data["public"] as? Bool ?? false) ? "everyone" : "friends"),
                     oneTime: data["oneTime"] as? Bool ?? false,
                     // Absent on everything posted before the option existed, which reads as off.
                     // The public MIRROR carries the same key, so a stranger reaching an
                     // "Everyone" story from a profile gets the protection too.
                     captureProtected: data["captureProtected"] as? Bool ?? false,
                     // Only my own story hands this over — see the property.
                     recipientsLeft: author == me
                        ? ((data["recipientUids"] as? [String])?.count ?? -1)
                        : -1,
                     // Absent on every story that is not a repost, which is nearly all of them.
                     repostOf: StoryRepost.from(data["repostOf"]),
                     recipientTokens: author == me ? data["recipientUids"] as? [String] : nil,
                     groupId: (data["groupId"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                     groupName: data["groupName"] as? String,
                     groupPhoto: data["groupPhoto"] as? String)
    }

    // Optimistically advance my LOCAL per-author watermark to the story just shown, so the
    // ring/row re-sort instantly instead of waiting for the server write (H8). Monotonic: the
    // watermark is the POST time of the newest story I've watched — never wall clock — so a
    // person with newer unwatched stories keeps their colored ring.
    @MainActor func markSeenLocally(_ authorUid: String, upTo storyCreatedAt: Date) {
        // READ the current value into a local BEFORE writing. `x?.y = max(x?.y ?? …)` reads the
        // same @Observable property inside its own write access — a Swift exclusivity violation
        // that crashed (SIGABRT) the instant an own-story item was viewed (build 176).
        if let i = others.firstIndex(where: { $0.authorUid == authorUid }) {
            let cur = others[i].lastViewedAt ?? .distantPast
            if storyCreatedAt > cur { others[i].lastViewedAt = storyCreatedAt }
        }
        if let m = mine, m.authorUid == authorUid {
            let cur = m.lastViewedAt ?? .distantPast
            if storyCreatedAt > cur { mine?.lastViewedAt = storyCreatedAt }
        }
    }

    // Synchronous removal of one story from the live caches AND the visible groups (used by
    // deleteStory so "was that my last story?" checks never race the listener's delete event).
    @MainActor func removeLocally(_ storyId: String) {
        mineStories.removeAll { $0.id == storyId }
        othersStories.removeAll { $0.id == storyId }
        mine?.stories.removeAll { $0.id == storyId }
        if mine?.stories.isEmpty == true { mine = nil }
        for i in others.indices { others[i].stories.removeAll { $0.id == storyId } }
        others.removeAll { $0.stories.isEmpty }
    }

    // Server-side watermark dedupe: true = this view advances the synced watermark (caller then
    // writes it), false = already covered (no write). Seeded from storyContexts on load.
    private var serverWatermarks: [String: Date] = [:]
    @MainActor func advanceServerWatermark(_ authorUid: String, to date: Date) -> Bool {
        guard date > (serverWatermarks[authorUid] ?? .distantPast) else { return false }
        serverWatermarks[authorUid] = date
        return true
    }

    // Kept for every existing call site: first call goes LIVE (attaches the listeners); later
    // calls just regroup (refilter expiry, pick up renamed profiles) — no network round-trip.
    func load(force: Bool = false) async {
        // demo stories injected; don't let Firebase overwrite them. Un-guarded from `#if DEBUG`
        // so the demo works in TestFlight; `active` is false until the demo username is typed.
        if DemoMode.active { return }
        guard let me = Auth.auth().currentUser?.uid else { return }
        if listeningUid != me {
            // ⚠️ THE PAINT COMES FIRST, BEFORE THE HOUSEKEEPING BELOW. It used to come after, and
            // `purgeExpired` walks two directories before it returns — so on the async path the row
            // waited on a disk sweep that has nothing to do with drawing it. The view now seeds
            // synchronously through `seedRowFromDisk` and never gets here first, but the order still
            // matters for every other caller (a pull-to-refresh, a story just posted, a sign-in).
            await MainActor.run { seedFromDisk(me) }
            // ⚠️ THE OTHER HALF OF KEEPING STORY MEDIA PERMANENTLY. Its files moved out of `Caches`
            // so the OS stops deleting them (his "when i update the app story chache i loss"), and a
            // permanent directory with no lifetime rule is a leak. This is his "after Expired
            // delete": anything past two days goes, which is the retention the reference app gives its own
            // story category. Once per sign-in rather than per refresh — it walks two directories,
            // and doing that on every pull-to-refresh would be work nobody asked for.
            StoryStorage.purgeExpired()
            // The server-side equivalent, and the same once-per-sign-in cadence: mirrors of my own
            // expired stories, which nothing else deletes. See `sweepExpiredMirrors`. Detached so a
            // slow round trip cannot delay the row painting.
            // `StoriesService`, not `self` — this call site lives in `StoriesRepository`, and the
            // two share a file but not a type.
            Task.detached { await StoriesService.shared.sweepExpiredMirrors() }
            // ⚠️ AND WHAT TIME THE SERVER THINKS IT IS, before anything is judged against it. Every
            // expiry test on this device reads `ServerClock.now`; until this lands it is the phone's
            // own clock, which is the behaviour we had. See `ServerClock`.
            Task.detached { await ServerClock.sync() }
            // ⛔ AND ANYTHING THAT WAS STILL BEING POSTED WHEN THE APP LAST DIED. See `StoryOutbox`.
            // After `seedFromDisk` so the row is already on screen, and on the main actor because
            // `postStoryBackground` owns the in-flight state the row draws from.
            // ⚠️ FOR THIS ACCOUNT ONLY. The outbox folder is shared by every account that signs in on
            // the phone and survives a sign-out, so an unqualified resume published one person's
            // failed post as the next person to sign in. See `Ticket.ownerUid`.
            Task { @MainActor in
                StoryOutbox.resume(for: me)
                VideoStoryOutbox.resume(for: me)   // unfinished video posts too (2026-10-12)
            }
            await MainActor.run {
                start(me)          // first call, or the signed-in user changed
            }
        } else {
            await rebuild()
        }
    }

    /// THE SYNCHRONOUS DOOR, and the reason it had to exist.
    ///
    /// `seedFromDisk` has been right all along, and the row still popped in. The order is why: every
    /// caller reaches it through `await load(force:)`, so the seed cannot run until after the first
    /// frame — and inside `load` it sat behind `StoryStorage.purgeExpired()`, which walks two
    /// directories on disk before returning. The last-known row was on the phone the whole time,
    /// waiting behind housekeeping.
    ///
    /// This is called the way the chat list calls `repo.start()`: straight from the view, on the main
    /// thread, before anything is drawn. Re-entry is free — `seedFromDisk` refuses to do anything
    /// once the row has content.
    @MainActor func seedRowFromDisk() {
        // demo stories are injected; a disk row would fight them. Un-guarded from `#if DEBUG` for
        // the same reason as `load()` above.
        if DemoMode.active { return }
        guard let me = Auth.auth().currentUser?.uid else { return }
        seedFromDisk(me)
    }

    // Cold-start seed: re-publish the persisted row (expired stories dropped) before the first
    // listener snapshot, so the stories row renders on the first frame like the chat list does.
    @MainActor private func seedFromDisk(_ me: String) {
        guard mine == nil, others.isEmpty, let blob = StoryRowCache.load(uid: me) else { return }
        let now = ServerClock.now
        var m = blob.mine
        m?.stories.removeAll { $0.expiresAt <= now }
        mine = (m?.stories.isEmpty == false) ? m : nil
        others = blob.others.compactMap { g -> StoryGroup? in
            var g = g
            g.stories.removeAll { $0.expiresAt <= now }
            return g.stories.isEmpty ? nil : g
        }
        for (u, p) in blob.profiles where profileCache[u] == nil { profileCache[u] = (p.name, p.photo) }
    }

    // Attach the three live queries (chat-list listener pattern).
    @MainActor private func start(_ me: String) {
        stop()
        listeningUid = me
        // ⚠️ MY TOKEN, NOT MY UID — see `StoryAudienceToken`. One `array-contains` against the same field,
        // so the query's shape, its index and its cost are exactly what they were.
        othersReg = db.collection("stories")
            .whereField("recipientUids", arrayContains: StoryAudienceToken.token(me))
            .addSnapshotListener { [weak self] snap, error in
                guard let self, let snap else { if let error { print("stories listen error:", error) }; return }
                if !snap.metadata.isFromCache { self.othersFromServer = true }
                // One line, no extra read — see `ConnectionStatus`.
                Task { @MainActor in ConnectionStatus.shared.noteSnapshot(fromCache: snap.metadata.isFromCache, pendingWrites: snap.metadata.hasPendingWrites) }
                if Self.ignoreColdEmpty(snap, serverHasSpoken: self.othersFromServer) { return }
                self.othersByToken = self.parse(snap.documents)
                self.mergeOthers()
                Task { await self.rebuild() }
            }
        // The stories posted before the change, for the day they have left. See `othersLegacyReg`.
        othersLegacyReg = db.collection("stories").whereField("recipientUids", arrayContains: me)
            .addSnapshotListener { [weak self] snap, error in
                guard let self, let snap else { if let error { print("legacy stories listen error:", error) }; return }
                if !snap.metadata.isFromCache { self.othersLegacyFromServer = true }
                if Self.ignoreColdEmpty(snap, serverHasSpoken: self.othersLegacyFromServer) { return }
                self.othersByLegacyUid = self.parse(snap.documents)
                self.mergeOthers()
                Task { await self.rebuild() }
            }
        mineReg = db.collection("stories").whereField("authorUid", isEqualTo: me)
            .addSnapshotListener { [weak self] snap, error in
                guard let self, let snap else { if let error { print("my stories listen error:", error) }; return }
                if !snap.metadata.isFromCache { self.mineFromServer = true }
                Task { @MainActor in ConnectionStatus.shared.noteSnapshot(fromCache: snap.metadata.isFromCache, pendingWrites: snap.metadata.hasPendingWrites) }
                if Self.ignoreColdEmpty(snap, serverHasSpoken: self.mineFromServer) { return }
                self.mineStories = self.parse(snap.documents)
                Task { await self.rebuild() }
            }
        // My per-author seen watermarks — live too, so watching on another device greys rings here.
        ctxReg = db.collection("users").document(me).collection("storyContexts")
            .addSnapshotListener { [weak self] snap, _ in
                guard let self, let snap else { return }
                for d in snap.documents {
                    if let ts = (d.data()["lastViewedAt"] as? Timestamp)?.dateValue() {
                        // Merge FORWARD only — read into a local first (same-property read inside
                        // its own write access is an exclusivity crash, see markSeenLocally).
                        let cur = self.serverWatermarks[d.documentID] ?? .distantPast
                        if ts > cur { self.serverWatermarks[d.documentID] = ts }
                    }
                }
                Task { await self.rebuild() }
            }
    }

    /// The two audience listeners, as one list. Tokenised first so a story matching both keeps the
    /// newer copy, deduplicated by id because a merge is the only place the two can meet.
    @MainActor private func mergeOthers() {
        var seen = Set<String>()
        othersStories = (othersByToken + othersByLegacyUid).filter { seen.insert($0.id).inserted }
    }

    /// THE OFFLINE COLD START, AND ONLY THAT: an empty snapshot out of the cache, before the server
    /// has ever answered this listener, with no unacknowledged write of ours to explain it.
    ///
    /// Everything else is a real emptying and has to be applied. The case this used to swallow is
    /// the one that matters: deleting your LAST story is the only delete that empties the query, and
    /// on a slow connection Firestore reports it from the cache first, so the guard threw the truth
    /// away and the card stayed on the row. `hasPendingWrites` is what names that snapshot as the
    /// consequence of my own delete rather than an empty cache, and it is true from the moment the
    /// local mutation lands until the server acknowledges it.
    ///
    /// Static, so it cannot read the flag it is being told about — a stored property passed into a
    /// method of its own owner is the exclusivity trap `markSeenLocally` already paid for once.
    private static func ignoreColdEmpty(_ snap: QuerySnapshot, serverHasSpoken: Bool) -> Bool {
        snap.metadata.isFromCache && snap.documents.isEmpty
            && !snap.metadata.hasPendingWrites && !serverHasSpoken
    }

    @MainActor private func stop() {
        othersReg?.remove(); othersReg = nil
        othersLegacyReg?.remove(); othersLegacyReg = nil
        mineReg?.remove(); mineReg = nil
        ctxReg?.remove(); ctxReg = nil
        listeningUid = nil
        // A new account gets a new cold start. Left true, the first empty cached snapshot after a
        // sign-in would be applied as though the server had already confirmed the row was empty.
        mineFromServer = false
        othersFromServer = false
    }

    // Regroup the cached live inputs into the row's groups. Cheap (no story reads); only
    // unknown-author profiles are fetched, once each, then cached.
    private typealias RebuildInputs = (me: String, all: [Story], convs: [Conversation],
                                       myName: String, myPhoto: String?,
                                       cachedProfiles: [String: (String, String?)])

    /// ⛔ MY OWN NAME AND PICTURE CHANGED, SO THE ROW AND THE VIEWER HEADER HAVE TO BE REGROUPED.
    ///
    /// `rebuild` reads `ProfileStore.shared.me` live, so it always produces the right answer — but
    /// nothing ASKED it to run when the profile changed. It is driven by the three story listeners,
    /// and changing your photograph is not a story event. So the group kept the url captured at the
    /// last rebuild: after a removal the story header still showed the deleted picture, and after a
    /// change it still showed the old one, until some unrelated story event happened to regroup.
    ///
    /// Cheap by construction — the note on `rebuild` says it: no story reads, just regrouping what
    /// is already in memory.
    func refreshMyDisplay() { Task { await rebuild() } }

    private func rebuild() async {
        let now = ServerClock.now
        // Claimed on the main actor with the inputs, so the number and the data it describes are
        // taken in the same hop and cannot disagree.
        var generation = 0
        // Snapshot every live-mutated input on the main actor.
        let inputs: RebuildInputs? = await MainActor.run {
            guard let me = listeningUid else { return nil }
            rebuildGeneration &+= 1
            generation = rebuildGeneration
            // ⚠️ THE ONE-TIME FILTER RUNS HERE TOO, NOT ONLY IN `parse`.
            //
            // `parse` reads a SNAPSHOT, and a story I have just opened produces no snapshot for
            // several seconds: my consumption receipt has to reach Firestore, `onStoryConsumed` has
            // to fire, and only then does the recipients query stop matching. Until it did, the
            // parsed struct sat in `othersStories` and every regroup put it straight back in the
            // tray — so the card was still there and could be opened again and again. His report,
            // exactly: "a user can finish viewing the story and still see/open that same story".
            // Filtering the cached list as well makes the local flag bite immediately, on the
            // regroup the viewer's own close already asks for, without waiting for the server.
            return (me, (othersStories + mineStories)
                        .filter { $0.expiresAt > now }
                        .filter { !($0.oneTime && $0.authorUid != me && StoryPrefs.isOneTimeUsed($0.id)) },
                    ConversationsRepository.shared.conversations,
                    ProfileStore.shared.me?.name ?? "You",
                    ProfileStore.shared.me?.photoUrl,
                    profileCache)
        }
        guard let (me, all, convs, myName, myPhoto, cachedProfiles) = inputs else { return }

        // Authors NOT in my chats (a story can reach me from someone I've never messaged,
        // e.g. beta test accounts): fall back to their profile doc for name/photo instead of
        // rendering "User". Rules allow any signed-in user to read users/{uid}.
        let known = Set(convs.map { $0.otherUid(me) })
        let unknownAuthors = Set(all.map(\.authorUid)).subtracting(known).subtracting([me])
            .filter { cachedProfiles[$0] == nil }
        var profiles = cachedProfiles
        if !unknownAuthors.isEmpty {
            await withTaskGroup(of: (String, String, String?)?.self) { group in
                for u in unknownAuthors {
                    group.addTask { [db] in
                        let snap = try? await db.collection("users").document(u).getDocument()
                        if let snap, snap.exists, let f = snap.data() {
                            // The tick comes in the same read (owner 2026-10-16: it arrived late).
                            VerificationIndex.record(uid: u, verification: Verification(f["verification"] as? [String: Any]))
                            return (u, f["name"] as? String ?? "", f["photoUrl"] as? String)
                        }
                        // Doc genuinely doesn't exist → negative-cache ("", nil) so a profileless author
                        // isn't re-fetched on every listener tick. A NETWORK error (snap == nil) returns
                        // nil so it's retried next rebuild (don't cache a transient failure).
                        return snap != nil ? (u, "", nil) : nil
                    }
                }
                for await r in group { if let (u, n, p) = r { profiles[u] = (n, p) } }
            }
        }

        func display(_ uid: String) -> (String, String?) {
            if uid == me { return (myName, myPhoto) }
            if let c = convs.first(where: { $0.otherUid(me) == uid }) {
                return (c.name(for: me), c.photoUrl(for: me))
            }
            return profiles[uid] ?? ("", nil)
        }

        // Don't show stories from anyone I've blocked (C3, read side). isBlockedByMe, not
        // leaksBlocked — a quietly-blocked author's stories were still appearing in my row.
        // 2026-09-26 block rebuild: and everybody on my account list, chat or no chat.
        let blockedAuthors = Set(convs.filter { $0.isBlockedByMe(me) }.map { $0.otherUid(me) })
            .union(BlockList.snapshot.entries.keys)
        // ⛔ AND ANYONE WHOSE CHAT WITH ME IS STILL AN UNANSWERED REQUEST (owner 2026-10-12). The
        // poster now leaves them out (`resolveAudience`), but stories already posted, and posts
        // from older builds, still name me in `recipientUids`. Someone with no chat at all is not
        // touched here (a glow reaches people who never chatted).
        // ⛔ NOT FOR A GROUP STORY (owner 2026-10-26: members could not see his group story). Being in
        // the group is the tie; an unanswered 1:1 request between the poster and me hid the whole
        // group's post from me. Only a real block drops a group story.
        let requestAuthors = Set(convs.filter { MessageRequests.isUnansweredRequest($0) }.map { $0.otherUid(me) })

        var myGroup: StoryGroup?
        var groups: [StoryGroup] = []
        // GROUP STORIES (owner 2026-10-23) get the group's ring, keyed by `ringKey`, mine included
        // (owner, later the same day: "a group story must not go in my own story"). A ring of only
        // my posts is `isMine`, so its viewer shows Views and Replies. A blocked author's group story
        // is dropped story by story, so the rest of that group's ring still shows.
        var byRing: [String: [Story]] = [:]
        for s in all {
            let key = s.ringKey
            if key != s.authorUid && blockedAuthors.contains(s.authorUid) { continue }
            if key == s.authorUid && requestAuthors.contains(s.authorUid) { continue }
            byRing[key, default: []].append(s)
        }
        for (key, list) in byRing {
            let sorted = list.sorted { $0.createdAt < $1.createdAt }
            if key.hasPrefix(StoryGroup.groupKeyPrefix) {
                let gid = String(key.dropFirst(StoryGroup.groupKeyPrefix.count))
                let conv = convs.first { $0.id == gid }
                // Suspended or disabled by Fariin: its stories are gone from the row (owner 2026-10-26).
                if conv?.fariinLocked == true { continue }
                let last = sorted.last
                // The group's own name and photo; a story posted before 2026-10-23 may carry a
                // member's name in groupName (the 1:1 helper), so the live group wins.
                let name = conv?.displayName(me) ?? last?.groupName ?? ""
                let photo = conv?.displayPhoto(me) ?? last?.groupPhoto
                groups.append(StoryGroup(authorUid: key, name: name, photoUrl: photo,
                                         stories: sorted, lastViewedAt: nil,
                                         isMine: sorted.allSatisfy { $0.authorUid == me }))
                continue
            }
            let author = key
            let (name, photo) = display(author)
            let g = StoryGroup(authorUid: author, name: name, photoUrl: photo,
                               stories: sorted, lastViewedAt: nil, isMine: author == me)
            if author == me { myGroup = g }
            else if !blockedAuthors.contains(author) { groups.append(g) }
        }
        if Self.injectDemoStories { groups.append(contentsOf: Self.demoGroups(now: now)) }   // TEMP test data
        // ⭐ THE STORY ROW AND THE CHAT LIST NOW SHOW THE SAME PEOPLE. Settings > Demo chats injected
        // chats only, so Cabdi and Khadra sat in the chat list with their photographs while the row
        // above them showed a different, older set of demo people carrying drawn placeholders.
        // Different names and different faces on one screen, which is the one thing a screenshot
        // cannot have. Gated on the same switch, so one toggle produces a coherent phone.
        // Read from the cache, not built here: this method is not main-actor isolated and building
        // them draws with UIKit. Same arrangement `demoChats` already uses.
        if DemoMode.chatsInjected { groups.append(contentsOf: DemoMode.demoStories) }
        // Fariin's official stories, as one more person in the row. See `OfficialStories`.
        if let official = OfficialStories.group { groups.append(official) }

        // Unseen first, then by most-recent story. (Watermarks are applied on commit below,
        // so hasUnseen here can be pessimistic — the row re-sorts from live state anyway.)
        groups.sort {
            if $0.hasUnseen != $1.hasUnseen { return $0.hasUnseen }
            return ($0.stories.last?.createdAt ?? .distantPast) > ($1.stories.last?.createdAt ?? .distantPast)
        }

        let nextExpiry = all.map(\.expiresAt).min()
        await MainActor.run {
            // The account changed while this rebuild was awaiting profile fetches → publishing now
            // would repaint the previous account's story row for the next person, right after
            // reset() cleared it (audit). reset() nils listeningUid, so this is the test.
            guard self.listeningUid == me else { return }
            // AND ONLY IF NOTHING NEWER HAS STARTED. See `rebuildGeneration`. A rebuild that has
            // been overtaken while it waited on profile fetches is holding an older picture of the
            // world, and publishing it would undo whatever the newer one has already drawn.
            guard generation == self.rebuildGeneration else { return }
            for (u, p) in profiles where cachedProfiles[u] == nil { profileCache[u] = p }
            // Apply the freshest watermark to each group so a rebuild can never REGRESS a ring
            // to unseen while the view write is still in flight (H8, watermark edition).
            var mg = myGroup
            if let m = mg, let w = self.serverWatermarks[m.authorUid], w > (m.lastViewedAt ?? .distantPast) {
                mg?.lastViewedAt = w
            }
            var gs = groups
            for i in gs.indices {
                let cur = gs[i].lastViewedAt ?? .distantPast
                if let w = self.serverWatermarks[gs[i].authorUid], w > cur {
                    gs[i].lastViewedAt = w
                }
            }
            self.mine = mg; self.others = gs
            self.didLoad = true
            self.storiesVersion &+= 1
            // Persist the freshly built row so the NEXT cold start paints it on the first frame.
            StoryRowCache.save(uid: me, mine: mg, others: gs, profiles: self.profileCache)
            self.scheduleExpiryTick(nextExpiry)
            self.prefetchOnArrival(gs)
        }
    }

    /// ⛔ DOWNLOAD ON ARRIVAL — 2026-10-10, his "make the stories page strong" order, the reference
    /// app's rule (its StoryManager): when a story arrives it downloads up to THREE unwatched stories
    /// per person, and only for about TWENTY people, in the background. Ours only warmed the first
    /// story per person, and only from the UIKit strip, so the two-column grid (the layout in use)
    /// warmed nothing and every card opened on a download.
    ///
    /// Here, in the store, it runs for every layout and every time the list changes (a new post
    /// lands through the listener). `others` is unseen-first, so the first twenty are the people
    /// most likely to be opened. `StoryPrefetcher` dedupes in-flight and on-disk files, keeps videos
    /// to Wi-Fi, and stands down in Low Data Mode, so a repeat call costs nothing.
    private var lastArrivalKey = ""
    @MainActor private func prefetchOnArrival(_ groups: [StoryGroup]) {
        // ⛔ NOT WHILE A STORY IS OPEN — owner, 2026-10-11, the cube turn lagging. Watching a story
        // rebuilds the groups, and this re-ran on every rebuild, decoding dozens of full-size
        // pictures in the background during the turn. The viewer runs its own lookahead; this one
        // waits for the next rebuild after it closes.
        if StoryDoorState.shared.isOpen { return }
        var items: [StoryPrefetcher.Item] = []
        // Hidden people are skipped: their cards are not on the page, so nobody is about to open them.
        let wanted = groups.filter { !Self.isDemoAuthor($0.authorUid) && !StoryPrefs.isHidden($0.authorUid) }
        for g in wanted.prefix(20) {
            let unseen = g.stories.filter {
                !StoryPrefs.isStorySeen($0.id) && $0.createdAt > (g.lastViewedAt ?? .distantPast)
            }
            for (n, s) in unseen.prefix(3).enumerated() where !s.mediaUrl.isEmpty {
                items.append(.init(media: s.mediaUrl, poster: s.previewUrl, isVideo: s.isVideo, leading: n == 0))
            }
        }
        let key = items.map(\.media).joined(separator: "|")
        guard key != lastArrivalKey else { return }
        lastArrivalKey = key
        // Bytes only: pixels are decoded when a story is near (the viewer's lookahead) — decoding
        // up to sixty pictures nobody has opened was the cost, not the download.
        StoryPrefetcher.prefetchFirsts(items, mediaDepth: items.count, decode: false)
    }

    // A story crossing its 24h mark changes nothing in the database, so no listener fires —
    // wake up right after the soonest expiry and regroup so the card drops off by itself.
    @MainActor private func scheduleExpiryTick(_ next: Date?) {
        expiryTask?.cancel(); expiryTask = nil
        guard let next else { return }
        let delay = next.timeIntervalSinceNow + 1
        guard delay > 0 else { return }
        expiryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.rebuild()
        }
    }

    // ===== Demo story people, for testing the viewer / carousel / rings / cube =====
    //
    // DEBUG ONLY, AND LOCAL ONLY. Every picture and every clip is drawn and encoded on this phone by
    // `DemoStoryMedia` and planted in the caches the real code reads, so these people work with the
    // network off and nothing about them ever reaches Firebase. Nobody else can see them because
    // they do not exist anywhere but this device.
    //
    // ⚠️ THE POINT OF THEM IS VIDEO. The previous version of this block pointed at `picsum.photos`
    // and every demo story was a still, which could not test one bug this app actually has — they
    // are all video bugs. The mixes below are chosen for the reports that keep coming back:
    // video→video→video for the preview-card flash, image→video→video for "the viewer closes when a
    // clip ends instead of advancing", and several people so the cube has somewhere to turn.
    //
    // Toggle at runtime with the switch in Settings (debug builds only) — no rebuild needed.
    /// ⚠️ NOT `#if DEBUG`. That gate shipped in build 550 and put the demo people in no build he can
    /// run: the TestFlight lane builds Release, and with no Mac in the picture every build that
    /// reaches his phone is a TestFlight build. `DemoStoryMedia.isAvailable` is debug OR TestFlight,
    /// never the App Store, which is the distinction that was actually wanted.
    /// ⛔ ALWAYS OFF — 2026-09-24 audit. The "Demo story people" switch was removed on his
    /// 2026-09-05 order, but this still read its key, so anyone who had it on in an older TestFlight
    /// build kept the "(demo)" people with no way left to turn them off.
    static var injectDemoStories: Bool { false }

    /// True for a person who only exists on this device, so nothing tries to write a view receipt,
    /// a watermark or a reply for them.
    /// ⛔ BOTH DEMO FAMILIES, AND THE SECOND ONE WAS MISSING — 2026-09-11 audit, carried over from
    /// the 2026-09-05 read-only pass.
    ///
    /// There are two sets of people who exist only on this device, and they were given different
    /// prefixes: the story row's demo cast is `demo_` (`demoGroups`) and the Glow cast is
    /// `glowdemo_` (`GlowDemo.cast`). This test knew only the first, so
    /// `"glowdemo_hodan".hasPrefix("demo_")` is FALSE and every Glow demo author walked straight
    /// through the one guard that exists to stop them.
    ///
    /// ⚠️ WHAT THAT COST. `markViewed` returns early for a demo author precisely because their
    /// story ids match no document — so for a Glow demo person it went on to write a view receipt
    /// and advance a per-author watermark, against the REAL database, under the real account, for a
    /// story that does not exist. Writes that can only fail, and a watermark polluted with a uid no
    /// real person will ever have.
    ///
    /// ⚠️ THE TWO PREFIXES ARE NOT FOLDED INTO ONE. `glowdemo_` does not start with `demo_`, so a
    /// single test cannot cover both, and renaming either cast is a data change on devices that
    /// already have one. `GlowDemo.isDemoPerson` is the Glow half's own copy of this question and
    /// must stay in step with the second clause here.
    /// ⛔ AND THE THIRD FAMILY, `demo-` WITH A HYPHEN — 2026-09-24 audit. The Settings "Demo chats"
    /// people ("demo-sagal", "demo-cabdi") matched neither prefix, so viewing their story wrote
    /// users/{me}/storyContexts/demo-sagal to the real database. No real account uid starts "demo-".
    static func isDemoAuthor(_ uid: String) -> Bool {
        uid.hasPrefix("demo_") || uid.hasPrefix("glowdemo_") || uid.hasPrefix("demo-")
    }

    /// Re-publish the row after the demo switch is flipped, so it takes effect without a relaunch.
    /// The first flip ON is also the encode, which is why it runs off the main actor.
    func refreshForDemo() { Task { await rebuild() } }

    static func demoGroups(now: Date) -> [StoryGroup] {
        // Ages, so the rings sort the way a real row would.
        func made(_ hoursAgo: Double) -> Date { now.addingTimeInterval(-3600 * hoursAgo) }
        func expires() -> Date { now.addingTimeInterval(3600 * 20) }

        func videoStory(_ uid: String, _ n: Int, _ clip: DemoStoryMedia.Clip?, _ hoursAgo: Double) -> Story? {
            guard let clip else { return nil }
            return Story(id: "demo_\(uid)_\(n)", authorUid: uid, createdAt: made(hoursAgo),
                         expiresAt: expires(), mediaUrl: clip.mediaUrl, allowsReplies: true,
                         caption: "", isVideo: true, duration: clip.seconds, thumbUrl: clip.thumbUrl)
        }
        func imageStory(_ uid: String, _ n: Int, _ url: String, _ hoursAgo: Double) -> Story {
            Story(id: "demo_\(uid)_\(n)", authorUid: uid, createdAt: made(hoursAgo),
                  expiresAt: expires(), mediaUrl: url, allowsReplies: true)
        }

        // CABDI — three videos in a row. This is the set for the preview-card flash: open the
        // middle one, swipe up, then swipe the card row away and back.
        let cabdi = [
            videoStory("demo_cabdi", 1, DemoStoryMedia.video("cabdi-1", seconds: 6,
                                                             top: .systemIndigo, bottom: .systemBlue,
                                                             title: "Cabdi 1"), 5),
            videoStory("demo_cabdi", 2, DemoStoryMedia.video("cabdi-2", seconds: 4,
                                                             top: .systemPink, bottom: .systemRed,
                                                             title: "Cabdi 2"), 4),
            videoStory("demo_cabdi", 3, DemoStoryMedia.video("cabdi-3", seconds: 7,
                                                             top: .systemTeal, bottom: .systemGreen,
                                                             title: "Cabdi 3"), 3),
        ].compactMap { $0 }

        // HODAN — image, then two videos. The exact shape of the "B ends and the viewer closes
        // instead of going to C" report.
        let hodan = [
            imageStory("demo_hodan", 1, DemoStoryMedia.image("hodan-1", top: .systemOrange,
                                                             bottom: .systemYellow, title: "Hodan 1"), 6),
            videoStory("demo_hodan", 2, DemoStoryMedia.video("hodan-2", seconds: 5,
                                                             top: .systemPurple, bottom: .systemPink,
                                                             title: "Hodan 2"), 2),
            videoStory("demo_hodan", 3, DemoStoryMedia.video("hodan-3", seconds: 5,
                                                             top: .systemBrown, bottom: .systemOrange,
                                                             title: "Hodan 3"), 1),
        ].compactMap { $0 }

        // YASIN — a single long clip, so there is a person whose story does not advance internally.
        let yasin = [
            videoStory("demo_yasin", 1, DemoStoryMedia.video("yasin-1", seconds: 8,
                                                             top: .systemCyan, bottom: .systemIndigo,
                                                             title: "Yasin"), 7),
        ].compactMap { $0 }

        // SAGAL — stills only, as a control: whatever breaks on the video people must NOT break here.
        let sagal = [
            imageStory("demo_sagal", 1, DemoStoryMedia.image("sagal-1", top: .systemGreen,
                                                             bottom: .systemTeal, title: "Sagal 1"), 9),
            imageStory("demo_sagal", 2, DemoStoryMedia.image("sagal-2", top: .systemRed,
                                                             bottom: .systemPink, title: "Sagal 2"), 8),
        ]

        return [
            StoryGroup(authorUid: "demo_cabdi", name: "Cabdi (demo)",
                       photoUrl: DemoStoryMedia.avatar("cabdi", top: .systemIndigo,
                                                       bottom: .systemBlue, initial: "C"),
                       stories: cabdi, lastViewedAt: nil, isMine: false),
            StoryGroup(authorUid: "demo_hodan", name: "Hodan (demo)",
                       photoUrl: DemoStoryMedia.avatar("hodan", top: .systemPurple,
                                                       bottom: .systemPink, initial: "H"),
                       stories: hodan, lastViewedAt: nil, isMine: false),
            StoryGroup(authorUid: "demo_yasin", name: "Yasin (demo)",
                       photoUrl: DemoStoryMedia.avatar("yasin", top: .systemCyan,
                                                       bottom: .systemIndigo, initial: "Y"),
                       stories: yasin, lastViewedAt: nil, isMine: false),
            StoryGroup(authorUid: "demo_sagal", name: "Sagal (demo)",
                       photoUrl: DemoStoryMedia.avatar("sagal", top: .systemGreen,
                                                       bottom: .systemTeal, initial: "S"),
                       stories: sagal, lastViewedAt: nil, isMine: false),
        ].filter { !$0.stories.isEmpty }
    }
}
