import SwiftUI   // ChatColorSpec and Theme hand back SwiftUI values that are resolved here, once
import UIKit

// ===== Message → MessageRowModel =====
//
// The one place that reads app state to decide how a row looks. Everything downstream of here is
// pure geometry over a value type.
//
// ⚠️ It takes its context as EXPLICIT INPUTS rather than reaching into ThreadView. That is not
// tidiness — it is what makes the routing decision auditable: `canRender` below is a total function
// of these inputs, so "why did this row go down the old path" is answerable by reading one
// function, and a state that was forgotten cannot silently change a row's appearance.

struct MessageRowContext {
    var me: String
    var cid: String
    var isGroup: Bool
    /// A channel (2026-10-28): every post is the channel speaking, drawn as received for everyone,
    /// its admin too (the reference app's rule), with no sender name or face.
    var isChannel: Bool = false
    /// The channel signs its posts with the admin's name (Sign Posts).
    var signPosts: Bool = false
    /// The channel's name and tick, written at the top of a post that quotes another (owner 2026-11-07).
    var channelTitle: String = ""
    var channelVerified: Bool = false
    /// My 1:1 call: the other phone has said it is ringing (CallService.calleeRinging).
    var calleeRinging: Bool = false
    /// A channel's reactions (2026-10-29): shown at all (not "off"), may I add one (a follower),
    /// and my pick per post, as shown and as the server holds it (the counts include the latter).
    var channelReactionsOn: Bool = false
    var channelCanReact: Bool = false
    /// Disable Sharing is on in this chat (`ThreadRepository.noForwarding`).
    var noForwarding: Bool = false
    /// The channel has replies off for every post (`Conversation.repliesOff`).
    var repliesOff: Bool = false
    /// The channel turned Quotes off: the bar leaves out the quote count (owner 2026-11-07).
    var quotesOff: Bool = false
    /// Draw every bubble plain, whatever style it was sent with: a group with Bubble styles off
    /// (`Conversation.bubbleStylesOff`) and the official Fariin chat (owner 2026-11-07).
    var stylesOff: Bool = false
    var channelMine: (String) -> String? = { _ in nil }
    var channelConfirmed: (String) -> String? = { _ in nil }
    /// The counts to draw for a post (mid, the post's own): the server's answer to my pick while the
    /// post has not caught up (`ChannelFollows.displayCounts`, 2026-10-29 review fix).
    var channelCounts: (String, [String: Int]) -> [String: Int] = { $1 }
    var dark: Bool
    var selecting: Bool
    /// Their `wasShowingSelectionUI`: was selection mode up on the PREVIOUS pass. See
    /// `MessageRowModel.wasSelecting` for why leaving selection needs two passes.
    var wasSelecting: Bool
    var selectedIds: Set<String>
    var highlightId: String?
    var firstUnreadId: String?
    var chatColor: ChatColorSpec?
    var onWallpaper: Bool
    var wallpaperBlur: WallpaperBlurState?
    var otherLastReadMillis: Double
    /// 2026-09-25: when my messages reached the other phone (1:1). 0 = not known / group.
    var otherDeliveredMillis: Double = 0
    var iBlocked: Bool
    var searchTerm: String
    var nameFor: (String) -> String
    var avatarFor: (String) -> String?
    /// owner 2026-10-18: a group member's Role as the chip shows it, or nil. Groups only.
    var roleFor: (String) -> String? = { _ in nil }
    /// The colour name of that member's tag (owner 2026-10-28), or nil.
    var roleColorFor: (String) -> String? = { _ in nil }
    var resolveOriginal: (String) -> Message?
    /// The quoted message is known to be deleted for everyone, even when `resolveOriginal` cannot
    /// see it: a group drops its tombstones from the list, and an old original is not loaded (audit H5).
    var quoteDeleted: (String) -> Bool = { _ in false }
    /// The quoted message was sent while I had its author blocked: never shown, so a reply to it
    /// says "Not available" instead of the copy of its words the reply carries.
    var quoteHiddenByBlock: (String) -> Bool = { _ in false }
    /// Is this story still live? A reply to one that has expired shows "Story unavailable" rather
    /// than an empty frame, and the card stops being a door.
    var storyIsLive: (_ storyId: String, _ author: String) -> Bool = { _, _ in true }
    /// 2026-09-24 feature-audit: my edits the server has not answered yet. Their footer shows the
    /// sending clock, as the reference app does for an edit in flight.
    var editPendingIds: Set<String> = []
    /// The disappearing timer in force now, and since when (the notice that set it, or nil when that
    /// notice is outside the loaded window). See `provisionalExpiry`.
    var timer: (since: Date?, seconds: Int)? = nil
    /// The Restricted chat request notice I can answer right now, or nil. See `ThreadView`.
    var liveRestrictRequestId: String? = nil
    /// The other person's name in a 1:1 (story mention cards: "You mentioned NAME in a story").
    var otherName: String = ""
}

/// ⚠️ `@MainActor` because it genuinely is main-actor work, not to silence a warning: it reads
/// `AuthService`, `PlayedVoice`, `HiddenMessages`, `VerificationIndex` and `MediaOpenRects`, and it
/// is only ever called from ThreadView's body. Saying so is cheaper than a nonisolated shim that
/// pretends otherwise.
@MainActor
enum MessageRowModelBuilder {

    /// Can this message be drawn by the UIKit row system yet?
    ///
    /// ⛔ THIS IS THE MIGRATION'S ONE ROUTING GATE. Phase 1 owns text, jumbomoji, tombstones,
    /// replies, reactions, group chrome, chat colours, system/pin/call rows and every row
    /// decoration. Media and the cards arrive in phases 2 and 3 — until then those messages return
    /// nil here and keep the old path, so nothing is drawn wrong while the port is under way.
    ///
    /// ⚠️ A KIND THAT IS NOT LISTED MUST NOT FALL THROUGH TO "text". That mistake has already been
    /// made once on this gate: a system notice matched "plain delivered text" and rendered as a
    /// blue bubble with delivery ticks. Every unhandled kind is refused explicitly at the bottom.
    static func canRender(_ m: Message) -> Bool {
        if m.deleted { return true }                       // the tombstone capsule
        if m.isCall { return true }
        if m.isSystem { return true }
        if m.pinNotice != nil { return true }
        // ⚠️ VIEW-ONCE FIRST, before the kind tests below say yes to its photo. A view-once message
        // is a PILL, not its media — the picture must never be drawn in the list, which is the
        // whole security property. `bubble()` sends it to `.pill` for the same reason.
        if m.viewOnce { return true }
        // ⛔ PENDING MEDIA BEFORE THE KIND TESTS, and this ordering is a real bug fixed rather than
        // a tidy-up. `isImage` is true for a message that merely has `localImageData` — which is
        // exactly what an optimistic, still-uploading photo has — so with the kind tests first a
        // pending photo matched "photo" and was drawn as a finished media bubble instead of the
        // pending placeholder. The old `content` chain tested pending first for the same reason.
        if m.pendingMediaKind != nil || m.isPendingImage { return true }
        if m.isImage || m.isVideo || m.isGif { return true }
        if m.isAlbum || m.isFile { return true }
        if m.isAudio { return true }
        if m.locationCard != nil || m.contactCard != nil { return true }
        if m.poll != nil { return true }
        if m.isFeatureMarker { return true }               // the "update the app" notice
        // ⛔ TOTAL. Every branch above returns true and so does this one: there is no message the
        // UIKit rows cannot draw, and nothing routes to SwiftUI any more. A message with no kind
        // and no words is a data anomaly, and it draws an empty bubble — which is exactly what the
        // old `content` chain's final `else` did with it.
        //
        // ⚠️ THE LIST IS 100% UIKIT FROM HERE. This function is kept rather than deleted because it
        // is the readable statement of WHICH kinds exist, and because a future kind added to
        // `Message` should have to come here and say what it is instead of silently falling into
        // "text" — the mistake that once drew a system notice as a blue bubble with delivery ticks.
        return true
    }

