import UIKit

// ===== The resolved, SwiftUI-free description of one row in the message list =====
//
// ThreadView owns the context — who I am, the wallpaper, the chat colour, the group roster, the
// cluster arithmetic — and resolves all of it into one of these. A cell never reaches back into app
// state to decide how it looks, which is what lets the same value be MEASURED off-screen and
// RENDERED on-screen with no possibility of the two disagreeing.
//
// Everything here is Equatable so an identical reconfigure is free and a changed row is detected
// without asking the renderer.

/// One reaction capsule under a bubble.
struct ReactionChip: Equatable {
    var emoji: String
    var count: Int
    var mine: Bool
}

/// The sender's name and avatar above/beside a bubble in a group.
struct SenderChrome: Equatable {
    var uid: String
    var name: String
    var colorSeed: String        // the uid the palette hashes; kept separate so a rename never moves the colour
    var showsName: Bool          // first bubble of the cluster
    var showsAvatar: Bool        // last bubble of the cluster — the avatar sits on the baseline
    var avatarUrl: String?
    var verified: Bool
}

/// The tinted quote box inside a bubble that is a reply.
struct QuoteChrome: Equatable {
    enum Thumb: Equatable {
        case none
        case story(url: String)                    // 30×38, its own anchor key
        case media(url: String, enc: EncMeta?, play: Bool)   // 34×34
        case gif(url: String)
    }
    var targetId: String
    var authorLine: String       // "You" or the sender's name
    var snippet: String
    var thumb: Thumb
    var isStatus: Bool
}

/// Time, edited tag and delivery tick — the footer inside every bubble.
struct MetaChrome: Equatable {
    var timeText: String
    var edited: Bool
    var tick: BubbleTicks.Kind
    /// When the message was created, so the sending clock can honour its 0.8s grace window. A
    /// healthy send flips to a tick inside that window and the clock is never seen.
    var bornAt: Date?
}

/// What sits inside the bubble. Phase 1 renders text, jumbomoji and the tombstone; the media and
/// card cases arrive in phases 2 and 3 and are absent here rather than stubbed, so a row that this
/// enum cannot describe is still routed to the old path by ThreadView instead of drawing wrong.
enum BubbleBody: Equatable {
    case text(TextBody)
    case jumbomoji(String)          // 1…5 emoji, drawn borderless at up to 3.5× the body size
    case tombstone(String)          // "You deleted this message" — a notice, not a message
    /// A photo, a video or a gif: ONE media box that wears the bubble's own corners, with the
    /// caption (when there is one) flush below it under the same background — never two bubbles.
    case media(MediaBody)
    /// 2+ photos and videos sent together as ONE message: a mosaic grid plus one caption.
    case album(AlbumBody)
    /// A document: an icon or a page preview, the name, the size.
    case file(FileBody)
    /// A shared place: the map picture flush to the top and sides, the label under it.
    case location(LocationBody)
    /// A shared contact: avatar, name, and a "message" button.
    case contact(ContactBody)

    struct LocationBody: Equatable {
        var lat: Double
        var lon: Double
        var label: String
    }

    struct ContactBody: Equatable {
        var uid: String
        var name: String
        var photo: String?
        /// False for my own card and for the person I am already talking to — there is no chat to
        /// open, and a button that does nothing is worse than no button.
        var canMessage: Bool
    }

    struct AlbumBody: Equatable {
        struct Tile: Equatable {
            var url: String?
            var enc: EncMeta?
            /// w/h. ⚠️ IT DECIDES THE ARRANGEMENT, so it has to be right BEFORE the tiles exist —
            /// an optimistic album has only `localAlbum`, and a receiver's has only `albumSizes`.
            /// Falling through to 1 there made every pending photo measure as a square, the mosaic
            /// solved one arrangement, and it changed under the reader when the real tiles landed.
            var aspect: Double
            var isVideo: Bool
            var durationText: String?
            var localData: Data?
            /// "clientId#index" while this ITEM is still uploading. Per-item, because `sendState` is
            /// per-MESSAGE and stays `.sending` until the whole batch commits — a finished tile kept
            /// its overlay while its siblings uploaded, and with its bytes gone from UploadProgress
            /// the ring degraded into a forever-spinner.
            var uploadKey: String?
        }
        var tiles: [Tile]
        var extra: Int                   // "+N" on the last tile, past the 10-item ceiling
        var caption: TextBody?
        var uploading: Bool
        var blurhash: String?
        var inlineThumbBase64: String?
        var thumbCacheId: String
    }

    struct FileBody: Equatable {
        var name: String
        var sizeLabel: String
        /// A page preview (a PDF's first page) — 44×58 when there is one, else a 26pt doc glyph.
        /// ⚠️ The two slots are deliberately checked in this order and BOTH exist in the sending
        /// state, so only the spinner moves between them and the bubble never resizes mid-send.
        var previewUrl: String?
        var previewEnc: EncMeta?
        var localPreview: Data?
        var uploading: Bool
    }

