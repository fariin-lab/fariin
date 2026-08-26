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
    var dark: Bool
    var selecting: Bool
    var selectedIds: Set<String>
    var highlightId: String?
    var firstUnreadId: String?
    var chatColor: ChatColorSpec?
    var onWallpaper: Bool
    var wallpaperBlur: WallpaperBlurState?
    var otherLastReadMillis: Double
    var iBlocked: Bool
    var searchTerm: String
    var nameFor: (String) -> String
    var avatarFor: (String) -> String?
    var resolveOriginal: (String) -> Message?
    /// Is this story still live? A reply to one that has expired shows "Story unavailable" rather
    /// than an empty frame, and the card stops being a door.
    var storyIsLive: (_ storyId: String, _ author: String) -> Bool = { _, _ in true }
}

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
            selected: ctx.selectedIds.contains(msg.id),
            highlighted: msg.id == ctx.highlightId,
            onWallpaper: ctx.onWallpaper,
            wallpaperBlur: ctx.wallpaperBlur)
    }

    // ── The bubble ──

    private static func bubble(_ msg: Message, ctx: MessageRowContext,
                               first: Bool, last: Bool) -> BubbleRow {
        let isMe = msg.authorId == ctx.me
        let text = msg.safeText

        let body: BubbleBody
        if msg.deleted {
            body = .tombstone(isMe ? "You deleted this message" : "This message was deleted")
        } else if msg.viewOnce {
            body = .pill(viewOncePill(msg, ctx: ctx, isMe: isMe))
        } else if let pending = msg.pendingMediaKind ?? (msg.isPendingImage ? "image" : nil) {
            // Still being prepared: a spinner and a word. The real bubble arrives when the write
            // lands, carrying the poster, the duration and the waveform the placeholder cannot know.
            body = .pill(BubbleBody.PillBody(
                symbol: "arrow.up.circle", label: pendingLabel(pending),
                spent: false, opens: false, busy: true))
        } else if msg.isImage || msg.isVideo || msg.isGif {
            body = .media(mediaBody(msg, ctx: ctx))
        } else if msg.isAlbum {
            body = .album(albumBody(msg, ctx: ctx))
        } else if msg.isFile {
            body = .file(fileBody(msg))
        } else if let loc = msg.locationCard {
            body = .location(BubbleBody.LocationBody(
                lat: loc.lat, lon: loc.lon,
                // A share with no label says "Location", as it always did. The COORDINATES are
                // deliberately not on the face of it: the map replaced them, and a coordinate is
                // the one thing about a place that tells you nothing.
                label: (loc.label?.isEmpty == false ? loc.label! : "Location")))
        } else if msg.isAudio {
            body = .voice(voiceBody(msg, ctx: ctx))
        } else if let poll = msg.poll {
            body = .poll(BubbleBody.PollBody(
                pollId: poll.id, messageId: msg.id, question: poll.question,
                options: poll.options, multiple: poll.multiple))
        } else if let card = msg.contactCard {
            body = .contact(BubbleBody.ContactBody(
                uid: card.uid, name: card.name, photo: card.photo,
                // No button for my own card, and none for the person I am already talking to —
                // there is no chat to open, and a button that does nothing is worse than none.
                canMessage: card.uid != ctx.me && ChatService.convId(ctx.me, card.uid) != ctx.cid))
        } else if text.jumbomojiCount > 0, msg.linkPreview == nil,
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
                linkPreview: msg.linkPreview.map(linkPreviewBody)))
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
        let fill: BubbleFill = isMe ? myFill(ctx) : receivedFill(ctx)

        let tick: BubbleTicks.Kind
        if !isMe || msg.deleted {
            tick = .none
        } else {
            switch msg.sendState {
            case .sending: tick = .sending
            case .failed: tick = .failed
            case nil:
                // A blocked contact's lastRead is ignored, matching what the old path passed in as
                // `otherLastRead` — or a blocked chat shows ✓✓ on one row class and ✓ on another.
                let read = !ctx.iBlocked
                    && ctx.otherLastReadMillis >= msg.createdAt.timeIntervalSince1970 * 1000
                tick = read ? .read : .sent
            }
        }

        var sender: SenderChrome?
        if ctx.isGroup, !isMe {
            sender = SenderChrome(
                uid: msg.authorId,
                name: ctx.nameFor(msg.authorId),
                colorSeed: msg.authorId,
                showsName: first,
                showsAvatar: last,
                avatarUrl: ctx.avatarFor(msg.authorId),
                verified: VerificationIndex.of(msg.authorId)?.showsBadge == true)
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
                opens: live)
        }

        var quote: QuoteChrome?
        if let reply = msg.replyTo, !reply.isStatus, !msg.deleted {
            let original = ctx.resolveOriginal(reply.id)
            quote = QuoteChrome(
                targetId: reply.id,
                authorLine: reply.authorId == ctx.me ? "You" : ctx.nameFor(reply.authorId),
                snippet: replyLabel(reply: reply, original: original),
                thumb: replyThumb(original),
                isStatus: false)
        }

        // A tombstone is a placeholder, never a reactable message. Empty here is STRUCTURAL: every
        // badge, overhang and tap surface derives from this one value, so a deleted row cannot
        // render or respond to reactions no matter what the data still says.
        let reactions: [ReactionChip] = msg.deleted ? [] : reactionChips(msg, me: ctx.me)

        return BubbleRow(
            isMe: isMe,
            body: body,
            fill: fill,
            radii: .cluster(isMe: isMe, first: first, last: last),
            meta: MetaChrome(timeText: msg.createdAt.formatted(date: .omitted, time: .shortened),
                             edited: msg.edited && !msg.deleted,
                             tick: tick,
                             bornAt: msg.createdAt),
            sender: sender,
            quote: quote,
            storyReply: storyReply,
            forwarded: msg.forwarded && !msg.deleted,
            reactions: reactions,
            showsRetryRow: isMe && msg.sendState == .failed,
            // Theirs only, and only on a wallpaper — the reference guards it `hasWallpaper,
            // isIncoming`, and an outgoing bubble never wears one.
            rim: !isMe && ctx.onWallpaper,
            canSwipeToReply: msg.sendState == nil && !msg.deleted,
            opensOnTap: false,
            canDoubleTapReact: msg.sendState == nil && !msg.deleted)
    }

    private static func mediaBody(_ m: Message, ctx: MessageRowContext) -> BubbleBody.MediaBody {
        let kind: BubbleBody.MediaBody.Kind = m.isGif ? .gif : (m.isVideo ? .video : .photo)
        let caption = m.text.isEmpty ? nil : BubbleBody.TextBody(
            text: m.text, searchTerm: ctx.searchTerm,
            mentionTokens: m.mentions.map { "@\(ctx.nameFor($0))" })
        let duration: String? = {
            guard kind == .video, let d = m.duration, d > 0 else { return nil }
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
            uploading: m.sendState == .sending || m.uploading,
            clientId: m.clientId,
            // A gif is a public url with nothing to hold back; a photo goes through the
            // auto-download policy, which may keep it behind a tap.
            gated: kind == .photo)
    }

    private static func albumBody(_ m: Message, ctx: MessageRowContext) -> BubbleBody.AlbumBody {
        // An optimistic album has only `localAlbum`; a receiver's has only `albumSizes` until the
        // tiles land. Hidden-for-me tiles are dropped, but never while the album is still
        // optimistic — nothing can have been hidden yet.
        let optimistic = !m.localAlbum.isEmpty
        let count = optimistic ? m.localAlbum.count : m.album.count
        let visible: [Int] = optimistic
            ? Array(0..<count)
            : (0..<count).filter { !HiddenMessages.isHidden("\(m.id)-\($0)") }
        let n = max(visible.count, 2)
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
                guard let d = item?.duration, d > 0 else { return nil }
                let s = Int(d)
                return String(format: "%d:%02d", s / 60, s % 60)
            }()
            tiles.append(BubbleBody.AlbumBody.Tile(
                url: item?.imageUrl, enc: item?.enc, aspect: aspect,
                isVideo: isVideo, durationText: duration,
                localData: m.localAlbum.indices.contains(i) ? m.localAlbum[i] : nil,
                flightKey: MediaOpenRects.key(.chat, "\(m.id)-\(i)"),
                uploadKey: m.clientId.map { MediaSend.itemKey($0, i) }))
        }
        let caption = m.text.isEmpty ? nil : BubbleBody.TextBody(
            text: m.text, searchTerm: ctx.searchTerm,
            mentionTokens: m.mentions.map { "@\(ctx.nameFor($0))" })
        return BubbleBody.AlbumBody(
            tiles: tiles, extra: n - shown, caption: caption,
            uploading: m.sendState == .sending, blurhash: m.blurhash,
            inlineThumbBase64: m.thumb, thumbCacheId: m.rowId)
    }

    /// A view-once photo or a one-time voice note. Both are capsules; only the words differ.
    ///
    /// ⚠️ `spent` is what the RECIPIENT has used up, never the sender: my own view-once message is
    /// not "Viewed" to me just because they opened it.
    private static func viewOncePill(_ m: Message, ctx: MessageRowContext,
                                     isMe: Bool) -> BubbleBody.PillBody {
        let voice = m.isAudio
        let spent = !isMe && ViewedOnce.contains(m.id)
        if voice {
            return BubbleBody.PillBody(
                symbol: spent ? "circle.slash" : "1.circle",
                label: spent ? "Played" : "Voice message",
                spent: spent, opens: !spent, busy: false)
        }
        return BubbleBody.PillBody(
            symbol: spent ? "circle.slash" : "1.circle",
            label: spent ? "Viewed" : "Photo",
            spent: spent, opens: !spent, busy: false)
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
        let secs = Int(m.duration ?? 0)
        return BubbleBody.VoiceBody(
            messageId: m.id,
            url: m.audioUrl, enc: m.enc, localData: m.localAudioData,
            bars: m.waveform,
            durationText: String(format: "%d:%02d", secs / 60, secs % 60),
            // The unread dot: a note I did not send, that is not my own optimistic copy, and that
            // `PlayedVoice` has no record of me listening to.
            unplayed: m.authorId != ctx.me && m.localAudioData == nil
                && PlayedVoice.shared.isUnplayed(cid: ctx.cid, messageId: m.id, createdAt: m.createdAt),
            // ⚠️ A CONSTANT DERIVED FROM THE NOTE'S OWN DURATION AND NOTHING ELSE, so it is the same
            // number at pre-measure, at render and in every playback state. That is the property
            // the old bubble's width-on-play bloom fix actually needed.
            contentWidth: Double(VoiceMessageView.contentWidth(for: m)))
    }

    private static func linkPreviewBody(_ p: Message.LinkPreviewData) -> BubbleBody.LinkPreview {
        // The handle is read from the URL rather than stored, so every message ever sent — including
        // ones from before profile cards existed — answers the same way with no migration.
        let handle = URL(string: p.url).flatMap { LinkPreviewService.profileHandle(in: $0) }
        let shape: BubbleBody.LinkPreview.Shape
        if handle != nil, p.desc.isEmpty, p.title == "Unavailable" {
            shape = .profileUnavailable
        } else if let handle {
            shape = .profile(handle: handle)
        } else {
            shape = .article
        }
        return BubbleBody.LinkPreview(
            shape: shape, url: p.url, title: p.title, desc: p.desc, host: p.host,
            imageUrl: p.imageUrl, imageEnc: p.imageEnc)
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
        // No picture could be made for this wallpaper. The flat grey is the honest fallback here —
        // a live material would be a second mechanism for a case that should not happen.
        case .material: return .received
        }
    }

    private static func reactionChips(_ msg: Message, me: String) -> [ReactionChip] {
        guard !msg.reactions.isEmpty else { return [] }
        let mine = msg.reactions[me]
        return Dictionary(grouping: msg.reactions.values, by: { $0 })
            .map { ReactionChip(emoji: $0.key, count: $0.value.count, mine: mine == $0.key) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.emoji > $1.emoji }
    }

    private static func replyThumb(_ o: Message?) -> QuoteChrome.Thumb {
        // Never for a deleted original: its thumbnail is gone from Storage, so this would draw an
        // empty box next to the words saying it was deleted.
        guard let o, !o.deleted else { return .none }
        if o.isImage, let url = o.imageUrl { return .media(url: url, enc: o.enc, play: false) }
        if o.isAlbum, let first = o.album.first { return .media(url: first.imageUrl, enc: first.enc, play: false) }
        if o.isGif, let url = o.imageUrl { return .gif(url: url) }
        if o.isVideo, let url = o.thumbUrl { return .media(url: url, enc: o.thumbEnc, play: true) }
        return .none
    }

    private static func replyLabel(reply: ReplyRef, original o: Message?) -> String {
        if reply.isStatus { return "Status" }
        // The quote is a SNAPSHOT baked into the replying message, so deleting the original left its
        // words readable inside every reply to it. We cannot rewrite someone else's message, but we
        // can refuse to render the stale copy once we can see the original is gone.
        if o?.deleted == true { return "This message was deleted" }
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

    private static func systemNotice(_ m: Message, ctx: MessageRowContext) -> NoticeRow {
        // The disappearing-timer notice is worded HERE, per reader, from the value the writer
        // attached: "You" when I set it, the person's name when they did. The stored sentence (with
        // the writer's name baked in) is still what the chat list shows.
        guard let secs = m.disappearSeconds else {
            return NoticeRow(text: m.text, symbol: nil, style: .pill, tapTargetId: nil,
                             onWallpaper: ctx.onWallpaper, wallpaperBlur: ctx.wallpaperBlur)
        }
        let who = ctx.nameFor(m.authorId)
        let line = secs > 0
            ? " \(who) set disappearing message time to \(ChatService.disappearLabel(secs))."
            : " \(who) turned off disappearing messages."
        return NoticeRow(text: line, symbol: "timer", style: .pill, tapTargetId: nil,
                         onWallpaper: ctx.onWallpaper, wallpaperBlur: ctx.wallpaperBlur)
    }

    // ── Call rows ──

    private static func callRow(_ m: Message, ctx: MessageRowContext) -> CallRow {
        let mine = m.callerUid == ctx.me
        // The row exists from the first ring and `recordCall` finalises it in place. The age
        // fallbacks are the safety net for a writer that died mid-call: an orphan "ringing" renders
        // as a normal unanswered call, a stale "ongoing" as a plain ended one.
        let age = Date().timeIntervalSince(m.createdAt)
        let ringing = m.callOutcome == "ringing" && age < 120
        let ongoing = m.callOutcome == "ongoing" && age < 4 * 3600
        // Legacy "declined" records render exactly as missed.
        let missed = m.callOutcome == "missed" || m.callOutcome == "declined"
            || (m.callOutcome == "ringing" && age >= 120)
        let video = m.callVideo
        // "Missed call" (red) is ONLY for calls I RECEIVED and did not answer. When I was the caller
        // and nobody picked up it is an outgoing call with "No answer" — never red, never "call
        // back", because I was the one calling.
        let incomingMissed = missed && !mine
        let time = m.createdAt.formatted(date: .omitted, time: .shortened)
        let status = video ? (incomingMissed ? "Missed video call" : "Video call")
                           : (incomingMissed ? "Missed voice call" : "Voice call")
        let detail: String = {
            if ringing { return "Ringing · \(time)" }
            if ongoing { return "Ongoing · \(time)" }
            if incomingMissed { return "Call back · \(time)" }
            if missed { return "No answer · \(time)" }        // my unanswered outgoing call
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
            rim: !mine && ctx.onWallpaper)
    }

    private static func durationLabel(_ s: Int) -> String {
        if s < 60 { return "\(s) sec" }
        if s < 3600 { return String(format: "%d:%02d", s / 60, s % 60) }
        return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }
}