    static func model(for msg: Message, at index: Int, ctx: MessageRowContext,
                      isFirstInCluster: Bool, isLastInCluster: Bool,
                      dateHeader: String?, topSpacing: CGFloat) -> MessageRowModel? {
        guard canRender(msg) else { return nil }

        let header: NoticeRow? = dateHeader.map {
            NoticeRow(text: $0, symbol: nil, style: .pill, tapTargetId: nil,
                      onWallpaper: ctx.onWallpaper, wallpaperBlur: ctx.wallpaperBlur)
        }

        let content: MessageRowModel.Content
        if let pin = msg.pinNotice {
            let who = msg.authorId == ctx.me ? "You" : ctx.nameFor(msg.authorId)
            content = .notice(NoticeRow(text: "\(who) pinned \(pin.label)", symbol: nil, style: .pill,
                                        tapTargetId: pin.messageId,
                                        onWallpaper: ctx.onWallpaper, wallpaperBlur: ctx.wallpaperBlur))
        } else if msg.isFeatureMarker, msg.contactCard == nil, msg.locationCard == nil, msg.poll == nil {
            content = .notice(NoticeRow(
                text: "This message was sent using a newer version of the app. Update to the latest version to view it.",
                symbol: nil, style: .unsupported, tapTargetId: nil,
                onWallpaper: ctx.onWallpaper, wallpaperBlur: ctx.wallpaperBlur))
        } else if let sm = msg.storyMention, !ctx.isGroup {
            content = .notice(storyMentionRow(msg, sm, ctx: ctx))
        } else if msg.isSystem {
            content = .notice(systemNotice(msg, ctx: ctx))
        } else if msg.isCall {
            content = .call(callRow(msg, ctx: ctx))
        } else {
            content = .bubble(bubble(msg, ctx: ctx, first: isFirstInCluster, last: isLastInCluster))
        }

        return MessageRowModel(
            id: msg.rowId,
            dateHeader: header,
            showsUnreadDivider: msg.id == ctx.firstUnreadId,
            content: content,
            topSpacing: topSpacing,
            selecting: ctx.selecting,
            wasSelecting: ctx.wasSelecting,
            selected: ctx.selectedIds.contains(msg.id),
            selectionTint: selectionTint(ctx),
            highlighted: msg.id == ctx.highlightId,
            onWallpaper: ctx.onWallpaper,
            wallpaperBlur: ctx.wallpaperBlur)
    }

    // ── The bubble ──