    /// Phase 2. Everything the media box needs, resolved — no message, no app state.
    struct MediaBody: Equatable {
        /// ⚠️ THE THREE KINDS DO NOT SHARE A SIZING RULE, and that is not an accident to tidy up.
        /// A photo is measured by `MessageRowLayout.photoBox` (the 350 cap, the aspect clamp, the
        /// comfort width that lets a 9:16 grow, the anti-upscale floor); a video and a gif are
        /// measured by `displayBox` (240 × 340), and a video additionally takes the photo path's
        /// caption floor. Each of those was tuned against a report; collapsing them would undo
        /// several at once.
        enum Kind: Equatable { case photo, video, gif }
        var kind: Kind

        var url: String?                 // the encrypted bytes (a gif's is a public Giphy url)
        var enc: EncMeta?
        var posterUrl: String?           // a video's thumbnail
        var posterEnc: EncMeta?
        /// The optimistic local bytes, shown before the upload lands.
        var localData: Data?
        var blurhash: String?
        /// The inline thumbnail that travelled INSIDE the message — a real (tiny) photo, ready
        /// before anything has been asked of the network. Beats the hash whenever there is one.
        var inlineThumbBase64: String?
        var thumbCacheId: String
        var pixelWidth: Double?
        var pixelHeight: Double?
        var durationText: String?        // a video's badge, "0:42"
        var caption: TextBody?           // nil when the media carries no words
        var uploading: Bool
        var clientId: String?
        /// The photos auto-download policy may hold the fetch until tapped.
        var gated: Bool
    }

    struct TextBody: Equatable {
        var text: String
        var searchTerm: String      // in-chat search highlights this run
        /// The "@Display Name" tokens to bold and tint — resolved by ThreadView, which owns the
        /// group roster. Passing the finished tokens keeps the renderer free of app state, and it
        /// is also the only way the measuring pass can agree with the drawing pass about how wide
        /// a mention is (a name that resolves late would change the width after measurement).
        var mentionTokens: [String]
    }
}

/// A message bubble, fully resolved.
struct BubbleRow: Equatable {
    var isMe: Bool
    var body: BubbleBody
    var fill: BubbleFill
    var radii: BubbleRadii
    var meta: MetaChrome
    var sender: SenderChrome?          // groups, incoming only
    var quote: QuoteChrome?
    var forwarded: Bool
    var reactions: [ReactionChip]
    var showsRetryRow: Bool            // "Not delivered. Tap to retry" under a failed send
    var rim: Bool                      // the hairline an incoming bubble wears on a wallpaper
    var canSwipeToReply: Bool
    var opensOnTap: Bool               // media opens something → no double-tap recogniser
    var canDoubleTapReact: Bool
}

/// A centred capsule notice: the day separator, a system event, a pin notice.
struct NoticeRow: Equatable {
    enum Style: Equatable {
        case pill                      // the day separator / system event / pin notice capsule
        case unsupported               // dashed-border card for a newer app version's message
    }
    var text: String
    var symbol: String?                // leading SF Symbol, inline with the text (the timer glyph)
    var style: Style
    var tapTargetId: String?           // a pin notice jumps to the pinned message
    var onWallpaper: Bool
    var wallpaperBlur: WallpaperBlurState?
}

/// A call-history row: disc, status, detail, and the bubble that hugs them.
struct CallRow: Equatable {
    var mine: Bool
    var status: String
    var detail: String
    var symbol: String
    var missedIncoming: Bool
    var live: Bool                     // ringing or ongoing → no call-back on tap
    var video: Bool
    var fill: BubbleFill
    var rim: Bool
}

/// One row of the list. A message can carry a day separator and the unread divider ABOVE it — the
/// same shape the SwiftUI row had, which is what keeps row ids stable across the migration.
struct MessageRowModel: Equatable {
    enum Content: Equatable {
        case bubble(BubbleRow)
        case notice(NoticeRow)
        case call(CallRow)
    }

    var id: String
    var dateHeader: NoticeRow?
    var showsUnreadDivider: Bool
    var content: Content

    /// Space above the row's content (cluster spacing). Held on the row rather than inside the
    /// bubble so a date header can sit in it without the bubble's own gap doubling up.
    var topSpacing: CGFloat

    // Row-level decorations. These change often and independently of the content, and they are
    // compared here so a selection flip or a highlight pulse reconfigures without re-resolving
    // the message.
    var selecting: Bool
    var selected: Bool
    var highlighted: Bool

    /// True while a wallpaper is behind the list — the notice pills and incoming bubbles change
    /// surface with it.
    var onWallpaper: Bool
    var wallpaperBlur: WallpaperBlurState?
}