    private static func bubble(_ msg: Message, ctx: MessageRowContext,
                               first: Bool, last: Bool) -> BubbleRow {
        // In a channel nobody's post is "mine" on screen; `authored` still drives its sending state.
        let authored = msg.authorId == ctx.me
        let isMe = authored && !ctx.isChannel
        let text = msg.safeText

        let body: BubbleBody
        if msg.deleted {
            // 2026-09-24 feature-audit: an admin's delete of my message is not "You deleted".
            body = .tombstone(isMe && msg.deletedBy == nil ? "You deleted this message" : "This message was deleted")
        } else if msg.viewOnce {
            body = .pill(viewOncePill(msg, ctx: ctx, isMe: isMe))
        // ⛔ A STICKER HAS NO BUBBLE — owner 2026-10-17. The media box with no fill and no corners,
        // the art aspect-fit in about 160pt, the time on its own capsule like a bare photo.
        } else if let s = msg.sticker {
            body = .media(stickerBody(msg, s, ctx: ctx))
        // ⛔ A VOICE NOTE IS NEVER A PLACEHOLDER PILL. `ChatService.sendAudio` writes the duration
        // and the true waveform into the document BEFORE the first byte is uploaded, and says why:
        // "the recipient can be shown a REAL voice bubble immediately". The generic pending branch
        // below was overriding that and drawing a text-shaped bubble with a spinner and the words
        // "Voice message" — his screenshot, 2026-08-26: "when it is loading don't change the whole
        // voice bubble". A photo has nothing to draw before its bytes arrive; a voice note has
        // everything except the URL, which is needed only to press play.
        // ⛔ AND A PHOTO IS NEVER A PLACEHOLDER PILL EITHER — his screenshot, 2026-08-27: sending or
        // forwarding a picture draws a bubble with a spinner and the word "Photo" where the picture
        // should be. The SwiftUI copy of this row has always excluded it (`pendingKind != "image"`)
        // and this builder never got that exclusion, so the two halves of the app disagreed and the
        // UIKit list is the one on screen.
        //
        // ⚠️ A FORWARD IS WHY IT SHOWS UP AT ALL. `pendingMediaKind` is nil whenever local bytes are
        // present, which keeps an ordinary send out of it — the sender's own copy is the better
        // picture. A forward has no local bytes: nothing was picked from the library, it is a
        // re-send of something already on the server. So the sender lands here too, and unlike a
        // video or a document a photo HAS something to draw meanwhile — the blurhash and thumbnail
        // carried over from the original, at the real aspect ratio, which is exactly what
        // `isPendingImage` was written for.
        // ⛔ AND NOR IS A VIDEO — owner, 2026-09-26, a screenshot of a spinner and the word "Video"
        // where the clip should be. `announceVideo` writes the poster, duration and pixel size
        // BEFORE the transcode, so there is always a real bubble to draw; the ring on it says the
        // clip is still coming.
        } else if let pending = msg.pendingMediaKind, pending != "audio", pending != "image",
                  pending != "video" {
            // Still being prepared: a spinner and a word. The real bubble arrives when the write
            // lands, carrying the poster and the dimensions the placeholder cannot know.
            body = .pill(BubbleBody.PillBody(
                symbol: "arrow.up.circle", label: pendingLabel(pending),
                spent: false, opens: false, busy: true))
        // `isImage` needs a URL or local bytes, so a pending photo is not `isImage` yet and has to be
        // named here as well — the same footnote the voice branch below carries, for the same reason.
        } else if msg.isImage || msg.isVideo || msg.isGif || msg.isPendingImage
                    || msg.pendingMediaKind == "video" {
            var m = mediaBody(msg, ctx: ctx)
            // A photo or video that quotes a channel post carries the card (owner 2026-11-07).
            if m.kind == .photo || m.kind == .video { m.quoteCard = msg.quoteId.map { quoteBody($0, cid: ctx.cid, mid: msg.id) } }
            body = .media(m)
        } else if msg.isAlbum {
            var a = albumBody(msg, ctx: ctx)
            a.quoteCard = msg.quoteId.map { quoteBody($0, cid: ctx.cid, mid: msg.id) }
            body = .album(a)
        } else if msg.isFile {
            body = .file(fileBody(msg))
        } else if let loc = msg.locationCard {
            body = .location(BubbleBody.LocationBody(
                lat: loc.lat, lon: loc.lon,
                // A share with no label says "Location", as it always did. The COORDINATES are
                // deliberately not on the face of it: the map replaced them, and a coordinate is
                // the one thing about a place that tells you nothing.
                label: (loc.label?.isEmpty == false ? loc.label! : "Location")))
        // ⚠️ `isAudio` REQUIRES A URL OR LOCAL BYTES, so an uploading note is not `isAudio` yet —
        // it has to be named here as well, or it falls through to a plain text bubble.
        } else if msg.isAudio || msg.pendingMediaKind == "audio" {
            body = .voice(voiceBody(msg, ctx: ctx))
        } else if let poll = msg.poll {
            body = .poll(BubbleBody.PollBody(
                pollId: poll.id, messageId: msg.id, question: poll.question,
                options: poll.options, multiple: poll.multiple,
                correct: poll.correct, endsAt: poll.endsAt, closed: msg.pollClosed,
                // A channel never shows who voted (2026-10-29, S4): no faces on its poll bubble.
                hideVoters: poll.hideVoters || ctx.isChannel,
                inChannel: ctx.isChannel))
        } else if let card = msg.contactCard {
            body = .contact(BubbleBody.ContactBody(
                uid: card.uid, name: card.name, photo: card.photo,
                // No button for my own card, and none for the person I am already talking to —
                // there is no chat to open, and a button that does nothing is worse than none.
                canMessage: card.uid != ctx.me && ChatService.convId(ctx.me, card.uid) != ctx.cid))
        } else if text.jumbomojiCount > 0, msg.linkPreview == nil, msg.quoteId == nil,
                  msg.replyTo == nil || msg.replyTo?.isStatus == true {
            // Borderless applies only to a message with nothing else in the box: an emoji-only
            // REPLY keeps its bubble, because the quote shares that box with it, and so does one
            // carrying a link card.
            //
            // ⚠️ EXCEPT A STORY REPLY, which is the owner's own ruling. Its card is drawn ABOVE the
            // bubble, never inside it, so nothing shares the box and there is no reason to draw one
            // — an emoji story reply looks like an emoji message with a card on top.
            body = .jumbomoji(text)
        } else {
            body = .text(BubbleBody.TextBody(
                text: text,
                searchTerm: ctx.searchTerm,
                mentionTokens: msg.mentions.map { "@\(ctx.nameFor($0))" },
                // Only what TRAVELLED with the message renders — there is no viewer-side fetch, so
                // an older message without an embedded preview stays a plain link.
                // A call link takes the call card whatever preview travelled with it: the web page
                // behind the link knows nothing about the call, and older messages carry none.
                // A quoted channel post takes the card's place (owner 2026-11-06, `quoteBody`).
                linkPreview: msg.quoteId.map { quoteBody($0, cid: ctx.cid, mid: msg.id) } ?? callLinkPreview(text) ?? msg.linkPreview.map(linkPreviewBody),
                bold: text == msg.text ? msg.boldRanges : []))
        }

        // MY fill is the chat colour if one is set, else the default blue — a colour is a colour and
        // a wallpaper does not change that. THEIRS is whatever `Theme.receivedSurface` decides, the
        // same call the old bubbles made, so a chat cannot draw two different incoming surfaces
        // depending on which route a message took.
        //
        // A tombstone takes this same fill: the owner reversed the neutral placeholder deliberately
        // ("always use same color like other bubble, if i change color change it"). What keeps it
        // quieter than the message it replaced is that it is a CAPSULE and carries no time and no
        // tick — not a different colour.
        // A bubble style the sender chose (owner 2026-11-06, `BubbleStyles`): its fill and its own
        // text colour, on their side and mine alike. Unknown ids and deleted messages draw as before.
        // Text bubbles only (5-angle check): poll, location and contact cards draw their own white
        // details for my side, which a pastel would swallow.
        // Never in a channel or the official chat, nor in a group whose admins turned styles off
        // (owner 2026-11-07, SPEC section 5): the `bs` stays on the message, only the drawing is skipped.
        let bubbleStyle: BubbleStyle? = {
            // ⛔ 1:1 CHATS ONLY (owner 2026-11-10: "bubble style is only chat user, not groups and
            // channels; groups just use Bubble Color"). A group draws its plain / Bubble Color fill.
            guard !msg.deleted, !ctx.isChannel, !ctx.isGroup, !ctx.stylesOff, case .text = body else { return nil }
            return BubbleStyles.find(msg.bubbleStyle)
        }()
        // ⛔ EVERY STYLED BUBBLE WEARS ITS PICTURE (owner 2026-11-07, replacing SPEC section 3's
        // last-of-run rule): with last-only, sending a new message took the art off the one before,
        // which read as the old style being erased. Colour styles' decorations stay last-of-run.
        let picture: PictureStyle? = bubbleStyle?.picture
        let fill: BubbleFill = bubbleStyle.map { s -> BubbleFill in
            let look = s.look(ctx.dark)
            // Soft Glass with no wallpaper behind: a blur of the plain page is nearly invisible,
            // so it takes its own soft colour there.
            if look.glass && !ctx.onWallpaper { return .solid(look.fill.first ?? 0xF2F2F7) }
            return BubbleStyles.fill(look)
        } ?? (isMe ? myFill(ctx) : receivedFill(ctx))

        let tick: BubbleTicks.Kind
        if ctx.isChannel, authored, !msg.deleted, msg.sendState == .sending {
            tick = .sending   // my post on its way; a sent post shows no tick (it has no reader)
        } else if !isMe || msg.deleted {
            tick = .none
        } else {
            switch msg.sendState {
            case .sending: tick = .sending
            case .failed: tick = .failed
            case nil where ctx.editPendingIds.contains(msg.id):
                tick = .sending   // 2026-09-24 feature-audit: an edit still waiting for the server
            case nil where msg.held:
                tick = .sent      // held by their block: never delivered, not even after an unblock
            case nil:
                // A blocked contact's lastRead is ignored, matching what the old path passed in as
                // `otherLastRead` — or a blocked chat shows ✓✓ on one row class and ✓ on another.
                let sentMs = msg.createdAt.timeIntervalSince1970 * 1000
                let read = !ctx.iBlocked && ctx.otherLastReadMillis >= sentMs
                // 2026-09-25: one tick = on the server, two faded = on their phone, two solid = read.
                let delivered = !ctx.iBlocked && ctx.otherDeliveredMillis >= sentMs
                tick = read ? .read : (delivered ? .delivered : .sent)
            }
        }

        // ⛔ NO NAME ON BARE MEDIA (owner 2026-10-18, build 973: "a picture in a group gets a band
        // with the name; no name on a sticker, gif or photo, like the reference"). A photo, video,
        // gif, album or sticker with no caption, quote or Forwarded line is drawn as in a 1:1 chat;
        // the avatar beside the run still says who sent it. With words on it, the name stays.
        let bareMedia: Bool = {
            guard msg.replyTo == nil, !msg.forwarded, !msg.deleted else { return false }
            switch body {
            case .media(let m): return m.caption == nil && m.quoteCard == nil
            case .album(let a): return a.caption == nil && a.quoteCard == nil
            default: return false
            }
        }()
        let mediaBody: Bool = {
            switch body {
            case .media, .album: return true
            default: return false
            }
        }()
        var sender: SenderChrome?
        if ctx.isGroup, !isMe, !ctx.isChannel {
            sender = SenderChrome(
                uid: msg.authorId,
                name: ctx.nameFor(msg.authorId),
                colorSeed: msg.authorId,
                showsName: first && !bareMedia,
                showsAvatar: last,
                startsRun: first,
                avatarUrl: ctx.avatarFor(msg.authorId),
                verified: VerificationIndex.of(msg.authorId)?.showsBadge == true,
                role: ctx.roleFor(msg.authorId),
                roleColor: ctx.roleColorFor(msg.authorId))
        } else if ctx.isChannel, msg.quoteId != nil, !msg.deleted, !ctx.channelTitle.isEmpty, !mediaBody {
            // Not over a picture, video or album (owner 2026-11-07: the name sat in a band above the photo).
            // ⛔ A QUOTE POST SAYS WHOSE IT IS (owner 2026-11-07, "show my channel name in quote
            // posts"): the channel's name at the top of the bubble, over its words and the quoted
            // card, so the card's own channel name is not read as the poster. Quote posts only.
            sender = SenderChrome(
                uid: ctx.cid, name: ctx.channelTitle, colorSeed: ctx.cid,
                showsName: true, showsAvatar: false, startsRun: true,
                avatarUrl: nil, verified: ctx.channelVerified, nameOnly: true)
        }

        var storyReply: StoryReplyChrome?
        if let reply = msg.replyTo, reply.isStatus, !msg.deleted {
            let live = ctx.storyIsLive(reply.id, reply.authorId)
            let mine = reply.authorId == ctx.me
            storyReply = StoryReplyChrome(
                storyId: reply.id, authorId: reply.authorId,
                caption: isMe ? (mine ? "You replied to your story" : "You replied to their story")
                              : (mine ? "\(ctx.nameFor(msg.authorId)) replied to your story"
                                      : "\(ctx.nameFor(msg.authorId)) replied to their story"),
                thumbUrl: reply.storyThumbUrl,
                anchorKey: "storyreply-\(msg.id)",
                unavailable: !live,
                opens: live,
                isReaction: reply.isReaction == true)
        }

        var quote: QuoteChrome?
        if let reply = msg.replyTo, !reply.isStatus, !msg.deleted {
            let original = ctx.resolveOriginal(reply.id)
            let blocked = ctx.quoteHiddenByBlock(reply.id)
            // Deleted for everyone, seen or not in the list (audit H5): the words it carries are a
            // copy of the deleted message, so they are not drawn.
            let gone = ctx.quoteDeleted(reply.id)
            quote = QuoteChrome(
                targetId: reply.id,
                authorLine: reply.authorId == ctx.me ? "You" : ctx.nameFor(reply.authorId),
                snippet: blocked ? "Not available"
                    : (gone ? "This message was deleted" : replyLabel(reply: reply, original: original)),
                thumb: blocked || gone ? .none : replyThumb(original),
                isStatus: false)
        }

        // A tombstone is a placeholder, never a reactable message. Empty here is STRUCTURAL: every
        // badge, overhang and tap surface derives from this one value, so a deleted row cannot
        // render or respond to reactions no matter what the data still says.
        let reactions: [ReactionChip] = (msg.deleted || msg.isStoryReaction) ? [] : reactionChips(msg, ctx: ctx)

        return BubbleRow(
            isMe: isMe,
            body: body,
            fill: fill,
            // A picture-styled bubble stands alone (owner 2026-11-07): no run corners, its own shape
            // while the picture decodes: the picture's own corner radius, so it never flashes square.
            radii: picture.map { BubbleRadii.uniform($0.cornerRadius) } ?? .cluster(isMe: isMe, first: first, last: last),
            // ⛔ CLAMPED TO NOW. A pending message carries THIS phone's clock while everything it is
            // compared against carries the server's, and the repository maintains a whole clock-offset
            // median because the two disagree. Ordering already corrects for it; display did not.
            //
            // Clock eight minutes fast at 23:55: your own bubble read "12:03 AM", a "Today" separator
            // was inserted above it for tomorrow, and a second later the server echo dropped the time
            // back to "11:55 PM" and the separator vanished. Away from midnight it was still an
            // eight-minute jump on every send.
            //
            // Theirs applies `clampBeforeNow` on every display path for exactly this — a timestamp in
            // the future is never a fact about a message, it is a fact about the clock.
            meta: MetaChrome(timeText: min(msg.createdAt, Date()).formatted(date: .omitted, time: .shortened),
                             edited: msg.edited && !msg.deleted,
                             // ⛔ MY OWN POST SHOWS 1 THE MOMENT IT LANDS (owner 2026-10-30: "it counts
                             // now but a bit behind other apps"). The server counts the author's view
                             // as the post is created (onNewMessage), so 1 is already true; waiting for
                             // the server's write only made it appear late.
                             // Not while it is still on its way (offline): the clock says so, and
                             // a "1" beside it read as posted (Android check, 2026-11-06).
                             // ⛔ FROM THE FIRST FRAME (owner 2026-11-10: the eye and its count
                             // arrived after the post was sent, a late pop). My own post shows its
                             // 1 while it goes out too; the spinning clock beside it still says it
                             // is on its way. A failed send shows none.
                             views: ctx.isChannel && !msg.deleted && msg.sendState != .failed
                                 ? (msg.authorId == ctx.me ? max(msg.views, 1) : msg.views) : nil,
                             signature: ctx.isChannel && ctx.signPosts && !msg.deleted ? ctx.nameFor(msg.authorId) : nil,
                             tick: tick,
                             bornAt: msg.createdAt,
                             // A tombstone is already gone; putting a countdown on one would be
                             // promising to remove something that has been removed.
                             expiresAt: msg.deleted ? nil : (msg.expiresAt ?? provisionalExpiry(msg, ctx: ctx))),
            sender: sender,
            quote: quote,
            storyReply: storyReply,
            forwarded: msg.forwarded && !msg.deleted,
            forwardFrom: msg.forwarded && !msg.deleted ? msg.forwardSource?.title : nil,
            reactions: reactions,
            showsFailedBadge: authored && msg.sendState == .failed,
            // Theirs only, and only on a wallpaper — the reference guards it `hasWallpaper,
            // isIncoming`, and an outgoing bubble never wears one.
            rim: (!isMe && ctx.onWallpaper) || bubbleStyle?.look(ctx.dark).glass == true,
            // A story react-bar emoji can be swiped to reply too (owner 2026-11-08); it still takes
            // no long press and no reaction of its own.
            canSwipeToReply: msg.sendState == nil && !msg.deleted,
            // Media whose single tap opens something. Deliberately NOT gifs: a gif plays where it
            // sits and opens nothing, so there is no tap for the recogniser to hold up — which is
            // why it keeps the double-tap shortcut and the others give it away.
            opensOnTap: msg.isImage || msg.isVideo || msg.isAlbum || msg.isFile,
            canDoubleTapReact: msg.sendState == nil && !msg.deleted && !msg.isStoryReaction,
            textHex: bubbleStyle.map { $0.look(ctx.dark).text },
            // Decorations: the sender chose them, this is a text bubble, and it is the LAST of its run.
            decor: {
                // Not on a failed send (the red retry mark sits there), and not over a group's avatar.
                guard let s = bubbleStyle, s.picture == nil, msg.bubbleDecor, last, case .text = body, msg.sendState != .failed else { return [] }
                return BubbleDecorSets.placed(styleId: s.id, isMe: isMe, dark: ctx.dark, first: first,
                                              besideAvatar: !isMe && ctx.isGroup && !ctx.isChannel)
            }(),
            picture: picture?.id,
            pictureRim: picture?.lightText == true && ctx.dark,
            wide: ctx.isChannel && !msg.deleted,
            shareable: ctx.isChannel && !msg.deleted && !ctx.noForwarding,
            quoteBar: postBar(msg, ctx: ctx))
    }

    /// ⛔ "REPLIES · QUOTES" UNDER A CHANNEL POST (owner 2026-11-06). Shown once the post is out, when
    /// it can take replies or has been quoted. Replies off (the channel's or the post's) leaves only
    /// the quotes; neither leaves no bar.
    private static func postBar(_ msg: Message, ctx: MessageRowContext) -> QuoteBarChrome? {
        // ⛔ FROM THE FIRST FRAME (owner 2026-11-10: the post sent small, then "popped" bigger when
        // the Reply bar arrived with the server's answer). A post still sending wears its bar
        // already; only a FAILED send goes without (its retry mark sits there).
        guard ctx.isChannel, !msg.deleted, msg.sendState != .failed else { return nil }
        // Off hides the Reply part entirely (owner 2026-11-07: "in post don't show Reply"); the bar
        // stays only for quotes.
        let showReplies = !msg.repliesOff(channelDefault: ctx.repliesOff)
        let quotes = ctx.quotesOff ? 0 : msg.quoteCount
        guard showReplies || quotes > 0 else { return nil }
        return QuoteBarChrome(count: quotes, faces: quotes > 0 ? msg.quoteFaces : [],
                              replies: showReplies ? msg.replyCount : nil,
                              replyFaces: showReplies && msg.replyCount > 0 ? msg.replyFaces : [])
    }

    /// ⛔ THE TIMER ICON FROM THE FIRST FRAME — owner, 2026-09-29: messages sent right after the
    /// timer was set showed no icon, or grew one later and shifted. `expiresAt` is the server's
    /// (`onNewMessage` stamps it after the message lands), so my own bubble had no icon while
    /// sending, and gained one when the stamp came back. The reference app carries the timer on
    /// the message from the moment it is written. Here: a message the server has not stamped yet,
    /// written after the notice that turned the current timer on, draws with the time it will get.
    /// Drawing only; hiding still waits for the real stamp (`ThreadRepository`).
    private static func provisionalExpiry(_ m: Message, ctx: MessageRowContext) -> Date? {
        guard let t = ctx.timer, t.seconds > 0 else { return nil }
        // Notice out of the loaded window: only messages still in flight or just sent can be new.
        let since = t.since ?? Date().addingTimeInterval(-120)
        guard m.createdAt >= since else { return nil }
        return m.createdAt.addingTimeInterval(TimeInterval(t.seconds))
    }

    private static func mediaBody(_ m: Message, ctx: MessageRowContext) -> BubbleBody.MediaBody {
        let kind: BubbleBody.MediaBody.Kind = m.isGif ? .gif : (m.isVideo ? .video : .photo)
        let caption = m.text.isEmpty ? nil : BubbleBody.TextBody(
            text: m.text, searchTerm: ctx.searchTerm,
            mentionTokens: m.mentions.map { "@\(ctx.nameFor($0))" }, bold: m.boldRanges)
        let duration: String? = {
            guard kind == .video, let d = MediaDuration.clean(m.duration), d > 0 else { return nil }
            let s = Int(d)
            return String(format: "%d:%02d", s / 60, s % 60)
        }()
        return BubbleBody.MediaBody(
            kind: kind,
            url: m.imageUrl,
            enc: m.enc,
            posterUrl: m.thumbUrl,
            posterEnc: m.thumbEnc,
            localData: m.localImageData,
            blurhash: m.blurhash,
            inlineThumbBase64: m.thumb,
            thumbCacheId: m.rowId,
            // The MESSAGE id, not the row id — see MediaBody.flightKey.
            flightKey: MediaOpenRects.key(.chat, m.id),
            pixelWidth: m.width,
            pixelHeight: m.height,
            durationText: duration,
            caption: caption,
            uploading: m.sendState == .sending || m.uploadingLive,
            sendFailed: m.sendState == .failed,
            clientId: m.clientId,
            cancellable: m.authorId == ctx.me && m.sendState == .sending,
            // A gif is a public url with nothing to hold back; a photo goes through the
            // auto-download policy, which may keep it behind a tap.
            gated: kind == .photo,
            videoUrl: kind == .video ? m.videoUrl : nil,
            messageId: m.id,
            authorId: m.authorId)
    }

    /// 2026-10-17 chat stickers. The art is drawn by `RowStickerView`: a built-in one from this
    /// phone's pack (the public `imageUrl` copy only when the pack lacks it), one I made through the
    /// photo decrypt path. No caption, no gate (a sticker is small and is the whole message).
    private static func stickerBody(_ m: Message, _ s: Sticker, ctx: MessageRowContext) -> BubbleBody.MediaBody {
        BubbleBody.MediaBody(
            kind: .sticker,
            url: m.imageUrl,
            enc: m.enc,
            posterUrl: nil,
            posterEnc: nil,
            localData: m.localImageData,
            blurhash: nil,
            inlineThumbBase64: nil,
            thumbCacheId: m.rowId,
            flightKey: MediaOpenRects.key(.chat, m.id),
            pixelWidth: m.width ?? 512,
            pixelHeight: m.height ?? 512,
            durationText: nil,
            caption: nil,
            uploading: m.sendState == .sending && s.source == .mine,
            sendFailed: m.sendState == .failed,
            clientId: m.clientId,
            cancellable: false,
            gated: false,
            messageId: m.id,
            authorId: m.authorId,
            sticker: s)
    }

    private static func albumBody(_ m: Message, ctx: MessageRowContext) -> BubbleBody.AlbumBody {
        // An optimistic album has only `localAlbum`; a receiver's has only `albumSizes` until the
        // tiles land. Hidden-for-me tiles are dropped, but never while the album is still
        // optimistic — nothing can have been hidden yet.
        let optimistic = !m.localAlbum.isEmpty
        let count = optimistic ? m.localAlbum.count : m.album.count
        var visible: [Int] = optimistic
            ? Array(0..<count)
            : (0..<count).filter { !HiddenMessages.isHidden("\(m.id)-\($0)") }
        // ⛔ AN X'd TILE LEAVES AT ONCE — owner, 2026-09-29: "send several, cancel one, it stays until
        // the others finish uploading". The send loop already skips it; the tile only dimmed. Its
        // KEY keeps the original index (`i` below), so every other tile's ring and done mark still
        // match. Never below two while optimistic: the mosaic is built for two and up, and a lone
        // survivor becomes a photo once the send lands (`Message.init`), so the last X'd one just dims.
        // ⛔ EVEN DOWN TO ONE — owner, 2026-09-29, two photos, one X'd: "it stays blurred until the
        // other finishes; make it go at once, like the reference". The survivor is drawn alone, as
        // a one-tile group (`MediaGroupLayout.solve` has a one-item case, full width), exactly what
        // it becomes when the send lands (`Message.init` reads a one-item album as a photo).
        var cancelledSome = false
        if optimistic, let cid = m.clientId {
            let kept = visible.filter { !MediaSend.shared.isItemCancelled(MediaSend.itemKey(cid, $0)) }
            if !kept.isEmpty, kept.count < visible.count { visible = kept; cancelledSome = true }
        }
        // The two-slot floor is for a receiver's placeholder grid; an X'd optimistic group shows
        // exactly what is left.
        let n = cancelledSome ? visible.count : max(visible.count, 2)
        let shown = min(n, 10)          // the album ceiling; the rest rides a "+N" on the last tile

        var tiles: [BubbleBody.AlbumBody.Tile] = []
        for slot in 0..<shown {
            let i = slot < visible.count ? visible[slot] : slot
            // ⚠️ THE ASPECT HAS TO BE RIGHT BEFORE THE TILES EXIST, or the mosaic solves one
            // arrangement now and a different one when the real tiles land — it changes under the
            // reader. Three sources, best first.
            var aspect: Double = 1
            if m.album.indices.contains(i), m.album[i].height > 0 {
                aspect = m.album[i].width / m.album[i].height
            } else if m.albumSizes.indices.contains(i), m.albumSizes[i].count == 2,
                      m.albumSizes[i][1] > 0 {
                aspect = m.albumSizes[i][0] / m.albumSizes[i][1]
            } else if m.localAlbum.indices.contains(i),
                      let ui = UIImage(data: m.localAlbum[i]), ui.size.height > 0 {
                aspect = Double(ui.size.width / ui.size.height)
            }
            let item = m.album.indices.contains(i) ? m.album[i] : nil
            let isVideo = m.localAlbumIsVideo.indices.contains(i) ? m.localAlbumIsVideo[i]
                                                                  : (item?.isVideo ?? false)
            let duration: String? = {
                guard let d = MediaDuration.clean(item?.duration), d > 0 else { return nil }
                let s = Int(d)
                return String(format: "%d:%02d", s / 60, s % 60)
            }()
            tiles.append(BubbleBody.AlbumBody.Tile(
                url: item?.imageUrl, enc: item?.enc, aspect: aspect,
                isVideo: isVideo, durationText: duration,
                localData: m.localAlbum.indices.contains(i) ? m.localAlbum[i] : nil,
                flightKey: MediaOpenRects.key(.chat, "\(m.id)-\(i)"),
                uploadKey: m.clientId.map { MediaSend.itemKey($0, i) },
                videoUrl: isVideo ? item?.videoUrl : nil,
                videoEnc: isVideo ? item?.videoEnc : nil,
                itemId: "\(m.id)-\(i)",
                authorId: m.authorId))
        }
        let caption = m.text.isEmpty ? nil : BubbleBody.TextBody(
            text: m.text, searchTerm: ctx.searchTerm,
            mentionTokens: m.mentions.map { "@\(ctx.nameFor($0))" }, bold: m.boldRanges)
        return BubbleBody.AlbumBody(
            tiles: tiles, extra: n - shown, caption: caption,
            // ⚠️ `|| m.uploading` — the RECEIVER's half, and it was missing while the single-photo
            // path two hundred lines up has always had it. `sendState` exists only on my own
            // optimistic message, so an album still being uploaded by the other person drew blurred
            // tiles with no indicator at all: the wire carries `uploading: true` for exactly this
            // and nothing read it. See [[kulan-media-send-order]] — a message exists before its
            // bytes do, on purpose, and the ring is what says so.
            uploading: m.sendState == .sending || m.uploadingLive,
            sendFailed: m.sendState == .failed,
            cancellable: m.authorId == ctx.me && m.sendState == .sending,
            blurhash: m.blurhash,
            inlineThumbBase64: m.thumb, thumbCacheId: m.rowId)
    }

    /// A view-once photo or a one-time voice note, in the owner's two sizes (2026-11-07, with his
    /// design picture beside the reference app's chat):
    ///   UNOPENED, the big card: a 40pt dashed ring holding a bold "1", "Photo" / "Voice" over a
    ///   second line ("Tap to view" / "Tap to play" for theirs, "Not opened yet" for mine).
    ///   OPENED, the small one-line bubble: an empty 24pt ring and "Opened" in italic.
    ///
    /// ⚠️ THE TWO SIDES READ DIFFERENT FACTS. The recipient's bubble is spent by their own open
    /// (`ViewedOnce`, this phone) or by the server's burn (`consumed`, another of their phones).
    /// The SENDER's "Opened" is the other person's open only. The sender can never open their own
    /// (owner 2026-11-07, replacing 2026-10-03's one view for the sender), so mine never taps.
    private static func viewOncePill(_ m: Message, ctx: MessageRowContext,
                                     isMe: Bool) -> BubbleBody.PillBody {
        let voice = m.isAudio
        let usedHere = ViewedOnce.contains(m.id)
        let opened = isMe ? m.consumed : (usedHere || m.consumed)
        let canOpen = !isMe && !usedHere && !opened
        // Fetch the sealed bytes while the bubble is on screen, so opening only decrypts.
        if voice, !isMe, canOpen, m.sendState == nil {
            let id = m.id, url = m.audioUrl
            Task { @MainActor in OneTimeVoicePrefetch.start(id: id, audioUrl: url) }
        }
        if opened {
            return BubbleBody.PillBody(symbol: "", label: "Opened", spent: true, opens: false,
                                       busy: false, onceRing: .empty)
        }
        let sub = isMe ? "Not opened yet" : (voice ? "Tap to play" : "Tap to view")
        return BubbleBody.PillBody(symbol: "", label: voice ? "Voice" : "Photo", spent: false,
                                   opens: canOpen, busy: false, onceRing: .one, onceSubtitle: sub)
    }

    private static func pendingLabel(_ kind: String) -> String {
        switch kind {
        case "video": return "Video"
        case "audio": return "Voice message"
        case "file":  return "Document"
        case "album": return "Photos"
        default:      return "Photo"
        }
    }

    private static func voiceBody(_ m: Message, ctx: MessageRowContext) -> BubbleBody.VoiceBody {
        let secs = MediaDuration.whole(m.duration)
        return BubbleBody.VoiceBody(
            messageId: m.id,
            url: m.audioUrl, enc: m.enc, localData: m.localAudioData,
            bars: m.waveform,
            durationText: String(format: "%d:%02d", secs / 60, secs % 60),
            durationSeconds: secs,
            // The unread dot: a note I did not send, that is not my own optimistic copy, and that
            // `PlayedVoice` has no record of me listening to.
            unplayed: m.authorId != ctx.me && m.localAudioData == nil
                && PlayedVoice.shared.isUnplayed(cid: ctx.cid, messageId: m.id, createdAt: m.createdAt),
            // Still uploading: everything is drawn, only the disc spins. See `VoiceBody.loading`.
            loading: m.pendingMediaKind == "audio")
    }

    /// The call card for the first call link in `text`, or nil. The key is validated by the same
    /// parser the app uses when the link is tapped (`KulanApp.route`), so a card never offers to
    /// join something the tap would refuse. The title is always "Kulan Call": the link's own name
    /// is encrypted in its server document, and fetching it would make this builder async.
    private static func callLinkPreview(_ text: String) -> BubbleBody.LinkPreview? {
        // Cheap gate first: this runs for every text message the list builds.
        guard mentionsCallLink(text) else { return nil }
        let edges = CharacterSet(charactersIn: ".,;:!?()[]{}<>\"'")
        for token in text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }) {
            var s = String(token).trimmingCharacters(in: edges)
            guard mentionsCallLink(s) else { continue }
            if !s.lowercased().hasPrefix("https://") { s = "https://" + s }
            guard let url = URL(string: s), case .call(let key)? = KulanApp.route(from: url) else { continue }
            return BubbleBody.LinkPreview(
                shape: .call(key: key), url: url.absoluteString,
                title: "Fariin Call", desc: "Use this link to join a Fariin call",
                host: url.host ?? "fariin.com",
                imageUrl: nil, imageEnc: nil)
        }
        return nil
    }

    /// Both spellings of a call link: the path form on its own host (call.fariin.com/video/…,
    /// /voice/…) and the old fragment form (fariin.com/call/#key=…). A substring test only; the
    /// router above decides whether it is really a key.
    private static func mentionsCallLink(_ s: String) -> Bool {
        s.range(of: "call.fariin.com/", options: .caseInsensitive) != nil
            || s.range(of: "fariin.com/call", options: .caseInsensitive) != nil
    }

    private static func linkPreviewBody(_ p: Message.LinkPreviewData) -> BubbleBody.LinkPreview {
        // The handle is read from the URL rather than stored, so every message ever sent — including
        // ones from before profile cards existed — answers the same way with no migration.
        let handle = URL(string: p.url).flatMap { LinkPreviewService.profileHandle(in: $0) }
        if let code = URL(string: p.url).flatMap({ LinkPreviewService.groupCode(in: $0) }) {
            return groupLinkBody(p, code: code)
        }
        // A PUBLIC GROUP'S NAME LINK, fariin.com/<name> (owner 2026-10-21: "no Join button"): its
        // card was sent from `publicGroupDraft` ("N members"), so it gets the group card's button.
        // The tap goes through `openGroupLink`, which opens the group page in the app.
        if let u = URL(string: p.url), case .name(let name)? = KulanApp.route(from: u),
           p.desc.range(of: #"^[0-9.,KM]+ (members?|followers?)$"#, options: .regularExpression) != nil {
            // Looked up now so the tap opens at once, and today's count wins over the one the
            // sender's phone saw (owner 2026-10-23: the card said 8 members, Juni has 11).
            GroupDirectory.prewarm(name: name)
            let live = GroupDirectory.cachedCid(name: name).flatMap { GroupDirectory.cachedPreview(name: name, cid: $0) }
            return BubbleBody.LinkPreview(
                shape: .group(code: name, member: live?.isMember ?? false),
                url: p.url, title: live?.title ?? p.title,
                // A channel counts followers, so the card says Channel + Open Channel (owner 2026-11-06).
                desc: live.map { $0.isChannel
                    ? GroupDirectory.followersLine(ChannelCountBias.visitorCount($0.cid, memberCount: $0.memberCount, followerCount: $0.followerCount))
                    : GroupDirectory.membersLine($0.memberCount) } ?? p.desc, host: p.host,
                imageUrl: p.imageUrl, imageEnc: p.imageEnc)
        }
        let shape: BubbleBody.LinkPreview.Shape
        if handle != nil, p.desc.isEmpty, p.title == "Unavailable" {
            shape = .profileUnavailable
        } else if let handle {
            // Looked up now, so the card's Send Message has nothing left to wait for.
            ProfileCardDoor.prewarm(handle)
            shape = .profile(handle: handle)
        } else if let link = URL(string: p.url).flatMap({ LinkPreviewService.storyLink(in: $0) }) {
            shape = .story(id: link.id, handle: link.handle)
        } else {
            shape = .article
        }
        return BubbleBody.LinkPreview(
            // A YouTube card says "YouTube", as the reference's does, whatever spelling the link used.
            shape: shape, url: p.url, title: p.title, desc: p.desc,
            host: URL(string: p.url).flatMap { LinkPreviewService.youtubeID(in: $0) } != nil ? "YouTube" : p.host,
            imageUrl: p.imageUrl, imageEnc: p.imageEnc)
    }

    /// ⛔ A QUOTED CHANNEL POST (owner 2026-11-06): the article card's shape, filled from the server's
    /// answer for this reader (`QuoteStore`): the channel's name, the post's text as quoted, its first
    /// picture, "Quoted post" under them. Post deleted / This channel is private when that is the
    /// answer, with no picture. "Loading…" until the first answer lands.
    private static func quoteBody(_ qid: String, cid: String, mid: String) -> BubbleBody.LinkPreview {
        // Where this card sits, so a reader of THIS chat sees a quote of a private channel's post
        // (owner 2026-11-08). The server checks the quote really was sent in this message.
        QuoteStore.shared.noteHost(qid, cid: cid, mid: mid)
        guard let c = QuoteStore.shared.card(qid) else {
            // Drawn as skeleton bars, never as these words (owner 2026-11-10, `QuoteSkeleton`).
            return BubbleBody.LinkPreview(shape: .article, url: "fariin-quote://\(qid)", title: QuoteSkeleton.title,
                                          desc: QuoteSkeleton.desc, host: "Quoted post", imageUrl: nil, imageEnc: nil)
        }
        let image = c.state == .ok && !c.image.isEmpty ? c.image : nil
        // An album post's pictures (owner 2026-11-08: two photos quoted showed one). Only with a
        // first picture, and only 2 to 4 of them; anything else is the single-picture card.
        let album = (c.images ?? []).filter { !$0.isEmpty }
        let images = image != nil && album.count >= 2 ? Array(album.prefix(4)) : []
        // The card (owner 2026-11-06, his reference): the channel's photo and name, the post's
        // picture, its words; under my own words (MessageRowLayout places it below the text).
        return BubbleBody.LinkPreview(shape: .article, url: "fariin-quote://\(qid)", title: c.heading,
                                      desc: c.body, host: "", imageUrl: images.first ?? image, imageEnc: nil,
                                      avatarUrl: c.photoUrl.isEmpty ? nil : c.photoUrl, imageUrls: images)
    }

    /// owner 2026-10-18: a group link's card. What the sender's phone got from the server travels in
    /// the message (`LinkPreviewService.groupDraft`); a fresher answer this phone already holds
    /// (`GroupLinkDoor`, looked up when the card is drawn) wins, so the count is today's. A message
    /// from before group cards carries the WEBSITE's preview (the site banner), which is never shown:
    /// until the lookup lands it reads as a plain group invite with the letter circle.
    private static func groupLinkBody(_ p: Message.LinkPreviewData, code: String) -> BubbleBody.LinkPreview {
        GroupLinkDoor.prewarm(code)
        let sentDead = p.desc.isEmpty && p.title == "Unavailable"
        let fromServer = p.desc.range(of: #"^[0-9.,KM]+ (members?|followers?)$"#, options: .regularExpression) != nil
        var title = fromServer ? p.title : "Group invite"
        var desc = fromServer ? p.desc : "Fariin group"
        var image = fromServer ? p.imageUrl : nil
        var enc = fromServer ? p.imageEnc : nil
        if let live = GroupLinkDoor.lastFound(code) {
            title = live.title
            desc = live.membersLine
            image = live.photoUrl
            enc = nil
        }
        let member = GroupLinkDoor.isMember(code)
        let dead = !member && (GroupLinkDoor.refusal(code) != nil || (sentDead && GroupLinkDoor.cached(code) == nil))
        return BubbleBody.LinkPreview(
            shape: dead ? .groupUnavailable : .group(code: code, member: member),
            url: p.url, title: title, desc: desc, host: p.host,
            imageUrl: image, imageEnc: enc)
    }

    private static func fileBody(_ m: Message) -> BubbleBody.FileBody {
        let size: String = {
            guard let b = m.fileSize else { return "Document" }
            if b >= 1_048_576 { return String(format: "%.1f MB", Double(b) / 1_048_576) }
            if b >= 1024 { return String(format: "%.0f KB", Double(b) / 1024) }
            return "\(b) B"
        }()
        return BubbleBody.FileBody(
            name: m.fileName ?? "Document", sizeLabel: size,
            previewUrl: m.thumbUrl, previewEnc: m.thumbEnc, localPreview: m.localImageData,
            uploading: m.sendState == .sending)
    }

    /// The filled tick's colour: the chat's own, exactly as theirs tints the selection indicator
    /// with `chatColorValue`. A gradient chat takes its first stop — the indicator is a 24pt disc
    /// and a gradient across it would read as a flat colour anyway. Falls back to the same default
    /// bubble blue `myFill` uses, so an untinted chat looks unchanged.
    private static func selectionTint(_ ctx: MessageRowContext) -> UInt {
        guard let spec = ctx.chatColor, let first = spec.colors.first else {
            return ctx.dark ? 0x0A84FF : 0x007AFF      // Theme.defaultBubble
        }
        return first
    }

    private static func myFill(_ ctx: MessageRowContext) -> BubbleFill {
        guard let spec = ctx.chatColor else {
            return .solid(ctx.dark ? 0x0A84FF : 0x007AFF)      // Theme.defaultBubble
        }
        return spec.isGradient ? .gradient(spec.colors) : .solid(spec.colors.first ?? 0x3A76F0)
    }

    private static func receivedFill(_ ctx: MessageRowContext) -> BubbleFill {
        switch Theme.receivedSurface(ctx.dark, onWallpaper: ctx.onWallpaper, blur: ctx.wallpaperBlur) {
        case .flat:
            // ⚠️ `.flat` IS TWO DIFFERENT COLOURS. Theme returns the incoming grey off a wallpaper
            // and the PAGE BACKGROUND when Reduce Transparency is on over one. Theme still makes
            // the decision; this only reads the same flag it read to tell the two apart.
            return (ctx.onWallpaper && UIAccessibility.isReduceTransparencyEnabled) ? .background : .received
        case .slice(let state): return .wallpaperSlice(state)
        // The system blur. This branch used to return the flat grey, because a material was then a
        // fallback for a slice that could not be built; it is the surface itself now.
        case .material: return .material
        }
    }

    /// ⚠️ GROUPED BY UID, NOT BY VALUE. The old version grouped `msg.reactions.values`, which throws
    /// the uid away in the same expression that counts it — so the chip could say how many but never
    /// who. `msg.reactions` is uid → emoji, and the reactor is the key.
    private static func reactionChips(_ msg: Message, ctx: MessageRowContext) -> [ReactionChip] {
        if ctx.isChannel { return channelChips(msg, ctx: ctx) }
        guard !msg.reactions.isEmpty else { return [] }
        let mine = msg.reactions[ctx.me]
        var byEmoji: [String: [String]] = [:]
        for (uid, emoji) in msg.reactions { byEmoji[emoji, default: []].append(uid) }
        return byEmoji.map { emoji, uids in
            // Sorted so the face a chip shows is stable between rebuilds — an avatar that swaps
            // between two reactors on every repaint is worse than no avatar.
            let faces = uids.count > ReactionChip.maxFaces ? [] : uids.sorted().map {
                ReactionFace(uid: $0, name: ctx.nameFor($0), photoUrl: ctx.avatarFor($0))
            }
            return ReactionChip(emoji: emoji, count: uids.count, mine: mine == emoji, faces: faces)
        }
        .sorted { $0.count != $1.count ? $0.count > $1.count : $0.emoji > $1.emoji }
    }

    /// A channel post: counts only, never faces (followers never see who reacted). My pick still on
    /// its way moves the counts at once. Nobody yet: nothing (owner 2026-10-29 removed the empty
    /// "add" chip; double tap and the long-press bar are the ways in).
    private static func channelChips(_ msg: Message, ctx: MessageRowContext) -> [ReactionChip] {
        guard ctx.channelReactionsOn, !msg.isSystem, !msg.isCall else { return [] }
        let mine = ctx.channelMine(msg.id), held = ctx.channelConfirmed(msg.id)
        // Same emoji with or without its variation selector = one chip, and mine (audit E3).
        let counts = ChannelEmoji.merged(ctx.channelCounts(msg.id, msg.reactionCounts), mine: mine, held: held)
        let chips = counts.map {
            ReactionChip(emoji: $0.key, count: $0.value, mine: ChannelEmoji.same(mine, $0.key), faces: [], showCount: true)
        }
        .sorted { $0.count != $1.count ? $0.count > $1.count : $0.emoji > $1.emoji }
        return chips
    }

    private static func replyThumb(_ o: Message?) -> QuoteChrome.Thumb {
        // Never for a deleted original: its thumbnail is gone from Storage, so this would draw an
        // empty box next to the words saying it was deleted.
        guard let o, !o.deleted else { return .none }
        // ⛔ AND NEVER FOR A VIEW-ONCE ORIGINAL. This is the one path that could walk around the
        // rule the rest of the row system enforces.
        //
        // A view-once photo is deliberately routed to a PILL by `canRender`/`bubble`, so its picture
        // is never drawn in the list at all. This function does not go through that gate: it reads
        // the original `Message` and pulls `imageUrl` + `enc` straight into a 34pt image view. So
        // anyone replying to a view-once photo caused it to be rendered — permanently, in BOTH
        // threads, and still there after the single view had been spent. The one guarantee the
        // feature makes is the one it could not keep.
        guard !o.viewOnce else { return .none }
        if o.isImage, let url = o.imageUrl { return .media(url: url, enc: o.enc, play: false) }
        if o.isAlbum, let first = o.album.first { return .media(url: first.imageUrl, enc: first.enc, play: false) }
        if o.isGif, let url = o.imageUrl { return .gif(url: url) }
        // 2026-10-17 chat stickers: one I made is a sealed PNG like a photo. A built-in one draws
        // from the pack, not a url, so its quote carries the words only.
        if o.isSticker {
            if o.stickerPack == "mine", let url = o.imageUrl, !url.isEmpty { return .media(url: url, enc: o.enc, play: false) }
            return .none
        }
        if o.isVideo, let url = o.thumbUrl { return .media(url: url, enc: o.thumbEnc, play: true) }
        return .none
    }

    private static func replyLabel(reply: ReplyRef, original o: Message?) -> String {
        if reply.isStatus { return "Status" }
        // The quote is a SNAPSHOT baked into the replying message, so deleting the original left its
        // words readable inside every reply to it. We cannot rewrite someone else's message, but we
        // can refuse to render the stale copy once we can see the original is gone.
        if o?.deleted == true { return "This message was deleted" }
        // The words follow the same rule as the picture: a view-once original is named by what it
        // WAS, never by its caption, which is content the sender meant to be seen once.
        if o?.viewOnce == true { return "Photo" }
        if let o, o.isSticker { return StickerSend.label(emoji: o.stickerEmoji) }   // 2026-10-17
        if let o, o.isImage || o.isGif || o.isVideo || o.isAlbum {
            if !o.text.isEmpty { return quoteSafeLabel(o.text) }   // the caption wins
            if o.isAlbum { return "Photos" }
            if o.isGif { return "GIF" }
            if o.isVideo { return "Video" }
            return "Photo"
        }
        return reply.text.isEmpty ? "Message" : quoteSafeLabel(reply.text)
    }

    // ── System notices ──

    /// The notice tap target that means "the Restricted chat request", not a message to jump to.
    static let restrictRequestTarget = "restrict-request"
    /// The two answers under an open Restricted chat request (`NoticeRow.actions` ids).
    static let restrictReject = "restrict-reject"
    static let restrictAccept = "restrict-accept"

    /// The sentences `ChatService` writes about Restricted chat (and, 2026-10-19, the group's
    /// Restricted group switch), minus the writer's name: "turned on Restricted chat." etc. Nil for
    /// any other notice.
    private static func restrictedAction(_ text: String) -> String? {
        let actions = ["turned on Restricted chat.", "turned off Restricted chat.",
                       "asked to turn off Restricted chat.", "kept Restricted chat on.",
                       "turned on Restricted group.", "turned off Restricted group."]
        return actions.first { text.hasSuffix(" " + $0) }
    }

    /// 2026-10-19: a group notice I wrote ("adnan removed Ali") reads "You removed Ali" on my phone,
    /// the same swap the Restricted Chat and timer lines make. The stored sentence starts with the
    /// name my phone had when it wrote it, so the swap happens only when the text still starts with
    /// my name (or "Someone", the writer's fallback for an empty name); after a rename it stays as
    /// written. Others' notices are untouched.
    private static func ownNoticeAsYou(_ m: Message, ctx: MessageRowContext) -> String {
        guard !m.authorId.isEmpty, m.authorId == ctx.me else { return m.text }
        let names = [ProfileStore.shared.me?.name ?? "", ctx.nameFor(m.authorId), "Someone"]
        for name in names where !name.isEmpty && m.text.hasPrefix(name + " ") {
            return "You" + String(m.text.dropFirst(name.count))
        }
        return m.text
    }

    private static func systemNotice(_ m: Message, ctx: MessageRowContext) -> NoticeRow {
        // The disappearing-timer notice is worded HERE, per reader, from the value the writer
        // attached: "You" when I set it, the person's name when they did. The stored sentence (with
        // the writer's name baked in) is still what the chat list shows.
        guard let secs = m.disappearSeconds else {
            // A local notice (the block ones) carries its own symbol; the leading space matches the
            // timer line's, which is how the pill spaces a symbol from its words.
            if let symbol = m.localNoticeSymbol {
                return NoticeRow(text: " " + m.text, symbol: symbol, style: .pill, tapTargetId: nil,
                                 onWallpaper: ctx.onWallpaper, wallpaperBlur: ctx.wallpaperBlur)
            }
            // ⛔ RESTRICTED CHAT NOTICES ARE WORDED PER READER — owner, 2026-10-04: "I did it, so it
            // must say You". The stored sentence has the writer's name baked in (the chat list
            // still shows it); here the name part is replaced by "You" for my own, by the person's
            // name for theirs, with the owner's Restricted chat icon in front.
            if let action = restrictedAction(m.text) {
                let who = m.authorId == ctx.me ? "You" : ctx.nameFor(m.authorId)
                // His wording: "Restricted Chat", as the profile row names it.
                let said = action.replacingOccurrences(of: "Restricted chat", with: "Restricted Chat")
                    .replacingOccurrences(of: "Restricted group", with: "Restricted Group")
                let words = ctx.isChannel ? ChannelWords.apply(said) : said   // a channel's words (2026-10-29)
                // ⛔ THE OPEN REQUEST CARRIES ITS ANSWER (owner, 2026-10-12): Reject and Accept under
                // the request, for the person it was asked of, while it is open. Only the one notice
                // ThreadView names live gets them; older requests and the asker's own copy are a
                // plain line, and the buttons go the moment the request is answered or lapses.
                let live = m.isRestrictRequest && m.id == ctx.liveRestrictRequestId
                return NoticeRow(text: " \(who) \(words)", symbol: "ic_restricted_chat", style: .pill,
                                 tapTargetId: m.isRestrictRequest ? Self.restrictRequestTarget : nil,
                                 onWallpaper: ctx.onWallpaper, wallpaperBlur: ctx.wallpaperBlur,
                                 actions: live ? [NoticeAction(id: Self.restrictReject, title: "Reject"),
                                                  NoticeAction(id: Self.restrictAccept, title: "Accept")] : [])
            }
            // A request to turn Restricted chat off answers from its own notice, as in the
            // reference app (`ThreadView` reads this target and offers Turn Off / Keep On).
            // A channel's notices say "channel" (owner 2026-10-29: "You changed the group wallpaper",
            // "This group is now verified"): the server writes one sentence for both kinds.
            let said = ownNoticeAsYou(m, ctx: ctx)
            return NoticeRow(text: ctx.isChannel ? ChannelWords.apply(said) : said, symbol: nil, style: .pill,
                             tapTargetId: m.isRestrictRequest ? Self.restrictRequestTarget : nil,
                             onWallpaper: ctx.onWallpaper, wallpaperBlur: ctx.wallpaperBlur)
        }
        // Owner, 2026-10-10: always "You" for my own change. `nameFor` returns MY NAME for my uid in
        // one of the chat's two contexts (it is also used for sender labels), so the line flipped
        // between "You" and "adnan abdi". Same rule as the Restricted Chat notices above.
        let who = m.authorId == ctx.me ? "You" : ctx.nameFor(m.authorId)
        let line = secs > 0
            ? " \(who) set disappearing message time to \(ChatService.disappearLabel(secs))."
            : " \(who) turned off disappearing messages."
        return NoticeRow(text: line, symbol: "timer", style: .pill, tapTargetId: nil,
                         onWallpaper: ctx.onWallpaper, wallpaperBlur: ctx.wallpaperBlur)
    }

    // ── Story mention ──

    /// ⛔ THE STORY MENTION CARD — owner 2026-10-16, with the reference app's pictures: the story in a
    /// ring, "You mentioned NAME in a story" / "NAME mentioned you in a story", View Story. Once the
    /// story is gone (deleted or expired, the same live test a story reply uses) it becomes one
    /// centred line saying so. See `StoryMentions` for how the message is sent.
    private static func storyMentionRow(_ m: Message, _ sm: StoryMentionRef, ctx: MessageRowContext) -> NoticeRow {
        let mine = m.authorId == ctx.me
        let name = mine ? (ctx.otherName.isEmpty ? "them" : ctx.otherName) : ctx.nameFor(m.authorId)
        guard ctx.storyIsLive(sm.id, m.authorId) else {
            // Two lines, broken after the name (owner 2026-10-16: one long line looked bad).
            let line = mine ? "The story where you mentioned \(name)\nis no longer available"
                            : "The story where \(name) mentioned you\nis no longer available"
            return NoticeRow(text: line, symbol: nil, style: .pill, tapTargetId: nil,
                             onWallpaper: ctx.onWallpaper, wallpaperBlur: ctx.wallpaperBlur,
                             boldName: name)
        }
        let line = mine ? "You mentioned \(name) in a story" : "\(name) mentioned you in a story"
        return NoticeRow(text: line, symbol: nil, style: .storyCard, tapTargetId: nil,
                         onWallpaper: ctx.onWallpaper, wallpaperBlur: ctx.wallpaperBlur,
                         actions: [NoticeAction(id: "storymention:\(m.id)", title: "View Story")],
                         storyThumbUrl: sm.thumbUrl,
                         flightKey: MediaOpenRects.key(.storyRow, "storymention-\(m.id)"),
                         boldName: name)
    }

    // ── Call rows ──

    private static func callRow(_ m: Message, ctx: MessageRowContext) -> CallRow {
        let mine = m.callerUid == ctx.me
        // The row exists from the first ring and `recordCall` finalises it in place. The age
        // fallbacks are the safety net for a writer that died mid-call: an orphan "ringing" renders
        // as a normal unanswered call, a stale "ongoing" as a plain ended one.
        let age = Date().timeIntervalSince(m.createdAt)
        // Group call audit 2026-10-23: a group chat's call reads as THIS viewer saw it (joined on any
        // device, rung and missed, or never rung), not the one outcome the record stores for the
        // whole group. A record without `joinedUids` (1:1, an older server) keeps its own outcome.
        let outcome = GroupCallOutcome.mine(stored: m.callOutcome, callerUid: m.callerUid,
                                            joined: m.callJoinedUids, rung: m.callRungUids, me: ctx.me)
        let ringing = outcome == "ringing" && age < 120
        let ongoing = outcome == "ongoing" && age < 4 * 3600
        // Legacy "declined" records render exactly as missed.
        let missed = outcome == "missed" || outcome == "declined"
            || (outcome == "ringing" && age >= 120)
        let video = m.callVideo
        // "Missed call" (red) is ONLY for calls I RECEIVED and did not answer. When I was the caller
        // and nobody picked up it is an outgoing call with "No answer" — never red, never "call
        // back", because I was the one calling.
        // ⛔ SILENCED BY MY FOCUS (owner, 2026-10-11, the reference's bubble): an incoming call this
        // phone's Focus kept from ringing reads "Silenced voice call · Focus mode", grey, not the
        // missed red. The call message's id is "call_<callId>". See `FocusSilencedCalls`.
        let silenced = missed && !mine && m.id.hasPrefix("call_")
            && FocusSilencedCalls.contains(String(m.id.dropFirst(5)))
        let incomingMissed = missed && !mine && !silenced
        let time = m.createdAt.formatted(date: .omitted, time: .shortened)
        let status = silenced ? (video ? "Silenced video call" : "Silenced voice call")
            : video ? (incomingMissed ? "Missed video call" : "Video call")
                    : (incomingMissed ? "Missed voice call" : "Voice call")
        let detail: String = {
            if silenced { return "Focus mode · \(time)" }
            // My own call says what the call screen says (owner 2026-10-29: the bubble said Ringing
            // while the screen said Calling): Ringing only once the other phone has said it rings.
            if ringing { return (mine && !ctx.calleeRinging ? "Calling" : "Ringing") + " · \(time)" }
            if ongoing { return "Ongoing · \(time)" }
            if incomingMissed { return "Call back · \(time)" }
            if missed { return "No answer · \(time)" }        // my unanswered outgoing call
            // Never rung and never in it (controls audit 5-5): the group talked, I did not. No length,
            // as the Calls tab shows it.
            if outcome == GroupCallOutcome.notJoined { return time }
            if let d = m.callDuration, d > 0 { return "\(durationLabel(d)) · \(time)" }
            return "\(mine ? "Outgoing" : "Incoming") · \(time)"
        }()
        let symbol: String = {
            if video { return incomingMissed ? "video.slash.fill" : "video.fill" }
            if incomingMissed { return "phone.arrow.down.left" }
            return mine ? "phone.arrow.up.right" : "phone.arrow.down.left"
        }()
        return CallRow(
            mine: mine, status: status, detail: detail, symbol: symbol,
            missedIncoming: incomingMissed, live: ringing || ongoing, video: video,
            // The call bubble follows the chat colour like every other sent bubble, instead of
            // always being the brand accent.
            fill: mine ? myFill(ctx) : receivedFill(ctx),
            rim: !mine && ctx.onWallpaper,
            silenced: silenced,
            // In a group, whose call it was (owner 2026-10-20: "I don't know who is calling").
            callerName: ctx.isGroup && !mine ? ctx.nameFor(m.callerUid ?? m.authorId) : nil,
            callerPhoto: ctx.isGroup && !mine ? ctx.avatarFor(m.callerUid ?? m.authorId) : nil)
    }

    private static func durationLabel(_ s: Int) -> String {
        if s < 60 { return "\(s) sec" }
        if s < 3600 { return String(format: "%d:%02d", s / 60, s % 60) }
        return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }
}
