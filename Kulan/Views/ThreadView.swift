import SwiftUI
import PhotosUI
import Photos
import CoreTransferable
import AVFoundation
import UIKit
import FirebaseFirestore
import UniformTypeIdentifiers
import QuickLook

// Gallery-video handoff: PhotosPicker exports the movie to a temp FILE (no giant Data
// copy through memory); we transcode from that URL and delete it after.
struct PickedMovie: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent("pick-\(UUID().uuidString).\(received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension)")
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.copyItem(at: received.file, to: dest)
            return PickedMovie(url: dest)
        }
    }
}

struct ThreadView: View {
    let cid: String
    let title: String
    let photoUrl: String?

    @State private var repo: ThreadRepository
    @State private var input = ""
    @State private var mentionMap: [String: String] = [:]   // inserted "@name" -> uid (groups)
    @State private var showGroupAdd = false
    @State private var showGroupCall = false
    @State private var groupCallActive = false
    @State private var groupCallVideo = false
    @State private var groupCallListener: ListenerRegistration?
    @State private var tappedMember: GroupInfoView.MemberAction?
    @State private var replyingTo: Message?
    @State private var photoItem: PhotosPickerItem?
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var editImage: EditImageWrap?     // single picked/captured photo → chat editor
    @State private var panelEditImage: EditImageWrap?   // picked FROM the attach sheet → editor OVER the sheet (X returns to it)
    @State private var panelVideoApprove: VideoWrap?    // video picked FROM the sheet → trim editor OVER the sheet (X returns to it)
    @State private var panelMediaApprove: MediaWrap?    // mixed picked FROM the sheet → pager OVER the sheet (X returns to it)
    @State private var panelMultiVideo: MultiVideoWrap? // ALL-video multi FROM the sheet → multi-video editor over it
    /// Removed inside an approval screen while the media sheet is still open behind it. Handed to the
    /// strip so its ticks match what is actually in the post.
    @State private var deselectedIds: Set<String> = []
    @State private var multiVideoApprove: MultiVideoWrap? // ALL-video multi (main picker) → multi-video editor
    @State private var videoToApprove: VideoWrap?    // picked video → approval page (caption) before send
    struct EditImageWrap: Identifiable { let id = UUID(); let image: UIImage }
    struct ComingSoonWrap: Identifiable { let id = UUID(); let icon: String; let title: String }
    @State private var mediaToApprove: MediaWrap?    // 2+ picked items (images AND/OR videos) → mixed approval pager
    struct MediaWrap: Identifiable { let id = UUID(); let items: [ApprovalMedia] }
    struct VideoWrap: Identifiable { let id = UUID(); let url: URL }   // picked video → approval page (caption)
    struct MultiVideoWrap: Identifiable { let id = UUID(); let clips: [ApprovalClip] }   // ALL-video multi → single-editor chassis + rail

    // A 2+ selection that is ENTIRELY videos routes to the multi-video editor (the single video editor's
    // exact page + thumbnail rail — user spec); any mix keeps the pager.
    static func videoClips(from items: [ApprovalMedia]) -> [ApprovalClip]? {
        let clips = items.compactMap { item -> ApprovalClip? in
            if case .video(let aid, let url, let thumb, let dur) = item {
                return ApprovalClip(assetId: aid, url: url, thumb: thumb, duration: dur)
            }
            return nil
        }
        return clips.count == items.count && clips.count >= 2 ? clips : nil
    }
    // A tapped album opens a swipeable gallery of its photos (synthetic image messages), starting on
    // the tapped one.
    struct AlbumViewerWrap: Identifiable { let id = UUID(); let gallery: [Message]; let startId: String }
    @State private var viewedOnceTick = 0            // bump after consuming a view-once photo → bubbles refresh
    @State private var pendingViewOnceConsume: Message?   // view-once photo open in the viewer → mark on close
    @State private var sendingPhoto = false
    @State private var typingSent = false
    @State private var typingIdleStop: DispatchWorkItem?   // 3s idle → auto-stop typing (idle pause timer)
    @State private var viewerImage: Message?
    @State private var albumViewer: AlbumViewerWrap?   // tapped album photo → swipeable album gallery
    @State private var albumScreen: Message?           // tapped a photo GROUP → the album list screen
    @State private var viewerVideo: Message?   // tapped video bubble → full-screen player
    @State private var statusUnavailable = false     // tapped a status reply whose story expired
    @State private var sendError: String?
    @State private var showCamera = false
    @State private var showAttachPanel = false
    // Opens at ~62% (shows the camera + ~3 photo rows, user spec); grows to .large on caption focus.
    static let attachOpenDetent: PresentationDetent = .fraction(0.62)
    @State private var attachDetent: PresentationDetent = ThreadView.attachOpenDetent
    @State private var recentsHasSelection = false   // attach sheet: ≥1 photo selected → show caption+send, hide sources
    @State private var comingSoon: ComingSoonWrap?   // generic "coming soon" sheet (currently unused tiles)
    enum CallBackKind: String, Identifiable { case voice, video; var id: String { rawValue } }
    @State private var pendingCallBack: CallBackKind?   // tapped a call-history row → confirm before dialing
    @State private var showLocationShare = false     // Location tile → Select Location map
    @State private var showPollComposer = false      // Poll tile (groups) → new-poll composer
    @State private var showFileImporter = false
    @State private var showGifPicker = false
    @State private var filePreview: PreviewFile?
    @State private var pdfDoc: PDFDocWrap?           // received PDF → custom PDFKit reader (Liquid Glass)
    @State private var showLibrary = false
    @State private var showVideoSoon = false
    @State private var showContactInfo = false   // tap avatar/name in header → profile (or Group Info for groups)
    @State private var showEncryptionInfo = false   // empty-chat notice → the safety-number screen
    /// The requester's @username, fetched once for the message-request card. Empty until it lands,
    /// and the line simply is not drawn until then rather than showing a placeholder.
    @State private var requestHandle = ""
    @State private var showWallpaper = false      // "Change Wallpaper" from the profile menu opens the picker here
    // Hold-to-record voice gesture state (standard hold-to-record).
    @State private var recordLocked = false        // recording continues after finger lifts
    // Listening back to a paused note before sending it. Not one-way: the review bar's red mic
    // records the next stretch and the recorder stitches them at send. See lockedRecordingBar.
    @State private var reviewingNote = false
    @State private var previewPlayer: AVAudioPlayer?
    @State private var previewPlaying = false
    @State private var previewURL: URL?
    // The finished note's own bars, and how far through it you are. `pauseForReview` returns the
    // waveform of everything recorded so far; drawing it is what makes the review step feel like
    // listening rather than staring at a number.
    @State private var previewWaveform: [Int] = []
    @State private var previewProgress: Double = 0
    @State private var previewTimer: Timer?
    @State private var holdHint = false             // "hold to record" flash after an accidental tap
    @State private var voiceViewOnce = false        // "1" armed on the recording bar → send as one-time listen
    @State private var voiceOnceToast = false       // the little auto-fading confirmation when it arms
    @State private var micPulse = false             // continuous "breathing" of the recording halo
    @State private var pinIndex = 0                  // which of the (≤5) pinned messages the bar shows
    @State private var showPinnedSheet = false       // "See All" → full sheet of pinned messages
    @State private var recordDrag: CGSize = .zero   // live finger translation while holding
    @State private var recordCancelArmed = false    // dragged left past the cancel threshold
    @State private var holdStarted = false          // guards a single start per hold
    @State private var holdBeganAt: Date = .distantPast   // touch-down time: a sub-0.3s release is a TAP, not a hold
    @State private var micDenied = false            // mic permission denied → "open Settings" alert
    @State private var recordingBlockedByCall = false   // tried to record while a call owns the mic
    @State private var recorder = AudioRecorder()
    @State private var highlightId: String?
    // NEW-REACTION BADGE (user request): someone reacts to one of my older messages while I am reading
    // up the chat. The jump-to-bottom arrow cannot say that — it points at the newest message, not at
    // the one that was reacted to — so this is its sibling: it shows the emoji, and tapping it scrolls
    // to that exact message and flashes it.
    @State private var reactionJumpId: String?
    @State private var reactionJumpEmoji = ""
    @State private var seenReactionSigs: [String: String] = [:]
    @State private var reactionSigsSeeded = false
    /// The list's tap-to-dismiss-keyboard, held for one runloop turn so an inner tap that wants the
    /// keyboard kept (a reply quote jump) can cancel it — see listBody.
    @State private var pendingKeyboardDismiss = false
    @State private var infoTarget: Message?        // group message → "read by" info sheet
    @State private var nativeScrollTarget: String? // UIKit list: rowId to scroll into view (reply/search jump)
    // Keyboard is native (safeAreaBar + .always). But because the list is full-bleed UNDER the composer, the
    // composer's own inset isn't folded — so we measure the bar height and feed it as extra bottom clearance
    // (so the newest message clears the bar). Not a keyboard signal; the keyboard comes from .always.
    @State private var composerBarHeight: CGFloat = 0
    @State private var pinBarHeight: CGFloat = 0   // pinned-message bar height → floating date pill drops below it
    // Message multi-select: leading checkmark, whole-row tap, bottom action bar.
    @State private var selecting = false
    @State private var selectedIds = Set<String>()
    // Bumped inside SWIFTUI context-menu actions that reload cells (Select). The UIKit list defers its
    // reloads through the menu's dismissal animation — UIKit's own callbacks can't see SwiftUI menus,
    // which is how Select kept stranding the system's blur backdrop over the whole chat.
    @State private var menuActionTick = 0
    // Composer link-preview draft (sender-side fetch, the reference app's model — see LinkPreviewService). The
    // card shows above the input the moment a pasted/typed link resolves; X suppresses that URL.
    @State private var linkDraft: LinkPreviewService.LinkDraft?
    @State private var suppressedLinkUrl: String?
    @State private var linkDetectTask: Task<Void, Never>?
    @State private var bulkForward: [Message]?
    @State private var showBulkDeleteConfirm = false
    // In-chat search (opened from the profile's "search" tile) — a top bar + ↑/↓ through matches.
    @State private var searchActive = false
    @State private var searchQuery = ""
    @State private var searchCorpus: [InChatMessage] = []
    @State private var searchMatches: [InChatMessage] = []   // filtered, oldest→newest
    @State private var searchIndex = 0
    @State private var lastSearchText: String?   // identical-query dedup: arrows/focus don't re-run the search
    @State private var searchJumpSeq = 0         // coalesces rapid next/prev jumps — only the latest target lands
    @FocusState private var searchFocused: Bool
    // UIKit message list (opens at exact bottom, scroll-continuity on load-older, no jump).
    // Default ON now; the SwiftUI list stays as a fallback toggle in Settings ▸ Privacy while it settles.
    @State private var isAtBottom = true
    @State private var visibleRows = VisibleRowsBox()   // ids currently on screen → remember where I left
    @State private var tappedLink: URL?                 // link tapped in a bubble → ONE screen-level confirm
    @State private var tappedUserNotFound = false       // @username tapped but no such user (screen-level alert)
    // reference-style media open/close TEST (Settings > Privacy): the tapped photo/video springs from
    // the bubble rect instead of the system zoom transition.
    // Retired experiment (Settings toggle removed 2026-07-23): hard-off, ignoring any stored
    // value, so nobody stays stuck on the the reference app media-open path with no way back.
    @AppStorage("readReceipts") private var readReceiptsOn = true   // feeds the uikit tick + its cache key

    // Arrival high-water mark (audit S6): per-message arrival classification, not per-batch. A class
    // box — mutating it never re-runs the body.
    private final class ArrivalState {
        var newestCreatedAt = Date.distantPast
        var seeded = false
    }
    @State private var arrivalState = ArrivalState()

    // One drain per chat OPEN, not per onAppear (audit S5): returning from an in-chat profile push
    // re-fired the drain while the original send was still in flight → duplicate server doc + the
    // recipient's unread badge over-counted by one, permanently.
    private final class DrainGate { var done = false }
    @State private var drainGate = DrainGate()

    // Typing hygiene (audit M6): onChange(of: input) can't tell a keystroke from a programmatic
    // assignment, and independent setTyping Tasks could land out of order (remote "typing…" stuck
    // for the 15s expiry). suppressNext skips one onChange; chain serializes the writes.
    private final class TypingBox {
        var suppressNext = false
        var chain: Task<Void, Never>?
        var recordingRefresh: Timer?
        var typingRefresh: Timer?   // keeps a >15s composing burst alive on the other side
    }
    @State private var typingBox = TypingBox()

    private func setInputSilently(_ s: String) {
        // Arm the skip ONLY when the assignment will actually fire an onChange — assigning the same
        // value fires nothing, and the stranded flag then swallowed the FIRST real keystroke's
        // typing broadcast on every chat open with an empty draft (audit).
        if input != s { typingBox.suppressNext = true }
        input = s
    }

    private func broadcastTyping(_ v: Bool) {
        let prev = typingBox.chain
        let c = cid
        typingBox.chain = Task { await prev?.value; await ChatService.setTyping(c, v) }
    }

    // Recording rides the same serialized chain as typing — they write the SAME field, so an
    // out-of-order landing would stick one state over the other for the 15s expiry.
    private func broadcastRecording(_ v: Bool) {
        let prev = typingBox.chain
        let c = cid
        typingBox.chain = Task { await prev?.value; await ChatService.setRecording(c, v) }
    }
    @State private var settled = false   // suppress animated auto-scroll until the open transition + first load finish
    @State private var revealed = false  // list hidden until the first chunk has laid out — the chunked build was visible mid-push (user video)
    // (`replyStoryNS`, the zoom namespace a reply-opened story used to hero from, is gone with the
    // cover it belonged to. The quote thumbnail registers a rect for the flight instead — one flag
    // says whether this bubble's quote is a door at all, which is all the namespace was really
    // doing for the last few builds.)
    @State private var newWhileAway = 0
    @State private var unreadOnOpen = 0
    @State private var firstUnreadId: String?
    @State private var didAnchorUnread = false
    @State private var morePickerTarget: Message? // any-emoji picker
    @State private var reactorsTarget: Message?   // "who reacted" sheet
    @State private var pendingDelete: Message?
    @State private var editingMessage: Message?   // INLINE edit — no modal/sheet
    @State private var forwardTarget: Message?    // forward-to-chat picker
    @FocusState private var inputFocused: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss
    @AppStorage("typingIndicators") private var typingPref = true
    @AppStorage("shareLastSeen") private var lastSeenPref = true

    private var me: String { AuthService.shared.uid ?? "" }

    // A person's display name: "You" for me, the member's name in a group, the 1:1 title otherwise.
    // Never the group name for a member (that was a bug in several call sites).
    private func personName(_ uid: String) -> String {
        if uid == me { return "You" }
        return isGroup ? (conversation?.names[uid] ?? "User") : title
    }
    private var dark: Bool { scheme == .dark }

    init(cid: String, title: String, photoUrl: String?) {
        self.cid = cid
        self.title = title
        self.photoUrl = photoUrl
        let r = ThreadRepository(cid: cid)
        _repo = State(initialValue: r)
        // ALWAYS start hidden — even a warm cache hit. Video showed the bug: when revealed started true
        // (cache hit), the chat was visible DURING the push transition at a not-yet-bottom position, then
        // jumped to the bottom. Starting hidden + settling under the veil (revealAtOpenAnchor, run from
        // onAppear for the cache path / onChange for the cold path) means it's never seen mid-scroll.
        _revealed = State(initialValue: false)
    }

    private var threadScroll: some View {
        ScrollViewReader { proxy in scrollStack(proxy) }
    }

    // Extracted so the type-checker isn't overloaded (the inline `if` in the big chain broke the build).
    @ViewBuilder private var topPinArea: some View {
        if !searchActive {   // search owns the top area — the pin bar hides while searching
            pinnedBar
                // Measure the pin bar's height and feed it to the list so the floating date pill drops BELOW
                // it (the reference app behavior). 0 when nothing is pinned (pinnedBar is empty) → the pill stays put.
                .background {
                    GeometryReader { geo in
                        Color.clear.onChange(of: geo.size.height, initial: true) { _, h in
                            pinBarHeight = h
                        }
                    }
                }
        }
    }

    @ViewBuilder private func scrollStack(_ proxy: ScrollViewProxy) -> some View {
            // The message list runs edge-to-edge UNDER the nav bar so the native iOS 26
            // blur frosts the messages scrolling beneath it (seamless, no band). `.ignoresSafeArea(.top)`
            // lets the list extend under the header; the list's own inset logic (unchanged) still clears
            // the bars. The pinned-message bar floats as a top overlay, positioned below the header.
            // NOTE: this only changes ThreadView's layout — NativeMessageList's scroll/send/inset code
            // is untouched. The heavy modifier chain lives in messagesLayer() for the type-checker.
            messagesLayerErased(proxy)
            // Full-bleed under BOTH bars, SYMMETRICALLY. The top already ran under the nav (messages render
            // behind it, frosted) — the bottom must do the SAME so messages + wallpaper render UNDER the
            // composer instead of stopping above it (that gap = the plain white app background showing = the
            // "white composer" bug). The UIKit view still sees the real bottom safe area (composer safeAreaBar
            // + keyboard) exactly like it sees the top nav inset, so `.always` folds it and the newest message
            // still rests clear of the composer — same mechanism as the top, just mirrored.
            .ignoresSafeArea(.container, edges: [.top, .bottom])
            // NO custom edge blur. The hand-made gradient-masked bands (ef7b076) rendered as huge
            // frosted blocks through the MIDDLE of the chat on device (user screenshot, removed on
            // demand the same night) — the overlay alignment did not pin to the screen edges the way
            // it reasoned on paper. The progressive edge blur, if it comes, must be Apple's native
            // scroll edge effect, integrated properly — research first, prefer-native rule.
            // Jump-to-bottom chevron as a FLOATING OVERLAY (not inside the bar). It MUST NOT live in the
            // composer safeAreaBar: the bar now feeds the content inset, so a button that appears/disappears
            // there changed the bar height → changed the inset → the bottom gap "grew in stages" as you
            // scrolled (the reported bug). As an overlay it respects the bottom safe area (floats just above
            // the composer, rides the keyboard) and is fully tappable (padding, not offset).
            .overlay(alignment: .bottomTrailing) {
                VStack(spacing: 10) {
                    reactionJumpButton   // sits ABOVE the arrow, like the reference
                    jumpToBottomButton
                }
                .padding(.bottom, 10)
            }
            // "Recording a voice note" indicator (their side): floats OVER the list at bottom-leading.
            // Deliberately NOT a list row — inserting transient rows touches the inverted-list scroll
            // machine (do-not-touch rules); an overlay moves nothing and costs nothing when absent.
            .overlay(alignment: .bottomLeading) {
                if repo.otherRecording, typingPref, !repo.iBlocked {
                    RecordingBubble(dark: dark)
                        .padding(.leading, 12).padding(.bottom, 10)
                        .transition(.scale(scale: 0.5, anchor: .bottomLeading).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.32, dampingFraction: 0.75), value: repo.otherRecording)
            // Composer floats OVER the full-bleed list as a native iOS 26 blur bar (safeAreaBar); messages
            // scroll under it. The bar grows the bottom safe area; .always folds it into the content inset.
            .floatingBottomBar {
                // THE REFERENCE MODEL — NO background at all. The iOS-26 input toolbar is a
                // UIGlassContainerEffect: the container paints NOTHING across the bar; only the pill
                // controls themselves are Liquid Glass, blurring what passes directly under THEM.
                bottomBarContent
                    // Measure the composer bar's height and feed it to the list as extra bottom clearance.
                    // Because the list is full-bleed under the composer (.ignoresSafeArea(.container,.bottom)),
                    // the composer's own safe-area inset is NO LONGER folded in — so without this the newest
                    // message slides UNDER the bar. The keyboard still comes from the (un-ignored) keyboard
                    // safe area via .always, so this only adds the static bar height, no double-count.
                    .background {
                        GeometryReader { geo in
                            Color.clear.onChange(of: geo.size.height, initial: true) { _, h in
                                composerBarHeight = h
                            }
                        }
                    }
            }
            // Per-chat wallpaper behind the messages (extends under the bars).
            .background { ChatWallpaperBackground(cid: cid).ignoresSafeArea() }
    }

    // Type-erase the heavy messages chain at the scrollStack boundary: the chain's opaque type grew past
    // the type-checker's budget ("unable to type-check this expression in reasonable time") when another
    // onChange was added. AnyView resets the complexity scrollStack sees; one wrapper, no behavior change.
    private func messagesLayerErased(_ proxy: ScrollViewProxy) -> AnyView { AnyView(messagesLayer(proxy)) }

    // First half of the messages chain (list + reveal + arrival handling), extracted so each half's
    // type-check stays bounded. messagesLayer stacks the remaining handlers on the erased boundary.
    @ViewBuilder private func messagesLayerCore(_ proxy: ScrollViewProxy) -> some View {
            listContainer(proxy)
            // Appear fully-formed: the cache chunk lands DURING the push transition
            // and the pinned-bottom re-layout read as the whole chat jumping/wiggling.
            // The UIKit list opens at the exact bottom on its own, so it needs no reveal veil.
            .opacity(1)   // the UIKit list manages its own reveal (alpha until the first frame is final)
            // Reveal only once the FULL first page is loaded + laid out (didInitialLoad) — NOT on the
            // first single message. Revealing on the first message showed the chat while cache→live
            // chunks were still landing, so the pinned-bottom layout re-flowed DURING the push and the
            // chat visibly jumped. didInitialLoad means the initial page is decrypted and settled, so
            // it fades in stable. Demo chats set didInitialLoad synchronously — hence their smoothness.
            .onChange(of: repo.didInitialLoad) { _, done in
                if done, !revealed { revealAtOpenAnchor(proxy) }
            }
            .task {
                // Safety net: if didInitialLoad is slow (or the chat is genuinely empty), still reveal
                // so the composer / empty state shows.
                try? await Task.sleep(nanoseconds: 500_000_000)
                if !revealed { revealAtOpenAnchor(proxy) }
            }
            .onAppear {
                // Cache-seeded chat: didInitialLoad is already true, so the reveal onChange never fires —
                // settle-under-veil here too (not a single scrollTo) so the cache path also never shows
                // the chat mid-scroll during the push transition.
                if repo.didInitialLoad { revealAtOpenAnchor(proxy, settlePasses: 3) }   // measured -> reveal fast (no blink)
            }
            // Interactive keyboard dismiss on drag is handled in UIKit (collectionView.keyboardDismissMode
            // = .interactive); the SwiftUI modifier here was a no-op on the representable.
            // Keyed on itemsVersion, not count (audit S6): a trim-neutral emission (new message + LRU
            // drop in one commit) left the count unchanged, so its arrival was invisible to receipts,
            // badges, and the own-send glide.
            .onChange(of: repo.itemsVersion) { _, _ in
                // PER-MESSAGE classification (audit S6): the old handler classified the whole batch by
                // its LAST author — their message + my echo in one Firestore commit read as "mine", so
                // the read receipt was skipped (a standing contributor to the tick complaints), and a
                // 3-message burst counted as "1" on the jump button. Fresh = genuinely newer than the
                // newest we'd seen (prepends of old history never count).
                let newestBefore = arrivalState.newestCreatedAt
                let seeded = arrivalState.seeded
                arrivalState.seeded = true
                // The high-water ratchets on DELIVERED messages only. My optimistic bubble carries a
                // LOCAL Date(), which runs ahead of the server stamp on a message the other person
                // composed a moment earlier — raising the mark past it meant their message was never
                // "fresh", so it got no read receipt and no jump count (my own regression: the two of
                // us typing at once). sendState != nil is exactly the not-yet-delivered case.
                if let newest = repo.items.last(where: { $0.sendState == nil })?.createdAt,
                   newest > arrivalState.newestCreatedAt {
                    arrivalState.newestCreatedAt = newest
                }
                if !settled {
                    // INITIAL LOAD (clean): pin to the OPEN ANCHOR as cache→live chunks land — invisible
                    // under the reveal veil. (proxy path retained from the pre-native list.)
                    let a = openAnchor
                    proxy.scrollTo(a.id, anchor: a.edge)
                    return
                }
                guard seeded else { return }   // first emission just seeds the high-water mark
                let fresh = repo.items.filter { $0.createdAt > newestBefore }
                guard !fresh.isEmpty else { return }
                let incoming = fresh.filter { $0.authorId != me }
                // My own send ALWAYS glides to the newest message — even when I was reading history.
                // sendState != nil = the OPTIMISTIC insert (the actual send action). The server echo
                // arrives with a slightly different timestamp and must not re-trigger the glide if the
                // user scrolled away in the meantime.
                if fresh.contains(where: { $0.authorId == me && $0.sendState != nil }) && !isAtBottom {
                    nativeScrollTarget = "BOTTOM"
                } else if !incoming.isEmpty && !isAtBottom {
                    newWhileAway += incoming.count   // per message, not per batch
                }
                // Read receipts: only for INCOMING messages the user can actually see (at the bottom) —
                // never while scrolled up reading history. Own sends in the same batch no longer mask them.
                if !incoming.isEmpty && isAtBottom && !repo.iBlocked {
                    ChatService.markReadThrottled(cid)
                    // Keep the stored unread counter at 0 for live-read arrivals too — otherwise the
                    // badge goes stale if the app is killed while this chat is still open.
                    Task { await ChatService.resetUnread(cid) }
                }
            }
            // (chain continues in messagesLayer below — split at this erased boundary for the type-checker)
    }

    // Second half of the messages chain. messagesLayer grew past the compiler's type-check budget as ONE
    // expression; the erased AnyView boundary between the halves resets the opaque-type complexity.
    @ViewBuilder private func messagesLayer(_ proxy: ScrollViewProxy) -> some View {
        AnyView(messagesLayerCore(proxy))
            .onChange(of: repo.messages.count) { _, _ in anchorUnread(proxy) }
            // The window trim must never delete the rows the reader is currently viewing (that deletion
            // yanked the viewport while reading history) — pause it whenever they're away from the bottom.
            .onChange(of: isAtBottom) { _, atB in repo.readerAwayFromBottom = !atB }
            // Always default the pinned bar to the LAST (most recent) pin; tapping then cycles.
            // visiblePinIds, not repo.pinnedMessageIds: deleting a pin "for me" leaves the shared
            // list untouched, so watching the raw list never fired and the bar kept a stale index
            // (and, on the last pin, a stale height).
            .onChange(of: visiblePinIds) { _, ids in
                pinIndex = max(0, ids.count - 1)
                // The bar's height is reported by a GeometryReader ON the bar — when the last pin is
                // removed the bar unmounts and nothing reports 0, so the floating date pill stayed at
                // the lowered position forever (user report). Reset explicitly.
                if ids.isEmpty { pinBarHeight = 0 }
            }
            .onChange(of: unreadOnOpen) { _, _ in anchorUnread(proxy) }
            // A reaction changes no message text, so it arrives as a content-only update — this is the
            // one signal that sees it.
            .onChange(of: repo.itemsVersion) { _, _ in noteReactionChanges() }
            // Reaching the newest message means you have caught up; the badge has nothing left to say.
            .onChange(of: isAtBottom) { _, atBottom in
                if atBottom, reactionJumpId != nil {
                    withAnimation(.easeInOut(duration: 0.2)) { reactionJumpId = nil }
                }
            }
            // (Removed, audit: the typing auto-scroll "revealed" an in-list typing bubble that does
            // not exist — typing lives in the HEADER only — and the loose 44pt at-bottom test yanked
            // a near-bottom reader to exact bottom on every typing flip, revealing nothing.)
            // Keyboard opening: if I was already at the bottom, keep the newest messages pinned right
            // above the keyboard. The list's inset pin covers this at the UIKit level; this explicit
            // glide is the belt-and-suspenders for cases where focus lands before the keyboard frame —
            // and it too was a proxy.scrollTo NO-OP that never executed (the "tap input → conversation
            // doesn't move" report).
            .onChange(of: inputFocused) { _, focused in
                guard focused, isAtBottom else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    nativeScrollTarget = "BOTTOM"
                }
            }
            // (Jump-to-bottom button moved: it's anchored ABOVE the composer bar in scrollStack — the list
            // is full-bleed now, so a list-anchored overlay landed at the raw screen bottom UNDER the bar.)
            // Float the composer OVER the messages (iOS 26 native via safeAreaBar):
            // the glass dims/blurs the messages scrolling under it like the native bars;
            // the scroll content auto-insets so the last message never hides.
            // Skeleton placeholder bubbles until the first page is ready (cold load only;
            // a cached chat flips didInitialLoad instantly, so this never flashes).
            .overlay {
                if !repo.didInitialLoad, repo.skeletonArmed {
                    ThreadSkeleton().allowsHitTesting(false)
                }
            }
            // A chat with nothing in it yet says what it is. Every standard messenger does this: two of
            // the reference apps put a lock notice where the first message will go, a third fills the
            // same space with an empty-state line. Ours takes the lock notice, and states what is
            // actually protected (messages AND calls) rather than naming the app that protects it.
            .overlay(alignment: .center) { encryptionNotice }
            // Brief centered toast (e.g. reply to a deleted original).
            .overlay(alignment: .center) {
                if let t = jumpToast {
                    Text(t).font(.system(size: 14, weight: .medium)).foregroundStyle(.white)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(.black.opacity(0.8), in: Capsule())
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
            }
    }

    // Floating jump-to-bottom button — appears when scrolled up, with a count of messages that arrived
    // while away. Anchored above the composer bar (see scrollStack).
    /// The new-reaction badge. Appears ONLY while there is an unseen reaction on one of my messages
    /// and I am not at the bottom; tapping scrolls to that message and flashes it, then it is gone.
    @ViewBuilder private var reactionJumpButton: some View {
        if let id = reactionJumpId, !recordingHeld, !recordLocked {
            Button {
                flashAndScroll(id)
                withAnimation(.easeInOut(duration: 0.2)) { reactionJumpId = nil }
            } label: {
                Text(reactionJumpEmoji)
                    .font(.system(size: 19))
                    .frame(width: 40, height: 40)
                    .liquidGlass(Circle(), interactive: true)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 16)
            .transition(.scale.combined(with: .opacity))
        }
    }

    /// Watch my own messages for reactions that ARRIVED (not ones that were already there when the
    /// chat opened). The first pass only seeds the baseline — otherwise every existing reaction in the
    /// loaded window would fire the badge the moment you walk into a chat.
    private func noteReactionChanges() {
        var sigs: [String: String] = [:]
        var arrived: (id: String, emoji: String)?
        for m in repo.items where m.authorId == me && !m.reactions.isEmpty {
            let sig = m.reactions.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ",")
            sigs[m.id] = sig
            // Changed since we last looked, and the change is someone ELSE's reaction. Diff against
            // the OLD map: only an entry that is NEW or CHANGED counts — the old "any non-mine
            // reaction exists" test fired on removals and could name the wrong emoji (audit).
            if let old = seenReactionSigs[m.id], old != sig {
                var oldMap: [String: String] = [:]
                for pair in old.split(separator: ",") {
                    let kv = pair.split(separator: "=", maxSplits: 1)
                    if kv.count == 2 { oldMap[String(kv[0])] = String(kv[1]) }
                }
                if let fresh = m.reactions.first(where: { $0.key != me && oldMap[$0.key] != $0.value }) {
                    arrived = (m.id, fresh.value)
                }
            }
        }
        let seeding = !reactionSigsSeeded
        seenReactionSigs = sigs
        reactionSigsSeeded = true
        guard !seeding, let a = arrived, !isAtBottom else { return }
        reactionJumpEmoji = a.emoji
        withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { reactionJumpId = a.id }
    }

    // Drawn only on a chat that genuinely has nothing in it, and only AFTER the first page has landed
    // (didInitialLoad) — otherwise it flashes over every cold open while the messages are still being
    // decrypted, which is the same mistake the skeleton above is written to avoid.
    //
    // An OVERLAY, not a list row. Same reason as the recording bubble: a transient row goes through the
    // inverted list's scroll machine, and this one would insert and remove itself at the exact moment
    // the first message arrives — the worst possible time to move that layout.
    @ViewBuilder private var encryptionNotice: some View {
        if repo.didInitialLoad, repo.items.isEmpty, !notAMember {
            let line = Text("\(Image(systemName: "lock.fill")) Messages and calls are end-to-end encrypted. Only people in this chat can read or listen to them.")
            // The safety number is a number BETWEEN two devices, so a group has nothing to show. It
            // gets the notice with no link rather than a link that leads nowhere.
            if isGroup || otherUid.isEmpty {
                line.modifier(EmptyChatNotice()).allowsHitTesting(false)
            } else {
                Button { showEncryptionInfo = true } label: {
                    // Fixed brand blue, not accentColor — accentColor is WHITE in dark mode, which is
                    // the bug that made the jump-button count invisible.
                    (line + Text(" Learn more").foregroundStyle(Theme.defaultBubble(dark)))
                        .modifier(EmptyChatNotice())
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder private var jumpToBottomButton: some View {
        if !isAtBottom && !recordingHeld && !recordLocked {   // hide the down-arrow while recording
            Button {
                // Two-stage: if there are unread messages I haven't reached yet, jump
                // to the FIRST unread; otherwise glide to the newest message.
                if let unread = firstUnreadId, let row = repo.items.first(where: { $0.id == unread }) {
                    // rowId, not doc id — the native list keys rows by clientId ?? id, and every
                    // modern message has a clientId, so the untranslated id failed the lookup
                    // silently and the first tap did nothing (audit finding).
                    nativeScrollTarget = row.rowId
                    firstUnreadId = nil   // consumed → next press goes to the bottom
                } else {
                    nativeScrollTarget = "BOTTOM"
                    newWhileAway = 0
                }
            } label: {
                Image(systemName: "chevron.down").font(.system(size: 16, weight: .bold))
                    // Explicit per-mode color + a soft counter-shadow so the glyph stays readable in
                    // dark mode AND over a bright wallpaper.
                    .foregroundStyle(dark ? .white : .black)
                    .shadow(color: (dark ? Color.black : Color.white).opacity(0.35), radius: 2)
                    .frame(width: 40, height: 40)
                    .liquidGlass(Circle(), interactive: true)
                    .overlay(alignment: .top) {
                        if newWhileAway > 0 {
                            Text("\(newWhileAway)").font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                // Fixed brand blue — Color.accentColor is WHITE in dark mode, so a white
                                // number on it was invisible (the reported "can't see the count" bug).
                                .background(Theme.defaultBubble(dark), in: Capsule())
                                .offset(y: -9)
                        }
                    }
            }
            .padding(.trailing, 16)
            .transition(.scale.combined(with: .opacity))
            .animation(.spring(response: 0.32, dampingFraction: 0.72), value: isAtBottom)
        }
    }

    // The bottom bar (composer / selection / blocked etc.), extracted so scrollStack can apply it OUTSIDE
    // the full-bleed list (the list runs under it via .ignoresSafeArea(.bottom); its height is fed back as
    // the list's manual bottom inset). A native iOS 26 blur bar (safeAreaBar) that messages scroll under.
    @ViewBuilder private var bottomBarContent: some View {
        Group {
            if selecting {
                selectionActionBar.transition(.opacity)
            } else if searchActive {
                searchNavBar.transition(.opacity)
            } else if notAMember {
                removedBar.transition(.opacity.combined(with: .move(edge: .bottom)))
            } else if cannotSendAnnouncement {
                announcementBar.transition(.opacity.combined(with: .move(edge: .bottom)))
            } else if iAmMuted {
                restrictedBar.transition(.opacity.combined(with: .move(edge: .bottom)))
            } else if repo.iBlocked {
                blockedBar.transition(.opacity.combined(with: .move(edge: .bottom)))
            } else if requestStance == .incoming {
                requestBar.transition(.opacity.combined(with: .move(edge: .bottom)))
            } else if requestStance == .awaitingReply {
                awaitingReplyBar.transition(.opacity.combined(with: .move(edge: .bottom)))
            } else if cannotMessageThem {
                cannotMessageBar.transition(.opacity.combined(with: .move(edge: .bottom)))
            } else {
                composerArea.transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: repo.iBlocked)
    }

    // Split into several layers so each modifier chain stays under the type-checker limit.
    private var threadCovers: some View {
        threadScroll
        // Avatar + name installed as the native UINavigationItem.titleView (left-aligned after the back
        // button, slides with the native swipe-back). NavTitleView clears the bar appearance overrides,
        // so there's no border — same native bar as the Chats list. RESTORED build-341 header on explicit
        // repeated user request ("completely go back build 341"). Known risk: setting titleView directly
        // fights SwiftUI's NavigationStack reconciler and can spin a CPU redisplay loop (0x8BADF00D hang);
        // the coalesced async re-assert in NavTitleView is the mitigation.
        .background(NavTitleView(isActive: !selecting, onTap: {
            // Close the keyboard before pushing the profile, else it stays up behind the pushed screen
            // and is still there when you swipe back (the reported bug).
            inputFocused = false
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            showContactInfo = true
        }) {
            // Selection mode replaces the title with just the toolbar (Delete All / count / X) — hide the
            // avatar + name so it reads as a clean selection bar.
            if !selecting { headerLabel }
        })
        .toolbar(.hidden, for: .tabBar)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(selecting)   // selection mode → only Delete All / X, no back
        .toolbar { chatToolbar }
        // Leaving the chat (swipe-back to the list, or any pop) closes the keyboard so it never
        // lingers over the chat list.
        .onDisappear {
            inputFocused = false
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
        .navigationDestination(isPresented: $showContactInfo) {
            if isGroup {
                if Flags.groupsEnabled { GroupInfoView(cid: cid) }
            } else {
                // The conversation already carries their tall crop, so the header can draw it on the
                // first frame instead of waiting for a fetch. Absent → falls back to the avatar.
                ContactInfoView(cid: cid, name: title, photoUrl: photoUrl,
                                posterUrl: conversation?.posterUrl(for: me), onSearch: {
                    showContactInfo = false   // pop back to the chat…
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { activateSearch() }   // …then open search
                })
            }
        }
        // "Learn more" on the empty-chat notice. The screen already exists and is already reachable
        // from Contact Info; this is a second door onto the same one, not a new screen.
        .navigationDestination(isPresented: $showEncryptionInfo) {
            VerifyEncryptionView(cid: cid, peerName: title, peerUid: otherUid, peerPhotoUrl: photoUrl)
        }
        .alert("Video calls", isPresented: $showVideoSoon) {
            Button("OK", role: .cancel) {}
        } message: { Text("Video calling is coming soon.") }
        .alert("Message not sent", isPresented: Binding(get: { sendError != nil },
                                                        set: { if !$0 { sendError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(sendError ?? "") }
        // Hold-to-record with mic permission denied → deep-link to the app's Settings page.
        .alert("Microphone access is off", isPresented: $micDenied) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Allow microphone access in Settings to record voice messages.") }
        .alert("You're on a call", isPresented: $recordingBlockedByCall) {
            Button("OK", role: .cancel) {}
        } message: { Text("Can't record voice messages during a call.") }
    }

    // Split into two halves at an erased boundary: this modifier chain (~28 covers/sheets/alerts on one
    // expression) blew the compiler's type-check budget ("unable to type-check in reasonable time",
    // Release build) once the delete-option alerts were added. AnyView between the halves resets the
    // opaque-type complexity — behavior unchanged.
    private var threadPickers: some View {
        AnyView(threadPickersD)
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { data in if let ui = UIImage(data: data) { editImage = EditImageWrap(image: ui) } }
                .ignoresSafeArea()
        }
        .fullScreenCover(item: $editImage) { wrap in
            ChatImageEditor(source: wrap.image) { data, caption, _, viewOnce in
                // Caption travels INSIDE the image message (one bubble).
                Task { await sendPhoto(data, viewOnce: viewOnce, caption: caption) }
            }
        }
        .fullScreenCover(item: $mediaToApprove) { wrap in
            // Mixed approval pager (images + videos, per-item edit, one caption, one send). EVERYTHING
            // selected — photos AND videos, in order — is delivered as ONE album message group,
            // with one caption. A single lone image/video keeps its dedicated fast path.
            MediaApprovalView(items: wrap.items) { ordered, caption, hd in
                Task { await sendMixedGroup(ordered, caption: caption, hd: hd) }
            }
        }
        // ALL-video multi from the main picker → the multi-video editor (single-editor page + rail).
        .fullScreenCover(item: $multiVideoApprove) { wrap in
            VideoApprovalView(clips: wrap.clips, onSendMulti: { urls, caption, hd in
                Task {
                    var cap = caption
                    for u in urls { await sendVideo(from: u, caption: cap, hd: hd); cap = "" }
                }
            })
        }
    }

    // First half of the picker chain (story/image/video viewers, camera source, etc.).
    private var threadPickersA: some View {
        threadCovers
        // (No story cover here any more: a reply quote opens through `StoryDoor`, on the app's own
        // presentation, so the scroll-down close is the same gesture here as everywhere else. It was
        // the last of the six doors still running Apple's zoom.)
        .alert("Status no longer available", isPresented: $statusUnavailable) {
            Button("OK", role: .cancel) {}
        } message: { Text("This status has expired.") }
        .fullScreenCover(item: $viewerImage, onDismiss: {
            // A view-once photo is consumed the moment the viewer closes: bubble flips to "Viewed".
            if let m = pendingViewOnceConsume {
                ViewedOnce.mark(m.id)
                pendingViewOnceConsume = nil
                viewedOnceTick += 1
            }
        }) { msg in
            // CLOSE = only the PHOTO follows the finger and the black backdrop fades (system photo
            // viewer), NOT the whole page. The native .zoom transition's own drag moved the WHOLE card
            // (and .interactiveDismissDisabled did NOT suppress it), so it's removed — the in-viewer
            // image-only pan (suppressDismissPan: false) owns the drag-down close, like the album viewer.
            Group {
                if msg.viewOnce, msg.isAudio {
                    // ONE-TIME VOICE opens as a PAGE — his order, the reference's model, and the
                    // exact shape of the view-once photo below: replay freely while the page is
                    // up, and closing it is what spends the listen (the same onDismiss mark).
                    OneTimeVoicePage(message: msg, cid: cid, dark: dark)
                        .onAppear { if msg.authorId != me { pendingViewOnceConsume = msg } }
                } else if msg.viewOnce {
                    // View-once opens ALONE (no paging into it, not part of the gallery).
                    ImageViewerView(message: msg, cid: cid,
                                    onDeleteForMe: { m in deleteForMe(m) },
                                    clipProvider: { MediaOpenRects.clipRect })
                        .onAppear { if msg.authorId != me { pendingViewOnceConsume = msg } }
                } else {
                    // A SINGLE PHOTO OPENS ALONE (user spec 2026-07-29: "when i send only one image then
                    // i click i see multi image… bottom thumbnails is only group images, not single
                    // image"). This used to hand the viewer EVERY photo in the conversation so you could
                    // page between unrelated messages, which meant one photo arrived with a filmstrip of
                    // other people's pictures under it and swiped away to them. Albums still open as a
                    // group — that gallery comes from the album's own items, further down.
                    ImageViewerView(message: msg, cid: cid,
                                    onSendEdited: { data, caption, viewOnce in
                                        Task { await sendPhoto(data, viewOnce: viewOnce, caption: caption) }
                                    },
                                    onDeleteForMe: { m in deleteForMe(m) },
                                    clipProvider: { MediaOpenRects.clipRect })
                }
            }
            // No transition modifier: MediaOpen flies the media BEFORE this cover presents, and
            // MediaDismissHost owns the drag-down close. The disabled ConditionalZoomTransition that
            // used to sit here was the last trace of the system zoom for chat media.
        }
        .photosPicker(isPresented: $showLibrary, selection: $photoItems, maxSelectionCount: Limits.mediaPerMessage, matching: .any(of: [.images, .videos]))
    }

    // Third slice of the picker chain (album/video viewers onward), joined to threadPickersA via an
    // erased boundary so neither half exceeds the type-check budget.
    private var threadPickersB: some View {
        AnyView(threadPickersA)
        // Album gallery: swipe between all the album's photos, starting on the tapped one. SAME native
        // zoom hero as single photos (user spec): each album CELL is a matchedTransitionSource with the
        // synthetic per-item id, so the viewer grows out of the tapped tile and the button-close shrinks
        // back into it. The drag-down close stays media-only via MediaDismissHost.
        // The album list. Its viewers are presented from INSIDE it, so closing a photo returns to the
        // group instead of dropping you back out to the chat (explicit user requirement).
        //
        // A SHEET, not a fullScreenCover, so you can leave it by SWIPING DOWN with your thumb (user
        // request). That interactive dismissal is native: it follows the finger, springs back if you
        // change your mind, and knows to only start when the list is scrolled to the top - none of
        // which a hand-rolled drag would get right.
        .sheet(item: $albumScreen) { m in
            AlbumScreenView(message: m, cid: cid,
                            senderName: m.authorId == me ? "You" : personName(m.authorId),
                            onSave: { img in Task { await saveImageToPhotos(img) } })
        }
        .fullScreenCover(item: $albumViewer) { wrap in
            ImageViewerView(message: wrap.gallery.first { $0.id == wrap.startId } ?? wrap.gallery[0],
                            in: wrap.gallery, cid: cid,
                            onSendEdited: { data, caption, viewOnce in
                                Task { await sendPhoto(data, viewOnce: viewOnce, caption: caption) }
                            },
                            onDeleteForMe: { m in deleteForMe(m) },
                            clipProvider: { MediaOpenRects.clipRect })
            // NO `.navigationTransition(.zoom)` here any more. The album viewer was the last place the
            // SYSTEM zoom transition still ran for chat media, and it is a third pipeline: it scales the
            // entire presented cover — backdrop, header, thumb strip, toolbar — out of the tapped tile,
            // while single photos and videos fly only the media through MediaOpen. Now that album
            // tiles fly too, leaving this on would run both animations over each other.
        }
        .fullScreenCover(item: $viewerVideo) { msg in
            VideoPlayerScreen(message: msg, cid: cid,
                              clipProvider: { MediaOpenRects.clipRect })
                // No transition modifier: the poster flies via MediaOpen before this presents,
                // exactly like photos. One pipeline, both directions.
        }
        // Picked video → approval page (caption) before sending, like the image editor (not auto-send).
        .fullScreenCover(item: $videoToApprove) { wrap in
            VideoApprovalView(url: wrap.url) { finalURL, caption, hd in
                Task { await sendVideo(from: finalURL, caption: caption, hd: hd) }
            }
        }
        .sheet(isPresented: $showAttachPanel, onDismiss: { recentsHasSelection = false; attachDetent = ThreadView.attachOpenDetent }) {
            attachPanel
                .presentationDetents([ThreadView.attachOpenDetent, .large], selection: $attachDetent)   // ~62% open, pull up for more
                // SOLID system background (white in light / dark in dark mode) — the default iOS 26 glass
                // sheet showed the chat blurring through, which read as a broken half-empty panel.
                .presentationBackground(Color(.systemBackground))
                // THE REFERENCE APP MODEL (user request 2026-07-14, replacing the brief zoom-from-+ experiment):
                // the reference app's attachment menu is a spring bottom sheet — it slides up from the bottom
                // edge with a quick spring, drags between part/full height, and a downward drag or flick
                // dismisses it. That is EXACTLY the native sheet-with-detents behavior, so the system
                // presentation owns it: no transition override. (The zoom morph fought the detent snap.)
        }
        .sheet(item: $comingSoon) { c in comingSoonSheet(c).presentationDetents([.fraction(0.6)]) }
        // Call-back confirm: tapping a call-history row asks first (never dials on a stray tap).
        .alert(pendingCallBack == .video ? "Video call" : "Voice call",
               isPresented: Binding(get: { pendingCallBack != nil }, set: { if !$0 { pendingCallBack = nil } }),
               presenting: pendingCallBack) { kind in
            Button("Cancel", role: .cancel) { }
            Button("Call") {
                CallService.shared.startCall(to: otherUid, name: title, photo: photoUrl, video: kind == .video)
            }
        } message: { kind in
            Text("\(kind == .video ? "Video call" : "Call") \(title)?")
        }
        // ⚠️ THE REFUSAL HAS TO BE SHOWN WHERE THE CALL WAS ATTEMPTED.
        //
        // His report: tapping call on somebody who restricts calls does NOTHING, and then the
        // "Can't Call" alert turns up on the chat LIST after he swipes back. That is exactly what
        // it was: the alert was declared only on ChatsView, and a SwiftUI alert cannot present from
        // a view that is not on screen. The state was set the instant he tapped, and the alert
        // waited for its view to come back.
        //
        // The same state, bound again here, so whichever screen is in front says it. The two can
        // never disagree because there is only one `restrictedCallee` and dismissing either clears
        // it — and a screen that is not on top has nothing to present anyway.
        .alert("Can't Call",
               isPresented: Binding(get: { CallService.shared.restrictedCallee != nil },
                                    set: { if !$0 { CallService.shared.restrictedCallee = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("This person restricts who can call them.")
        }
    }

    // Fourth slice of the picker chain (location onward), joined via an erased boundary.
    private var threadPickersC: some View {
        AnyView(threadPickersB)
        // "Select Location" map (user design): permission → GPS/pan/search → Send Location outputs the
        // coordinates, delivered as an encrypted location-card message.
        .sheet(isPresented: $showLocationShare) {
            LocationPickerSheet { lat, lon, label in
                Task {
                    try? await ChatService.sendText(
                        cid: cid,
                        text: Message.locationMarkerText(lat: lat, lon: lon, label: label),
                        group: isGroup ? groupMembers : nil)
                }
            }
        }
        // DELETED HERE: the Share Contact picker sheet, with the attach tile that opened it. Contact
        // cards already SENT still render — Message.contactMarkerText and the card bubble are
        // untouched, so nobody's history changes.
        // New-poll composer (groups): sends the poll as an encrypted "fariin-poll:" marker message.
        .sheet(isPresented: $showPollComposer) {
            PollComposerSheet { marker in
                showAttachPanel = false
                Task { try? await ChatService.sendText(cid: cid, text: marker, group: isGroup ? groupMembers : nil) }
            }
        }
        .sheet(isPresented: $showGifPicker) {
            GifPickerView { gif in
                // OPTIMISTIC, exactly like a text send (user: "make it like how it works when I send a
                // new message"). The bubble lands locally the moment you pick — and that local insert
                // is what fires the send glide to the newest message. GIF was the one send type without
                // an optimistic bubble: it only appeared on the server echo, which never scrolled.
                let clientId = UUID().uuidString
                repo.addPending(Message(localGifUrl: gif.url, width: gif.width, height: gif.height,
                                        authorId: me, clientId: clientId, sendState: .sending))
                Task {
                    // Surface failures — the old try? made a failed send look like a dead tap.
                    do { try await ChatService.sendGif(cid: cid, url: gif.url, width: gif.width, height: gif.height, clientId: clientId, group: isGroup ? groupMembers : nil) }
                    catch { await MainActor.run { repo.markFailed(clientId: clientId); sendError = "Couldn't send the GIF. Check your connection and try again." } }
                }
            }
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.item], allowsMultipleSelection: false) { result in
            handlePickedFile(result)
        }
        // Full SHEET page (user spec): rounded top + grabber + a real close button. The old
        // .ignoresSafeArea stretched the preview edge-to-edge, hiding the grabber and any Done chrome —
        // and since file content scrolls, swipe-down scrolled the text instead of dismissing ("can't
        // close it"). PDFs get the same sheet look instead of a bare full page.
        .sheet(item: $filePreview) { FilePreviewSheet(url: $0.url) }
    }

    // Fifth slice of the picker chain (link/not-found/pdf/reaction/forward/group/info), erased boundary.
    private var threadPickersD: some View {
        AnyView(threadPickersC)
        // ONE link-confirm + one not-found alert for the whole conversation (hoisted out of every bubble:
        // ~40 live cells each carried their own presentation machinery, anchored inside recyclable cells).
        .confirmationDialog("Open link?",
                            isPresented: Binding(get: { tappedLink != nil },
                                                 set: { if !$0 { tappedLink = nil } }),
                            titleVisibility: .visible, presenting: tappedLink) { url in
            Button("Open") { UIApplication.shared.open(url) }
            Button("Cancel", role: .cancel) {}
        } message: { url in Text(url.absoluteString) }
        .alert("Sorry, this user doesn't seem to exist.", isPresented: $tappedUserNotFound) {
            Button("OK", role: .cancel) {}
        }
        .fullScreenCover(item: $pdfDoc) { PDFViewerSheet(url: $0.url, title: $0.title) }
    }

    private var threadContent: some View {
        threadPickers
        // the reference app's flow for the bar's "…": the sheet presents OVER the still-open menu blur, and
        // its resolution — pick OR cancel — is what closes the overlay (no overlay = no-op; the
        // old native-menu React… path reaches this same sheet with no overlay up).
        .sheet(item: $morePickerTarget, onDismiss: { CMOverlay.current?.dismiss(animated: true) }) { m in
            EmojiMorePicker { emoji in react(m, emoji) }
        }
        .sheet(item: $reactorsTarget) { m in
            ReactorsSheet(reactions: m.reactions, nameFor: { personName($0) })
        }
        .sheet(item: $forwardTarget) { m in
            ForwardPicker(message: m, sourceCid: cid,
                          onQueued: { showJumpToast($0) },
                          onFailed: { showJumpToast("Couldn't forward some messages") })
        }
        .sheet(isPresented: $showGroupAdd) {
            AddMembersSheet(cid: cid, existing: Set(groupMembers))
        }
        .sheet(item: $infoTarget) { m in
            MessageInfoView(message: m, members: groupMembers.filter { $0 != me },
                            lastRead: repo.memberLastRead,
                            nameFor: { personName($0) }, photoFor: { conversation?.photos[$0] })
        }
        .sheet(isPresented: Binding(get: { bulkForward != nil }, set: { if !$0 { bulkForward = nil } })) {
            if let msgs = bulkForward {
                ForwardPicker(messages: msgs, sourceCid: cid, onSent: { exitSelection() },
                              onQueued: { showJumpToast($0) },
                              onFailed: { showJumpToast("Couldn't forward some messages") })
            }
        }
        .sheet(isPresented: $showPinnedSheet) {
            PinnedMessagesSheet(
                // items, not messages — same hidden-filter reason as the pin bar above, and the same
                // fetched-by-id fallback: this list had the identical hole, so "See All" quietly
                // showed you only the pins that happened to be on screen.
                pinned: visiblePinIds.compactMap { id in
                    repo.items.first { $0.id == id } ?? repo.pinnedPreviews[id]
                }
                .sorted { $0.createdAt < $1.createdAt },
                me: me, cid: cid, title: title,
                nameFor: { personName($0) },
                canUnpin: !isGroup || (conversation?.adminCan(me, .pinMessages) ?? false),
                onUnpin: { id in Task { await ChatService.removePinnedMessage(cid, id) } },
                onTap: { id in
                    showPinnedSheet = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        Task { await repo.ensureLoaded(id); await MainActor.run { flashAndScroll(id) } }
                    }
                })
        }
        .alert("Delete \(selectedIds.count) message\(selectedIds.count == 1 ? "" : "s")?",
               isPresented: $showBulkDeleteConfirm) {
            // Same options as the single-message delete (user report: bulk delete offered only one
            // option). "Delete for Everyone" shows when the selection contains any of my own messages
            // (it removes mine for everyone and hides the rest locally); "Delete for Me" hides all locally.
            if selectionHasMine {
                Button("Delete for Everyone", role: .destructive) { bulkDelete(everyone: true) }
            }
            Button("Delete for Me", role: .destructive) { bulkDelete(everyone: false) }
            Button("Cancel", role: .cancel) {}
        }
        // Pinned-message bar: docked at the top via safeAreaInset (the SAME reliable mechanism the search
        // bar uses) so it ALWAYS sits right below the nav bar — never mid-screen. The old approach placed it
        // as an overlay padded by a controller-reported navBarHeight, which repeatedly came back wrong and
        // dropped the bar into the middle of the conversation.
        .safeAreaInset(edge: .top) { topPinArea }
        // In-chat search: a top bar replaces the nav bar; the ↑/↓ nav bar (searchNavBar) replaces the
        // composer above the keyboard.
        .safeAreaInset(edge: .top) { if searchActive { searchBar } }
        // Media auto-download policies: prefetch this chat's videos/voice per setting +
        // network, so tapping them later plays instantly (files skipped over 200 MB).
        //
        // ⚠️ KEYED ON THE MESSAGE COUNT, NOT JUST THE CHAT — this used to be `.task(id: cid)`, which
        // meant it ran ONCE, on open, over whatever happened to be loaded at that second. So the case
        // that matters most was never covered: a note that ARRIVES while you are sitting in the chat.
        // She sends one, you tap it, and it spins, because the only sweep this chat will ever do already
        // happened. Older history you scrolled back to was missed for the same reason.
        //
        // The count also gives the debounce for free. `.task(id:)` cancels and restarts when the id
        // changes, so a burst of five arriving messages does not start five sweeps — the first four are
        // cancelled inside the sleep and one sweep runs 1.2s after the last one lands. The sweep itself
        // is already idempotent: it skips anything cached and anything in flight.
        .task(id: "\(cid)-\(repo.items.count)") {
            try? await Task.sleep(nanoseconds: 1_200_000_000)   // let the open settle first
            guard !Task.isCancelled else { return }
            MediaAutoDownloader.sweep(repo.items, cid: cid)
        }
        // LAND ON THE NOTE, not just in its chat. Tapping the floating voice bar used to open the
        // conversation wherever it normally opens, leaving you to hunt for the one bubble that was
        // moving. `initialScrollId` above covers the note already being loaded; this covers the rest by
        // paging back to it, which is the same `ensureLoaded` + `flashAndScroll` pair a tap on a reply
        // quote has always used.
        //
        // ⚠️ CONSUMED IMMEDIATELY, BEFORE THE AWAIT. If it were cleared afterwards, walking into a
        // different chat while this was still paging would let THAT chat pick the id up and go looking
        // for a message that was never in it.
        .task(id: cid) {
            guard let target = AppRouter.shared.pendingMessageId else { return }
            AppRouter.shared.pendingMessageId = nil
            // The repository starts loading with the view, so give the first page a moment to land
            // rather than paging backwards from an empty list.
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            if !repo.items.contains(where: { $0.id == target }) {
                await repo.ensureLoaded(target)
            }
            // Not in this chat at all, or too far back to reach: leave the chat where it opened rather
            // than scrolling somewhere arbitrary.
            guard repo.items.contains(where: { $0.id == target }) else { return }
            flashAndScroll(target)
        }
        .toolbar(searchActive ? .hidden : .automatic, for: .navigationBar)
    }

    var body: some View {
        // READ-RECEIPT LIVE FIX: read otherLastReadMillis DIRECTLY in the body so a live read update re-runs
        // the view. It's otherwise only read inside the rowSignatures helper — and unlike pins/reactions
        // (read directly in the body), that wasn't enough to refresh the tick, so my ✓ stayed single until a
        // full reload. This body-level read makes the tick flip to ✓✓ the moment the other person reads.
        let _ = repo.otherLastReadMillis
        threadContent
        // Chat wallpaper picker. ContactInfoView's "Change Wallpaper" pops back to this chat and
        // posts this notification, so the picker opens here (over the live chat, previewing behind).
        .sheet(isPresented: $showWallpaper) { WallpaperPickerSheet(cid: cid) }
        .onReceive(NotificationCenter.default.publisher(for: .openChatWallpaper)) { note in
            guard (note.object as? String) == cid else { return }
            showWallpaper = true
        }
        // "Go to Chat" from the media gallery: pop the profile/gallery push back to this chat, then
        // scroll to + flash the message.
        // Voice-note auto-advance: when a note finishes naturally, chain into the NEXT voice
        // message below it (scroll it into view + play), voicemail-style. Stops at the last one.
        .onReceive(NotificationCenter.default.publisher(for: .voiceNoteFinished)) { note in
            guard let id = note.object as? String,
                  let idx = repo.items.firstIndex(where: { $0.id == id }) else { return }
            // Never chain INTO a one-time note: auto-advance would spend its single listen on
            // somebody who never chose to open it.
            guard let next = repo.items.dropFirst(idx + 1).first(where: { $0.isAudio && !$0.viewOnce }) else { return }
            nativeScrollTarget = next.rowId
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                NotificationCenter.default.post(name: .voiceNotePlay, object: next.id)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .goToMessage)) { note in
            guard let p = note.object as? GoToMessage, p.cid == cid else { return }
            // Collapse the whole profile→gallery branch with animations DISABLED. SwiftUI's nested
            // boolean navigation pops one level at a time (gallery→profile→chat), so an animated pop
            // FLASHES the profile. Disabling the animation cuts straight to the conversation — the
            // profile is never rendered. (ContactInfoView clears showAllMedia the same way.)
            var t = Transaction(); t.disablesAnimations = true
            withTransaction(t) { showContactInfo = false }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                Task { await repo.ensureLoaded(p.messageId); await MainActor.run { flashAndScroll(p.messageId) } }
            }
        }
        .sheet(item: $tappedMember) { m in
            GroupMemberSheet(cid: cid, member: m,
                             iAmAdmin: conversation?.isAdmin(me) ?? false,
                             ownerUid: conversation?.createdBy ?? "",
                             canManageAdmins: (conversation?.createdBy == me && !(conversation?.createdBy.isEmpty ?? true)),
                             canRestrict: conversation?.adminCan(me, .banUsers) ?? false,
                             currentRights: conversation?.adminRights[m.id],
                             mutedUntil: conversation?.restrictedUntil[m.id] ?? 0)
                .presentationDetents([.medium, .large])
        }
        .fullScreenCover(isPresented: $showGroupCall) { GroupCallView() }
        .safeAreaInset(edge: .top) {
            if groupCallActive && !GroupCallService.shared.isActive {
                Button {
                    showGroupCall = true
                    Task { await GroupCallService.shared.start(cid: cid, title: title, video: groupCallVideo) }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: groupCallVideo ? "video.fill" : "phone.fill")
                        Text("Group call in progress").fontWeight(.medium)
                        Spacer()
                        Text("Join").fontWeight(.semibold)
                    }
                    .font(.subheadline).foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(Color.green)
                }
            }
        }
        .modifier(MessageActionDialogs(cid: cid, title: title, me: me,
                                       pendingDelete: $pendingDelete,
                                       onDeleteForMe: { m in deleteForMe(m) },
                                       onMarkDeleted: { m in repo.markDeletedLocally(m.id) },
                                       onRestoreDeleted: { m in repo.restoreAfterFailedDelete(m.id) }))
        .onChange(of: ConversationsRepository.shared.conversations) { _, list in
            let resolved = list.first { $0.id == cid }   // O(n) ONCE per change, not per render
            if resolved != cachedConv { cachedConv = resolved }
        }
        .onAppear {
            cachedConv = ConversationsRepository.shared.conversations.first { $0.id == cid }
            repo.start()
            // ONE drain per chat open (audit S5): onAppear also fires returning from an in-chat push,
            // and a re-drive racing the still-in-flight original produced a duplicate server doc and
            // over-counted the recipient's unread badge.
            if !drainGate.done {
                drainGate.done = true
                Task { await drainSendQueue() }          // re-drive any text send lost to an app kill
            }
            // No unconditional recorder.prepare() here: it triggered the mic-permission prompt the
            // moment ANY chat opened. Permission is asked on the first real hold (requestAndStart),
            // and the session re-warms itself after each record (AudioRecorder.reset → prepare).
            //
            // …but when permission is ALREADY GRANTED there is no prompt to fear, and NOT warming
            // was his "sometimes the tap says hold to record, tap again works" bug: the first hold
            // in a fresh chat hit a recorder still assembling itself (async permission callback +
            // session setup on a background queue), so `isRecording` was still false when a real
            // tap's finger lifted, and the tap-to-lock guard read that as nothing recording. The
            // second tap found the recorder the first one's cleanup had warmed. Warm it up front
            // instead — prepare() prompts nothing when permission is granted and no-ops when a
            // recorder already stands.
            if AVAudioApplication.shared.recordPermission == .granted { recorder.prepare() }
            // Call/Siri/alarm mid-record: the recording is PRESERVED (paused, file kept) — flip to the
            // locked bar so the user can send or cancel the partial note (was: recording discarded).
            recorder.onInterrupt = {
                recordDrag = .zero
                holdStarted = false   // recordingHeld is computed (holdStarted && !recordLocked) → goes false
                recordLocked = true
            }
            // A parked note from last time — leaving the chat, or the whole app, mid-recording —
            // is adopted back and the bar lands on the review: listen, continue with the red mic,
            // send or bin. His order, the reference's model: nothing recorded is silently gone.
            if !recordLocked, AudioRecorder.hasDraft(cid), recorder.adoptDraft(cid: cid) {
                recordLocked = true
                beginPreview()
            }
            // Restore an unsent draft (local-only). Never clobber text already being typed.
            // SILENTLY (audit M6): the programmatic set used to fire the typing broadcast — opening a
            // chat with a parked draft showed "typing…" to the other person with zero keystrokes.
            if input.isEmpty { setInputSilently(Drafts.shared.text(cid)) }
            // Unread count from the cached conversation — only used to place the unread-divider
            // MARKER now (we always open at the bottom, so it no longer drives the scroll position).
            unreadOnOpen = cachedConv?.unread(me) ?? 0
            // Gate animated auto-scroll until the push transition + first chunked load settle,
            // so the conversation opens cleanly at the bottom with no jump (defaultScrollAnchor).
            // `settled` gates the message-row slide-in transition. It is flipped true AFTER the reveal
            // (see the didInitialLoad/safety-net handlers), NOT on a fixed timer from here — a timer
            // that expired before a slow chat finished loading let the WHOLE opening batch slide/fade in
            // ("the chat animates open"). Tied to the reveal, the opening batch always just appears.
            settled = false
            if isGroup || !cid.contains("_") { startGroupCallListener() }
            AppRouter.shared.activeChatId = cid          // suppress this chat's own banners
            NotificationCleaner.clear(cid: cid)          // clear its notifications + fix the badge
            RecentsCache.prewarm()   // fetch + decode the media sheet's first thumbs NOW, before + is tapped
            Task {
                // Only needed when this chat wasn't in the cached list (no sync count above).
                if cachedConv == nil {
                    let n = await ChatService.myUnread(cid)
                    await MainActor.run { unreadOnOpen = n }
                }
                await ChatService.resetUnread(cid)
                // Wait for the REAL block state before stamping a read receipt (audit M8): iBlocked
                // defaults to false and the conv listener has only just attached — a blocked contact
                // received a receipt on open despite every other call site gating on iBlocked.
                var waited = 0
                while !repo.convLoaded, waited < 20 {   // ≤2s; then proceed on best-known state
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    waited += 1
                }
                if !repo.iBlocked { await ChatService.markRead(cid) }
            }
        }
        .onDisappear {
            // HAND THE REST OF THE RUN TO THE ENGINE BEFORE ANYTHING ELSE HERE. The auto-advance chain
            // is an `.onReceive` on this view and reads `repo.items`, so both die with it: a run of four
            // notes finished the one in your ear and stopped. This is the last moment the list still
            // exists, and it is before `repo.stop()` on purpose. The engine ignores it whenever the
            // playing note is not from this chat, and drops it again the moment the person picks a note
            // themselves.
            VoiceNotePlayer.shared.handOff(followOn: repo.items,
                                           after: VoiceNotePlayer.shared.messageId)
            repo.stop()
            groupCallListener?.remove(); groupCallListener = nil
            AppRouter.shared.activeChatId = nil
            broadcastTyping(false)
            // Keep the local flag in step with the broadcast we just sent — leaving it true meant a
            // quick return from an in-chat push never re-broadcast typing for the whole next burst
            // (the now != typingSent gate never tripped) (audit).
            typingSent = false
            // The RunLoop retains a live Timer past the view's death — without this, a locked
            // recording carried through navigation would re-broadcast "recording" forever.
            // Same for the typing keep-alive.
            typingBox.recordingRefresh?.invalidate(); typingBox.recordingRefresh = nil
            typingBox.typingRefresh?.invalidate(); typingBox.typingRefresh = nil
            // Messages that arrived while the chat was OPEN were read live but only onAppear reset
            // the stored counter — leaving showed a stale unread badge. Reset on the way out too.
            Task { await ChatService.resetUnread(cid) }
            // Leaving with a recording: a HELD (unlocked) one dies with the finger — the gesture
            // is gone. A LOCKED session (recording or reviewing) PARKS instead — his order, the
            // reference's model: the note stops, its stretches move to a per-chat draft on disk,
            // and the chat's next appearance lands on the review bar. Nothing recorded is lost
            // until the person sends or bins it. (This replaces "a locked recording survives
            // navigation": an in-chat push parks too now — a pause, not the destruction that
            // comment guarded against — and popping back adopts the draft straight away.)
            if recordLocked {
                parkRecordingDraft()
            } else if recorder.isRecording {
                recorder.cancel()
                recordDrag = .zero; holdStarted = false
                recordCancelArmed = false   // audit: a stale armed flag silently discarded the NEXT
                                            // stationary-hold voice note on release
            }
        }
        // Closing the app mid-recording parks the note exactly like leaving the chat — his spec
        // from the reference: kill the app, come back, the chat opens onto the review bar with
        // everything you said still there. Background IS the park point because a killed app gets
        // no goodbye at all; parking on the way to background is the last reliable moment.
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            if recordLocked { parkRecordingDraft() }
        }
        // Scrubbing the review knob right-to-left runs along the HOME INDICATOR's strip, and iOS
        // read it as the app-switch swipe (his report: "the app thinks I am swiping to leave").
        // While the locked bar owns the bottom edge, the system gesture goes soft: the first swipe
        // is ours, and leaving the app takes the deliberate second swipe. Off the moment the bar
        // closes — nobody wants a sticky home indicator in a chat.
        .defersSystemGestures(on: recordLocked ? .bottom : [])
        // Voice-note recording indicator, sender side: isRecording is the single source of truth —
        // it flips for every path (hold, lock, send, cancel, too-short, interruption), so no per-path
        // wiring. While ON, refresh every 10s: receivers self-clear at 15s and a note runs longer.
        .onChange(of: recorder.isRecording) { _, rec in
            typingBox.recordingRefresh?.invalidate(); typingBox.recordingRefresh = nil
            broadcastRecording(rec)
            if rec {
                typingBox.recordingRefresh = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
                    broadcastRecording(true)
                }
            }
        }
        .onChange(of: photoItems) { _, items in Task { await sendPickedMulti(items) } }
        // Draft follows every edit (so the chat list is correct the moment you leave), but
        // NOT while inline-editing a sent message — that text is the message, not a draft.
        .onChange(of: input) { _, v in
            if editingMessage == nil { Drafts.shared.set(cid, v) }
        }
    }

    private var hasText: Bool {
        !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // Resolving Calendar.current re-reads the user's locale/calendar each call; these helpers run
    // ~4-5x per row per render, so cache one instance.
    private static let cal = Calendar.current

    private func shouldShowDate(at index: Int) -> Bool {
        let items = repo.items
        guard index > 0, index < items.count else { return true }
        return !Self.cal.isDate(items[index - 1].createdAt, inSameDayAs: items[index].createdAt)
    }

    // Grouping: tight (2pt) inside a same-sender cluster, standard (14pt) on a new
    // cluster. The date separator carries its own gap.
    private func topGap(at index: Int) -> CGFloat {
        if shouldShowDate(at: index) { return 0 }
        return isFirstInCluster(at: index) ? 14 : 2
    }

    private static let clusterGap: TimeInterval = 300   // 5 min breaks a cluster

    // A new cluster starts on a date change, a sender change, or a >5min time gap.
    private func isFirstInCluster(at index: Int) -> Bool {
        let items = repo.items
        guard index > 0, index < items.count else { return true }
        if shouldShowDate(at: index) { return true }
        if items[index - 1].authorId != items[index].authorId { return true }
        return items[index].createdAt.timeIntervalSince(items[index - 1].createdAt) > Self.clusterGap
    }

    // A cluster ends at the last message, a sender change, a date change, or a >5min gap.
    private func isLastInCluster(at index: Int) -> Bool {
        let items = repo.items
        guard index >= 0, index < items.count - 1 else { return true }
        let next = items[index + 1], cur = items[index]
        if !Self.cal.isDate(cur.createdAt, inSameDayAs: next.createdAt) { return true }
        if next.authorId != cur.authorId { return true }
        return next.createdAt.timeIntervalSince(cur.createdAt) > Self.clusterGap
    }

    private func dayLabel(_ d: Date) -> String {
        let cal = Self.cal
        if cal.isDateInToday(d) { return "Today" }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        return d.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }

    /// Pins minus the ones I deleted "for me".
    ///
    /// `deleteMessage` (Delete for Everyone) drops the id from `pinnedMessageIds`, so that half
    /// already unpins itself. Delete for Me only hides the message on THIS device, and the pin is
    /// shared state — removing it there would yank the other person's pin too, which is the one
    /// thing Delete for Me must never do. So the local half is filtered here instead, and the bar
    /// disappears for me while their bar keeps working.
    ///
    /// Merely-unloaded ids are NOT dropped: `repo.pinnedPreviews` fetches those by id, so a pin
    /// older than the loaded window has a real name and a real snippet like any other.
    ///
    /// Ids the repository has PROVEN are gone are dropped, which is the reference app's rule — their banner
    /// shows nothing rather than a placeholder for a message it cannot resolve. Proven means a read
    /// came back saying the document does not exist, never a read that merely failed.
    private var visiblePinIds: [String] {
        repo.pinnedMessageIds.filter { !HiddenMessages.isHidden($0) && !repo.pinnedGone.contains($0) }
    }

    // Liquid-Glass pinned-message bar below the nav (tap to scroll to it; pin.slash to unpin).
    @ViewBuilder private var pinnedBar: some View {
        if !visiblePinIds.isEmpty {
            let ids = visiblePinIds
            let idx = min(pinIndex, ids.count - 1)
            let pid = ids[idx]
            // repo.ITEMS, not repo.messages (audit): items is the hidden-filtered list the chat
            // renders, so a pin the user deleted "for me" kept showing its author, snippet and photo
            // here while tapping it correctly said the message was gone.
            //
            // …then `pinnedPreviews`, which is the pin fetched by its own id. The window is what is on
            // SCREEN and a pin is usually older than that, so the window alone is why this bar has
            // been reading "Pinned Message / Tap to view". The window still goes first: it holds the
            // live copy, so an edit or a reaction shows here without a second fetch.
            let msg = repo.items.first { $0.id == pid } ?? repo.pinnedPreviews[pid]
            let author = msg.map { personName($0.authorId) } ?? "Pinned Message"
            HStack(spacing: 10) {
                // Vertical count indicator (one bar per pin, current highlighted).
                if ids.count > 1 {
                    VStack(spacing: 2) {
                        ForEach(0..<ids.count, id: \.self) { i in
                            Capsule().fill(i == idx ? Color.accentColor : Color.secondary.opacity(0.4))
                                .frame(width: 2.5, height: i == idx ? 16 : 7)
                        }
                    }
                }
                if let m = msg, m.isImage, let url = m.imageUrl {
                    SecureImageView(imageUrl: url, enc: m.enc, cid: cid)
                        .frame(width: 32, height: 32)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                } else if let m = msg, m.isAlbum, let first = m.album.first {
                    SecureImageView(imageUrl: first.imageUrl, enc: first.enc, cid: cid)
                        .frame(width: 32, height: 32)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                } else if let m = msg, m.isGif, let url = m.imageUrl {
                    AnimatedGifView(url: url)
                        .frame(width: 32, height: 32)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                } else if let m = msg, m.isFile {
                    // A pinned FILE showed a blank bar (owner screenshot): no branch here and its
                    // snippet is empty text. The document preview (PDF page 1 / image pixels) rides
                    // thumbUrl exactly as the bubble draws it; other file types keep the doc glyph.
                    if let t = m.thumbUrl, !t.isEmpty {
                        SecureImageView(imageUrl: t, enc: m.thumbEnc, cid: cid)
                            .frame(width: 26, height: 32)
                            .background(Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(Color.black.opacity(0.12), lineWidth: 0.5))
                    } else {
                        Image(systemName: "doc.fill").font(.system(size: 20))
                            .foregroundStyle(.secondary)
                            .frame(width: 26, height: 32)
                    }
                }
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(author).font(.system(size: 15, weight: .semibold)).foregroundStyle(.primary).lineLimit(1)
                        if ids.count > 1 {
                            Text("\(idx + 1)/\(ids.count)").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Text(msg.map { m in
                        m.isAlbum ? (m.text.isEmpty ? "\(m.album.count) Photos" : m.text)
                        : (m.isGif ? "GIF" : (m.isImage ? (m.viewOnce ? "View-once photo" : "Photo") : (m.isVideo ? "Video" : (m.isAudio ? "Voice message" : (m.isFile ? (m.fileName ?? "File") : m.safeText)))))
                    } ?? "Tap to view")
                        .font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                // Pin icon → context menu: Unpin (admin/1:1 only) + See All (full pinned-messages sheet).
                Menu {
                    if !isGroup || (conversation?.adminCan(me, .pinMessages) ?? false) {
                        Button {
                            Task { await ChatService.removePinnedMessage(cid, pid) }
                            if pinIndex > 0 { pinIndex -= 1 }   // keep index valid after removal
                        } label: { Label("Unpin", systemImage: "pin.slash") }
                    }
                    Button {
                        // Opens straight away now. This used to page older history for EVERY pin
                        // before the sheet could build — up to 12 pages each, five times over, with
                        // the menu just sitting there — because the list could only resolve pins that
                        // were in the window. `pinnedPreviews` already holds them, so there is
                        // nothing to wait for and nothing to load into memory.
                        showPinnedSheet = true
                    } label: { Label("See All", systemImage: "list.bullet") }
                } label: {
                    // Upright pin in a bordered circle (reference: image-2 style).
                    // 22 in 36 is the reference app's own proportion for this button: their banner pin is a
                    // 24pt glyph with `contentInsets .init(margin: 6)`, so the glyph owns two thirds
                    // of the button. 17 in 34 was half of it, which is the "too small" he reported —
                    // the same wrong number, from the same wrong reasoning, as the menu icons.
                    Image("ic_pin_bar").renderingMode(.template).resizable().scaledToFit()
                        .frame(width: MenuIcon.standard, height: MenuIcon.standard)
                        .foregroundStyle(.primary)
                        .frame(width: 36, height: 36)
                        .overlay(Circle().strokeBorder(.primary.opacity(0.35), lineWidth: 1.5))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.leading, 14).padding(.trailing, 8)
            .frame(height: 48)
            .liquidGlass(RoundedRectangle(cornerRadius: 24, style: .continuous), interactive: true)
            .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .onTapGesture {
                // Three outcomes, and only one of them used to exist.
                //
                // `ensureLoaded` pages older history looking for the message and gives up after 12
                // pages, about 480 messages. Everything past that was reported as "Pinned message was
                // deleted", which is not true and was never likely to be: delete-for-everyone already
                // drops the pin (ChatService.removePinnedMessage), so a pin that still exists is
                // almost never a deleted message. It is simply too old to reach by paging.
                //
                // So: jump to it when we can reach it. Say deleted only when the repository has PROVEN
                // it is gone. Otherwise the message is real and out of reach, and the pinned list can
                // show it to him — which is the one thing that beats a sentence explaining why not.
                Task {
                    await repo.ensureLoaded(pid)
                    await MainActor.run {
                        if repo.items.contains(where: { $0.id == pid }) { flashAndScroll(pid) }
                        else if repo.pinnedGone.contains(pid) { showJumpToast("Pinned message was deleted") }
                        else { showPinnedSheet = true }
                    }
                }
                if ids.count > 1 { pinIndex = (idx + 1) % ids.count }   // next tap shows the next pin
            }
            // 20pt = the nav bar's own button inset on iOS 26 (the glass back-button circle's leading
            // edge). scenePadding resolved to 16pt here, leaving the bar poking 4pt past the back button;
            // this lines the bar's edges up exactly under the back button and the call/video pill.
            .padding(.horizontal, 20)
            .padding(.top, 6).padding(.bottom, 2)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private var presenceSubtitle: String? {
        if isGroup {
            // Show who's typing in the group; otherwise the member count.
            if typingPref, repo.otherTyping, !repo.typingNames.isEmpty {
                let first = repo.typingNames.first ?? "Someone"
                return repo.typingNames.count == 1 ? "\(first) is typing…" : "\(repo.typingNames.count) people typing…"
            }
            return conversation?.memberCountLabel
        }
        if repo.iBlocked { return nil }   // blocked: don't reveal their typing/online/last-seen
        if typingPref && repo.otherTyping { return "typing…" }   // reciprocal: only if I share typing
        // Reciprocal (my audience isn't "No One") AND their audience allows me (in a chat
        // together we're contacts, so only their "No One" hides it — defense in depth on
        // top of their client not publishing at all).
        // contactOfMine was hardcoded true — "we're in a chat together" — but an EMPTY chat opened
        // from an @handle search is also a chat, so a stranger saw a My-Friends-only last-seen in
        // the header (audit). Ask the same message-history rule the profile page uses.
        if PrivacyPrefs.mine("lastSeen") != .nobody && lastSeenPref,
           PrivacyPrefs.allows(repo.otherPrivacy, "lastSeen",
                               contactOfMine: PrivacyPrefs.isContact(otherUid)) {
            if repo.otherOnline { return "online" }
            if let la = repo.otherLastActive {
                let f = RelativeDateTimeFormatter(); f.unitsStyle = .short
                return "last seen " + f.localizedString(for: la, relativeTo: Date())
            }
        }
        return nil
    }

    private var otherUid: String {
        cid.split(separator: "_").map(String.init).first { $0 != me } ?? ""
    }

    // Cached conversation: resolved once + refreshed only when it changes (onAppear + onChange
    // below), so reading it per render is O(1) instead of an O(n) scan of the whole conversations
    // singleton on every body pass (and a body re-eval on unrelated chats stays cheap).
    @State private var cachedConv: Conversation?
    private var conversation: Conversation? { cachedConv }
    private var isGroup: Bool { conversation?.isGroup ?? false }
    private var groupMembers: [String] { conversation?.users ?? [] }

    // Extracted from `body` so the type-checker can handle the screen (the inline ForEach
    // with all its closures was too complex as one expression after the header refactor).
    @ViewBuilder
    // Intro card at the top of a group: avatar, name, members,
    // "you created this group", and an Add Members CTA (admins).
    private var groupIntroCard: some View {
        VStack(spacing: 8) {
            AvatarView(name: conversation?.title ?? "Group", photoUrl: conversation?.avatarUrl, size: 72)
            Text(conversation?.title ?? "Group").font(.headline)
            Text(conversation?.memberCountLabel ?? "").font(.caption).foregroundStyle(.secondary)
            if conversation?.createdBy == me {
                Text("You created this group").font(.caption).foregroundStyle(.secondary)
            }
            if (conversation?.adminCan(me, .inviteUsers) ?? false) || (conversation?.membersCanAdd ?? false) {
                Button { showGroupAdd = true } label: {
                    Label("Add Members", systemImage: "person.badge.plus")
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 18).padding(.vertical, 9)
                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22).padding(.horizontal, 18)
        .background(Color.gray.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.horizontal, 36).padding(.top, 14).padding(.bottom, 6)
    }

    // (The old SwiftUI fallback list was deleted 2026-07-11 — the UIKit list is THE list.
    // Its ForEach(Array(repo.items.enumerated())) copied every Message per render and watchdogged
    // build 280 on the main thread.)

    // ONE row builder used by the UIKit list for every row (date/divider/bubble), proxy-free.
    // The per-chat custom bubble colour (local). Reading `.version` registers observation so bubbles
    // re-render live when the colour is changed in the wallpaper sheet.
    private var chatColorSpec: ChatColorSpec? {
        _ = ChatColorStore.shared.version
        return ChatColorStore.shared.color(for: cid)
    }

    @ViewBuilder
    private func rowView(at index: Int, _ msg: Message, jumpTo: @escaping (String) -> Void) -> some View {
        if shouldShowDate(at: index) {
            // Inline day separator: translucent pill. NOT Liquid Glass (user clarified 2026-07-14:
            // only the TOP floating "Today" pill is glass — the in-chat separators keep this look).
            Text(dayLabel(msg.createdAt))
                .modifier(ChatNoticePill())
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        }
        if msg.id == firstUnreadId { unreadDivider }
        if let pin = msg.pinNotice {
            // reference-style "X pinned …" notice: centered capsule, tap jumps to the pinned message.
            pinNoticeRow(msg, pin, jumpTo: jumpTo).id(msg.id)
        } else if msg.isFeatureMarker && msg.contactCard == nil && msg.locationCard == nil && msg.poll == nil {
            // A reserved kulan-…: payload we can't render as a card — either a newer app version's
            // feature OR a malformed known marker. Either way show the system notice, NEVER the raw
            // marker text.
            unsupportedRow(msg).id(msg.id)
        } else if msg.isSystem {
            systemRow(msg).id(msg.id)
        } else if msg.isCall {
            callRow(msg).padding(.top, 8).id(msg.id)
        } else {
            MessageBubble(
                message: msg, isMe: msg.authorId == me, dark: dark, cid: cid,
                nameFor: { personName($0) },
                avatarFor: { conversation?.photos[$0] },
                onReply: { m in beginReply(to: m) },
                onDelete: { pendingDelete = $0 },   // confirm dialog, not instant
                onCancelSending: { m in
                    // Discard the pending optimistic send — and CANCEL the upload behind it. Only
                    // hiding the bubble was the "images appear anyway a minute later" bug: nothing
                    // held the send Task, so it ran to the end and committed. See MediaSend.
                    if let clientId = m.clientId {
                        MediaSend.shared.cancel(clientId)
                        repo.removePending(clientId: clientId)
                    }
                },
                onTapContact: { uid, name, photo in
                    // "message" on a shared-contact card → open (or create) the chat with that user.
                    guard uid != me else { return }           // your own card → no self-chat
                    guard ChatService.convId(me, uid) != cid else { return }   // already in this chat
                    AppRouter.shared.pendingChatName = name    // so a brand-new chat shows the name/photo,
                    AppRouter.shared.pendingChatPhoto = photo   // not the "Chat" placeholder
                    AppRouter.shared.pendingChatId = ChatService.convId(me, uid)
                },
                // OPEN LIKE THE REFERENCE APP: fly only the MEDIA out of its bubble, then reveal the viewer.
                // `.navigationTransition(.zoom)` scaled the ENTIRE cover - black backdrop, header, thumb
                // strip, toolbar - out of the bubble, which is the one thing that never matched the reference app
                // no matter how the timing was tuned. Falls straight through to the plain presentation
                // when there is no live rect or no decoded image to fly, so opening can never be blocked.
                // THE OPEN AND THE CLOSE MUST READ THE SAME GEOMETRY. The close already lands on the
                // bubble's REAL corner radius (MediaDismiss reads MediaOpenRects.cornerRadius);
                // the open was leaving `sourceCornerRadius` at its 14pt default, so media whose bubble
                // has a different radius started the flight at one shape and finished at another. Two
                // directions, two radii, from one registry that already had the right number in it.
                onTapImage: { m in
                    // Scoped key (.chat): All Media and the profile strip register the SAME ids.
                    // Through the gate so a fast re-open right after a close is never swallowed.
                    let key = MediaOpenRects.key(.chat, m.id)
                    MediaOpen.flyOrPresent(
                        imageUrl: m.imageUrl, rectKey: key, clip: MediaOpenRects.clipRect,
                        present: { MediaPresentGate.present { viewerImage = m } })
                },
                // ALBUM IMAGES FLY TOO — this was the last media kind opening with no transition at all
                // (user: "make it sure image video multiple swipe swipe images"). It was never a broken
                // animation, it was a missing one: single photos and videos already called `fly`, and
                // album VIDEO tiles reach it through onTapVideo, but album IMAGE tiles went straight to
                // the pager. The geometry was already there and unused — a tile's rect is registered under
                // `"<messageId>-<index>"`, which is exactly the `startId` handed to us here.
                onTapAlbum: { gallery, startId in
                    let key = MediaOpenRects.key(.chat, startId)
                    MediaOpen.flyOrPresent(
                        imageUrl: gallery.first(where: { $0.id == startId })?.imageUrl,
                        rectKey: key, clip: MediaOpenRects.clipRect,
                        present: {
                            MediaPresentGate.present { albumViewer = AlbumViewerWrap(gallery: gallery, startId: startId) }
                        })
                },
                onOpenAlbum: { m in albumScreen = m },
                // Video takes the SAME path with its poster - one pipeline for all media, which is also
                // how the reference app does it (they fly a still frame for video, never a layer).
                onTapVideo: { m in
                    let key = MediaOpenRects.key(.chat, m.id)
                    MediaOpen.flyOrPresent(
                        imageUrl: m.thumbUrl, rectKey: key, clip: MediaOpenRects.clipRect,
                        present: { MediaPresentGate.present { viewerVideo = m } })
                },
                onReact: { emoji in Task { await ChatService.setReaction(cid: cid, messageId: msg.id, emoji: emoji, toAuthor: msg.authorId, group: isGroup ? groupMembers : nil) } },
                onPin: { m in togglePin(m) },
                onForward: { forwardTarget = $0 },
                // THE SELECTION BLUR, THIRD PASS — the first two were real but incomplete. Entering
                // selection reloads every visible cell; a context menu dismisses by animating its lifted
                // preview back INTO the source cell; reload that cell mid-flight and the system's
                // full-screen blur backdrop is stranded (user screenshot: sharp preview at top, blur
                // everywhere, selection chrome up). The UIKit-menu path waits on its animator. SwiftUI
                // menus give no animator, and the previous fix here — a blind 0.35s delay before the
                // flip — was both too short for a big album preview's dismissal spring AND ungated: at
                // 0.35s the reload landed no matter what was still animating.
                //
                // Now the action ARMS A GATE instead of guessing a delay: menuActionTick tells the list
                // controller "a SwiftUI menu is dismissing right now", canLandLoad holds every reload
                // inside that window, and the deferred selection flip lands through settleFlush the
                // moment it closes. The state flip itself is immediate again, so the selection toolbar
                // appears instantly — only the CELL reload waits, which is exactly the UIKit path's order.
                onSelect: { m in
                    menuActionTick += 1
                    withAnimation(.easeInOut(duration: 0.2)) { selecting = true; selectedIds = [m.id] }
                },
                onInfo: { infoTarget = $0 },
                onEdit: { m in
                    withAnimation(.easeInOut(duration: 0.2)) { editingMessage = m; replyingTo = nil }
                    input = m.text
                    inputFocused = true
                },
                onReactMore: { morePickerTarget = $0 },
                onConfirmLink: { tappedLink = $0 },
                onUserNotFound: { tappedUserNotFound = true },
                isGroup: isGroup,
                onTapReactions: { reactorsTarget = msg },
                onTapSender: { uid in
                    tappedMember = GroupInfoView.MemberAction(
                        id: uid, name: personName(uid), isAdmin: conversation?.isAdmin(uid) ?? false)
                },
                onOpenFile: { m in openFile(m) },
                onSaveImage: { m in Task { await saveImageToPhotos(m) } },
                canPin: !isGroup || (conversation?.adminCan(me, .pinMessages) ?? false),
                isPinned: repo.pinnedMessageIds.contains(msg.id),
                restricted: iAmMuted,
                onResend: { m in resend(m) },
                onJumpTo: { id in jumpTo(id) },
                resolveReplyOriginal: { id in repo.items.first { $0.id == id } },
                onTapStory: { id, author, anchor in openStory(id, author, anchorId: anchor) },
                storyQuoteOpens: true,
                isHighlighted: msg.id == highlightId,
                searchTerm: searchActive ? searchQuery.trimmingCharacters(in: .whitespaces) : "",
                isFirstInCluster: isFirstInCluster(at: index),
                isLastInCluster: isLastInCluster(at: index),
                otherLastRead: (msg.authorId == me && !repo.iBlocked) ? repo.otherLastReadMillis : 0,
                chatColor: chatColorSpec,
                isViewedOnce: msg.viewOnce && (viewedOnceTick >= 0) && ViewedOnce.contains(msg.id)
            )
            .equatable()
            .padding(.top, topGap(at: index))
            .id(msg.id)
            .onAppear { visibleRows.ids.insert(msg.id); schedulePersistScrollPosition() }
            .onDisappear { visibleRows.ids.remove(msg.id) }
            .transition(.identity)
            .modifier(SelectableRow(selecting: selecting, selected: selectedIds.contains(msg.id),
                                    onToggle: { toggleSelect(msg.id) }))
        }
    }

    // The scrolling list itself — the UIKit list when the flag is on, else the
    // SwiftUI ScrollView. Extracted so threadScroll's builder stays under the type-checker limit.
    @ViewBuilder
    private func listContainer(_ proxy: ScrollViewProxy) -> some View {
        // The floating date pill is drawn + updated inside the UIKit list now (no SwiftUI overlay, no
        // topVisibleId round-trip). listContainer is just the list body.
        listBody(proxy)
    }

    // The UIKit list is THE list (user decision 2026-07-11: "completely use this").
    // The old SwiftUI fallback — and its main-thread Message-array copy that watchdogged build 280 —
    // is gone along with the Settings toggle.
    @ViewBuilder private func listBody(_ proxy: ScrollViewProxy) -> some View {
        nativeList
            .contentShape(Rectangle())
            // Tap anywhere on the conversation → dismiss the keyboard. This gesture
            // lived on the deleted SwiftUI fallback list; simultaneous so bubble taps still work.
            //
            // …but SIMULTANEOUS means it also fires when the tap was meant for something inside a
            // bubble, which is why tapping a reply quote with the keyboard up both jumped AND closed
            // the keyboard (user: it must work and not close the keyboard, like the reference app). The dismissal
            // is therefore DEFERRED by one runloop turn and cancellable: anything that handles a tap
            // itself and wants the keyboard kept (the quote jump) clears the flag in the same event,
            // and because the cancel and the dismissal cannot race — the dismissal runs strictly after
            // both gestures have fired — the order SwiftUI happens to deliver them in does not matter.
            //
            // RESTORED VERBATIM FROM 399 (owner's A/B verdict, builds 408-411): the UIKit backgroundTap
            // replacement made the keyboard feel wrong even with its instant-close gate. This is the
            // version whose feel he calls good; do not swap it out again without a device A/B.
            .simultaneousGesture(
                TapGesture().onEnded {
                    pendingKeyboardDismiss = true
                    DispatchQueue.main.async {
                        guard pendingKeyboardDismiss else { return }
                        pendingKeyboardDismiss = false
                        inputFocused = false
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                                        to: nil, from: nil, for: nil)
                    }
                }
            )
            // Scrolled back down to the newest message → the missed messages are now seen: clear the
            // away-counter and send the (throttled) read receipt.
            .onChange(of: isAtBottom) { _, atBottom in
                if atBottom {
                    newWhileAway = 0
                    if !repo.iBlocked {
                        ChatService.markReadThrottled(cid)
                        // Mirror the arrival path: zero the stored counter the moment these are seen,
                        // so the badge is right even if the app dies before onDisappear.
                        Task { await ChatService.resetUnread(cid) }
                    }
                }
            }
            // WHO IS ASKING, at the top, before you decide (owner 2026-08-04, with his reference).
            //
            // `safeAreaInset`, NOT an overlay, and the note twenty lines up on `topPinArea` is why:
            // an overlay padded down by a reported nav-bar height "repeatedly came back wrong". It
            // came back wrong here too — the owner photographed this card's 88pt avatar sitting on
            // top of the header's own avatar and the name printed twice. An inset is measured by the
            // system against the real bar, so it cannot land anywhere but under it.
            //
            // It also means the conversation is pushed down by the card rather than running beneath
            // it, which is what the reference app gets for free by making its version a real row.
            .safeAreaInset(edge: .top) {
                if requestStance == .incoming { requestIntroCard }
            }
    }

    /// The card above a stranger's first message: who they are, and that the conversation is private.
    /// Their name and picture are the whole decision — you are about to let someone in or not, and
    /// the old screen asked you to make that call from a name in the navigation bar.
    private var requestIntroCard: some View {
        Button {
            inputFocused = false
            showContactInfo = true
        } label: {
            VStack(spacing: 8) {
                // A STRANGER'S PHOTO IS BLURRED UNTIL YOU LET THEM IN. The reference app does this
                // (the reference implementation) and the reason is worth writing down:
                // without it, anybody who can reach you can put a picture in front of you that you
                // never asked to see, just by setting it as their profile photo. Tapping opens the
                // profile, where it is shown properly, so nothing is hidden — it just is not pushed
                // at you before you have agreed to the conversation.
                AvatarView(name: title, photoUrl: photoUrl, size: 88)
                    .blur(radius: 14)
                    .clipShape(Circle())
                    .overlay {
                        Image(systemName: "eye.slash.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(.white.opacity(0.9))
                            .shadow(radius: 3)
                    }
                HStack(spacing: 4) {
                    Text(title)
                        .font(.system(size: 20, weight: .semibold))
                        .lineLimit(1)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                // WHO THEY ARE, not a reassurance. This said "This conversation is private", which
                // tells you nothing about the person you are being asked to decide about. The reference app
                // fills this line with identifying detail and mutual groups; groups are switched off
                // here, so our equivalent is the username somebody would actually recognise.
                if !requestHandle.isEmpty {
                    Text("@\(requestHandle)")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 14)
            .padding(.bottom, 10)
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .task(id: cid) {
            guard requestStance == .incoming, requestHandle.isEmpty else { return }
            let other = conversation?.otherUid(me) ?? ""
            if let p = await ProfileStore.shared.fetch(other) { requestHandle = p.handle }
        }
    }

    // Per-row CONTENT signature (what a bubble actually renders): text, edited, send state, reactions,
    // read tick, pinned, album count. The native list reconfigures a visible row ONLY when its signature
    // changes — so the constant presence/typing/read re-renders of ThreadView's body don't reconfigure
    // (re-render) every visible bubble = no flashing.
    // Per-emission signature cache (the reference app's one-producer discipline): the BASE signatures are computed
    // once per repo emission / read-cutoff / pin change and reused across every SwiftUI body re-run —
    // the old computed property re-hashed every message's text on EVERY body run (typing flags, presence
    // dots, keyboard focus…), pure churn during exactly the moments that need main-thread headroom.
    // A plain class box: not observed state, mutating it never re-runs the body.
    private final class SignatureCache {
        var key = ""
        var base: [String: String] = [:]
        // The DECORATED set (selection + highlight suffixes) memoised on its own key. Without this, the
        // slow path below rebuilt a full copy of the dictionary — one string concatenation per loaded
        // message — on EVERY body run for as long as selection mode was open or a jump flash was up.
        // The body re-runs on typing flags, presence, read receipts and keyboard focus, so in a long
        // conversation that was thousands of pointless string builds a second during exactly the two
        // interactions that need the main thread most: dragging through selection, and the moment after
        // a jump lands.
        var decoratedKey = ""
        var decorated: [String: String] = [:]
    }
    @State private var sigCache = SignatureCache()

    private var rowSignatures: [String: String] {
        let readCutoff = repo.otherLastReadMillis
        let pins = repo.pinnedMessageIds
        // Audit M3: the active search term must be a signature input — visible rows never repainted
        // their in-text match highlight as the query changed (only the jumped-to row, via highlightId).
        let term = searchActive ? searchQuery.trimmingCharacters(in: .whitespaces) : ""
        // Audit M2: viewedOnceTick keys the cache so consuming a view-once photo repaints its bubble.
        // Chat colour: a live colour change flips a row's route (UIKit default-colour cell ⇄
        // colour-capable SwiftUI cell). It changes no message content, so without it in the
        // signature the route-flip reload never fires and the colour didn't apply until you
        // left and re-opened the chat (user report). Putting it in every row's signature makes
        // the existing contentChanged→splitByRouteFlip→reloadItems path swap the cells live.
        let colorTok = chatColorSpec?.stored ?? "-"
        // EVERY value rowView reads eagerly must be in this key, or hosted cells keep stale content
        // (the class of bug that produced the frozen bubble corners). Added:
        //   dark          - SwiftUI bubbles baked the palette in, so flipping Dark Mode left received
        //                   bubbles light-grey while UIKit text cells adapted instantly = mixed palette.
        //   firstUnreadId - the unread divider changes a row's content AND its height by ~33pt.
        //   iBlocked      - read state is forced to 0 when blocked; the uikit model cache already keyed
        //                   on this, the SwiftUI side did not, so ticks disagreed between row types.
        // storiesVersion: a quoted story dying (deleted or expired) changes a story-reply row's
        // CONTENT AND HEIGHT (140pt card → one line of text), and height only updates through the
        // signature path. Reading it here also makes the body observe story changes at all.
        let storiesRepo = StoriesRepository.shared
        let key = "\(repo.itemsVersion)|\(readCutoff)|\(pins.joined(separator: ","))|\(viewedOnceTick)|\(term)|\(colorTok)|\(dark)|\(firstUnreadId ?? "-")|\(repo.iBlocked)|\(storiesRepo.storiesVersion)"
        if sigCache.key != key {
            var out: [String: String] = [:]
            out.reserveCapacity(repo.items.count)
            for (i, m) in repo.items.enumerated() {
                // CLUSTER GEOMETRY BELONGS IN THE SIGNATURE. The corner radii and top gap are read
                // EAGERLY when a row view is built (rowView passes isFirstInCluster/isLastInCluster and
                // applies topGap) and then frozen into the cell's UIHostingConfiguration. A hosted cell
                // is only rebuilt when its signature changes — so when a new message arrived, the row
                // ABOVE it kept the geometry it had when it was still the last row: full 18pt corners,
                // ungrouped. Confirmed plain text hid the bug because it routes to a UIKit cell, and
                // repaintUikitCells pushes fresh radii onto those on every update; SwiftUI-hosted rows
                // (every PENDING message, plus media/reply/reaction rows) have no such self-heal, which
                // is exactly why the user saw it only on 0-mark bubbles.
                let cluster = "\(isFirstInCluster(at: i))\(isLastInCluster(at: i))"
                let reactions = m.reactions.isEmpty ? "" : m.reactions.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ",")
                let read = readCutoff >= m.createdAt.timeIntervalSince1970 * 1000
                // View-once consumption (audit M2) — the bubble flips to "Viewed" only via reconfigure.
                let once = m.viewOnce ? String(ViewedOnce.contains(m.id)) : "-"
                // Search match (audit M3) — matching rows re-render their term highlight per keystroke.
                let match = term.isEmpty ? "-" : (m.text.localizedCaseInsensitiveContains(term) ? "M\(term.hashValue)" : "-")
                // Story-reply rows: the card ⇄ "Story unavailable" flip must reconfigure AND
                // re-measure the row (same availability rule as storyReplyExpired).
                let story: String = {
                    guard let r = m.replyTo, r.isStatus else { return "-" }
                    return storiesRepo.didLoad && !storiesRepo.hasLive(storyId: r.id, author: r.authorId) ? "G" : "L"
                }()
                // DELETED must be here for the same reason it must be in ThreadRepository.changeSig:
                // a tombstone on uncaptioned media changes NO other field this string reads (text ""
                // before and after, no reactions, no album), so the row never reconfigured and the
                // photo stayed on screen until a neighbour change repainted it — which read as the
                // delete landing on the PREVIOUS message instead of the one just picked.
                //
                // AND THE UNREAD DIVIDER, for the third instance of that exact mistake. `firstUnreadId`
                // was in the cache KEY above, so changing it rebuilt this whole dictionary — but every
                // row computed the SAME string it had before, because nothing else about the message
                // changed. The list reconfigures a row only when its signature differs, so the row that
                // gained a 33pt "Unread Messages" header was never re-measured and the rows after it
                // were laid out over the top of it. That is the overlapping the owner photographed:
                // bubbles and images stacked on each other around the divider.
                //
                // Being in the key is not the same as being in the value. The key decides WHETHER to
                // recompute; only the value can say WHICH row changed.
                let unread = m.id == firstUnreadId ? "U1" : "U0"
                // Live call rows mutate in place (ringing → ongoing → final, duration, voice→video
                // upgrade) and change no other field this string reads — same rule as `deleted`.
                let call = m.isCall ? "\(m.callOutcome ?? "-"):\(m.callDuration ?? -1):\(m.callVideo)" : "-"
                out[m.rowId] = "\(m.text.hashValue)|\(m.edited)|\(m.deleted)|\(String(describing: m.sendState))|\(read)|\(pins.contains(m.id))|\(reactions)|\(m.album.count)|\(once)|\(match)|\(colorTok)|\(cluster)|\(story)|\(unread)|\(call)"
            }
            sigCache.key = key
            sigCache.base = out
        }
        // Fast path (the overwhelmingly common state): no selection, no highlight → the cached base IS
        // the signature set. The suffixes below exist because:
        //  • SELECTION must be in the signature: the row renders a checkbox (and dims) in select mode —
        //    without it the visible rows never reconfigured and checkboxes were missing (308 bug).
        //  • HIGHLIGHT must be in the signature: the jump-to flash renders via isHighlighted — without a
        //    signature change the target row never reconfigured (the "jump didn't work" bug).
        if !selecting && highlightId == nil { return sigCache.base }
        // Only the SELECTED ids and the highlighted id can change a decorated value, so they are the whole
        // key. `selectedIds` is hashed rather than joined: Set's hashValue is order-independent and does
        // not allocate, and this runs on the body path.
        let decoratedKey = "\(key)|\(selecting)|\(selectedIds.count)|\(selectedIds.hashValue)|\(highlightId ?? "-")"
        if sigCache.decoratedKey == decoratedKey { return sigCache.decorated }
        var out = sigCache.base
        for m in repo.items {
            let sel = selecting ? (selectedIds.contains(m.id) ? "S1" : "S0") : "S-"
            let hl = m.id == highlightId ? "H1" : "H0"
            out[m.rowId] = (out[m.rowId] ?? "") + "|\(sel)|\(hl)"
        }
        sigCache.decoratedKey = decoratedKey
        sigCache.decorated = out
        return out
    }

    // UIKit bubble migration (stage 1): resolve a NATIVE model for a message the UIKit path fully supports —
    // plain 1:1 delivered text, default bubble color, no adornments. Any special case returns nil and the
    // message keeps its SwiftUI cell, so no feature is lost while the surface is progressively migrated.
    // ROUND 2 (2026-07-14, after the 325 field failure): ON again, with the failure covered by
    // construction. In 325, read ticks on uikit rows did not refresh on device even though the
    // diffable reconfigure chain reads correct — so uikit cells no longer DEPEND on that chain for
    // repaints: every SwiftUI update also pushes geometry-neutral model changes (ticks/time) straight
    // onto the visible cells (repaintUikitCells → repaintIfMetaChanged, soft cross-dissolve matching
    // the SwiftUI tick fade). Height-changing updates still ride the measured reconfigure/reload path.
    private static let useUIKitBubbles = true

    // Per-emission cache of the UIKit-routable models (same discipline as the signature cache): resolved
    // once per data/read/highlight change, NOT on every body run.
    private final class UikitModelCache {
        var key = ""
        var models: [String: UIKitBubbleModel] = [:]
        // Bumped only when the models are actually rebuilt. The list uses it to skip its direct repaint
        // pass entirely when nothing can have changed — see `uikitModelsVersion` at the call site.
        var version = 0
    }
    @State private var uikitModelCache = UikitModelCache()

    private var uikitModels: [String: UIKitBubbleModel] {
        // Search highlights text inside SwiftUI bubbles; selection/custom-color/group cases render
        // SwiftUI-only — in those states everything routes SwiftUI (empty dict).
        guard Self.useUIKitBubbles, !isGroup, !selecting, chatColorSpec == nil, !searchActive else { return [:] }
        // Audit M5: iBlocked and the read-receipts pref feed the tick, so they must key the cache —
        // toggling the pref (or a block-state change) left uikit rows showing stale ticks.
        let key = "\(repo.itemsVersion)|\(repo.otherLastReadMillis)|\(highlightId ?? "-")|\(repo.iBlocked)|\(readReceiptsOn)"
        if uikitModelCache.key == key { return uikitModelCache.models }
        var out: [String: UIKitBubbleModel] = [:]
        for m in repo.items {
            if let model = uikitBubbleModel(for: m.rowId) { out[m.rowId] = model }
        }
        uikitModelCache.key = key
        uikitModelCache.models = out
        uikitModelCache.version &+= 1
        return out
    }

    // Long-press menu for UIKit-routed rows — the SAME native menu (same items, same order, same
    // conditions) the SwiftUI .contextMenu builds, restricted to what a plain 1:1 delivered text
    // message can do (no Save Image / Info — those never apply to this row class).
    private func uikitMenu(for rowId: String) -> UIMenu? {
        guard let idx = repo.indexById[rowId], idx < repo.items.count else { return nil }
        let m = repo.items[idx]
        var items: [UIMenuElement] = []
        items.append(UIAction(title: "Reply", image: UIImage(systemName: "arrowshape.turn.up.left")) { _ in
            beginReply(to: m)
        })
        items.append(UIAction(title: "React…", image: UIImage(systemName: "face.smiling")) { _ in
            morePickerTarget = m
        })
        if m.authorId == me, Date().timeIntervalSince(m.createdAt) < Limits.editWindowSeconds {
            items.append(UIAction(title: "Edit", image: UIImage(systemName: "pencil")) { _ in
                withAnimation(.easeInOut(duration: 0.2)) { editingMessage = m; replyingTo = nil }
                input = m.text
                inputFocused = true
            })
        }
        let isPinned = repo.pinnedMessageIds.contains(m.id)
        items.append(UIAction(title: isPinned ? "Unpin" : "Pin",
                              image: isPinned ? UIImage(systemName: "pin.slash")
                                             : UIImage(named: "ic_pin_menu")?.withRenderingMode(.alwaysTemplate)) { _ in
            togglePin(m)
        })
        items.append(UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { _ in
            UIPasteboard.general.string = m.text
        })
        // Same `canForward` as the other two paths. Today every row that reaches this menu already
        // passes it (uikitBubbleModel filters out undelivered, view-once, calls, and tombstones via
        // their empty text), so this changes nothing — it just stops the next guard added to
        // canForward from missing this copy, which is how the view-once hole opened in the first place.
        if canForward(m) {
            items.append(UIAction(title: "Forward", image: UIImage(systemName: "arrowshape.turn.up.right")) { _ in
                forwardTarget = m
            })
        }
        items.append(UIAction(title: "Select", image: UIImage(systemName: "checkmark.circle")) { _ in
            withAnimation(.easeInOut(duration: 0.2)) { selecting = true; selectedIds = [m.id] }
        })
        // NO "Report" on a message. The whole point of end-to-end encryption is that we cannot read what
        // was sent, so a message report would either carry nothing useful or force us to ship the plaintext
        // off the device - which would quietly break the guarantee the app makes. Reporting a PERSON or a
        // GROUP still exists (ContactInfoView / GroupInfoView); it just does not attach message contents.
        // Both sides get Delete instead, and the dialog offers "Delete for Me" for someone else's message.
        let destructive = UIAction(title: "Delete", image: UIImage(systemName: "trash"),
                                   attributes: .destructive) { _ in pendingDelete = m }
        items.append(UIMenu(options: .displayInline, children: [destructive]))   // the divider + Delete
        return UIMenu(children: items)
    }

    // CUSTOM LONG-PRESS MENU (experiment — CMContextMenu.swift): ONE builder for EVERY message type.
    // Items and conditions carried over verbatim from the SwiftUI .contextMenu this replaces. There is
    // deliberately NO "React…" row — the floating bar above the message IS reacting, and it appears
    // for exactly the rows customReactInfo allows; its "…" opens the same full picker.
    private func customMenuActions(for rowId: String) -> [CMAction] {
        guard let idx = repo.indexById[rowId], idx < repo.items.count else { return [] }
        let m = repo.items[idx]
        let mine = m.authorId == me
        let canPin = !isGroup || (conversation?.adminCan(me, .pinMessages) ?? false)
        let isPinned = repo.pinnedMessageIds.contains(m.id)
        var out: [CMAction] = []

        // A TOMBSTONE has no content, so nothing that acts on content applies: no react, reply,
        // forward, copy, edit, pin or save. Offering them would produce empty copies and quotes of a
        // message that no longer exists. Clearing it from your own side is the only thing left.
        if m.deleted {
            // The SAME Delete action as any other message, but its dialog offers ONLY Delete for Me
            // (owner order): the message is already deleted for everyone, so the one thing left is
            // clearing the marker from your own side. The dialog enforces this — its Delete for
            // Everyone button is gated on !deleted.
            out.append(CMAction(title: "Delete", icon: "trash", destructive: true) { pendingDelete = m })
            out.append(CMAction(title: "Select", icon: "checkmark.circle") {
                selecting = true; selectedIds = [m.id]
            })
            return out
        }

        // MEDIA STILL UPLOADING: not on the server yet — only Save / Cancel Sending / Select.
        if m.sendState == .sending && (m.isImage || m.isVideo || m.isAlbum || m.isGif) {
            if m.isImage || m.isAlbum {
                out.append(CMAction(title: "Save Image", icon: "square.and.arrow.down") {
                    Task { await saveImageToPhotos(m) }
                })
            }
            out.append(CMAction(title: "Cancel Sending", icon: "xmark.circle", destructive: true) {
                // Cancel the UPLOAD too, not just the bubble — see onCancelSending / MediaSend.
                if let clientId = m.clientId {
                    MediaSend.shared.cancel(clientId)
                    repo.removePending(clientId: clientId)
                }
            })
            out.append(CMAction(title: "Select", icon: "checkmark.circle") {
                withAnimation(.easeInOut(duration: 0.2)) { selecting = true; selectedIds = [m.id] }
            })
            return out
        }

        // A CALL RECORD IS NOT A MESSAGE, and the general path below only ever gave it a menu by
        // accident: Forward, Copy, Edit, Save and Pin each fail their own test, so what survived was
        // Reply/Select/Delete and no mention of the one thing you actually want from a call row.
        // Owner 2026-08-13, "it's a gap we missing". Call back takes Forward's place in the order.
        if m.isCall {
            // The same liveness test the row itself uses (see callRow): a call still happening
            // offers no call-back, and a writer that died mid-call ages out of "live" on its own.
            let age = Date().timeIntervalSince(m.createdAt)
            let live = (m.callOutcome == "ringing" && age < 120)
                || (m.callOutcome == "ongoing" && age < 4 * 3600)
            out.append(CMAction(title: "Reply", icon: "arrowshape.turn.up.left") { beginReply(to: m) })
            if !live {
                out.append(CMAction(title: m.callVideo ? "Video Call" : "Voice Call",
                                    icon: m.callVideo ? "video" : "phone") {
                    // Through the same confirm the row's tap uses — a menu must not dial either.
                    pendingCallBack = m.callVideo ? .video : .voice
                })
            }
            out.append(CMAction(title: "Select", icon: "checkmark.circle") {
                withAnimation(.easeInOut(duration: 0.2)) { selecting = true; selectedIds = [m.id] }
            })
            out.append(CMAction(title: "Delete", icon: "trash", destructive: true) { pendingDelete = m })
            return out
        }

        // THE REFERENCE APP'S ORDER (owner's circled reference): Reply · Forward · Copy · Select · Info · Pin,
        // Delete last. Our extra items slot in where they belong: Edit and Save Image after Copy.
        // NOT-YET-DELIVERED messages carry a local clientId, not a server doc id, so anything that
        // stores a reference to them breaks permanently (audit): Pin wrote a phantom pin that never
        // resolves, and Reply sealed a quote pointing at an id the other device has never seen.
        // Edit and Info already had this guard; Reply, Forward and Pin now share it.
        let delivered = m.sendState == nil
        if delivered {
            out.append(CMAction(title: "Reply", icon: "arrowshape.turn.up.left") { beginReply(to: m) })
        }
        // Both forward paths now ask `canForward` and nothing else — see the note on it. This one
        // used to spell the rule out inline, which is how the two copies drifted apart.
        if canForward(m) {
            out.append(CMAction(title: "Forward", icon: "arrowshape.turn.up.right") { forwardTarget = m })
        }
        if !m.text.isEmpty && !m.isFeatureMarker && !m.viewOnce {
            out.append(CMAction(title: "Copy", icon: "doc.on.doc") { UIPasteboard.general.string = m.text })
        }
        // Edit follows the TEXT, not the type: a photo/album/video caption is sealed in the same
        // `text` field editMessage rewrites, so any of my messages WITH a body is editable within
        // the window. Bare media has no text to edit; view-once never re-opens for editing.
        if mine && !iAmMuted && !m.isAudio && !m.isCall
            && !m.isFeatureMarker && !m.viewOnce
            && !m.text.isEmpty
            && m.sendState == nil
            && Date().timeIntervalSince(m.createdAt) < Limits.editWindowSeconds {
            out.append(CMAction(title: "Edit", icon: "pencil") {
                withAnimation(.easeInOut(duration: 0.2)) { editingMessage = m; replyingTo = nil }
                input = m.text
                inputFocused = true
            })
        }
        if m.isImage && !m.viewOnce {
            out.append(CMAction(title: "Save Image", icon: "square.and.arrow.down") {
                Task { await saveImageToPhotos(m) }
            })
        }
        out.append(CMAction(title: "Select", icon: "checkmark.circle") {
            withAnimation(.easeInOut(duration: 0.2)) { selecting = true; selectedIds = [m.id] }
        })
        if isGroup && mine && m.sendState == nil {
            out.append(CMAction(title: "Info", icon: "info.circle") { infoTarget = m })
        }
        if canPin && delivered {   // see `delivered` above — a pin on a clientId can never resolve
            out.append(CMAction(title: isPinned ? "Unpin" : "Pin", icon: isPinned ? "pin.slash" : "ic_pin_menu") {
                togglePin(m)
            })
        }
        out.append(CMAction(title: "Delete", icon: "trash", destructive: true) { pendingDelete = m })
        return out
    }

    // The bar shows exactly when this row can be reacted to: on the server, and I am not muted.
    private func customReactInfo(for rowId: String) -> (emojis: [String], selected: String?)? {
        guard let idx = repo.indexById[rowId], idx < repo.items.count else { return nil }
        let m = repo.items[idx]
        // No bar on call/system rows (audit): they render no reaction badges, so a picked emoji
        // wrote server-side and was visible to NOBODY on either device.
        //
        // `isFeatureMarker` used to stand here and was far too wide. It is true for ANY message
        // whose text starts `kulan-<name>:`, which is how a shared location, a contact card and a
        // poll all travel — and those three draw ordinary bubbles and carry reaction badges exactly
        // like a text message. So long-pressing a location came up with no bar at all (owner's
        // report), and contacts and polls had the same fault waiting.
        //
        // What is excluded instead is the markers with nothing to react TO: the "pinned a message"
        // notice, which is a system line wearing a text message's clothes, and a message from a
        // newer build that this one can only draw as a placeholder.
        // No bar on a tombstone either: the deleted placeholder renders no badges (reactionCounts
        // is empty for it by construction), so a picked emoji would write server-side and show to
        // nobody — the same invisible-reaction trap the call/system exclusion above closed.
        guard m.sendState == nil, !iAmMuted, !m.isCall, !m.isSystem, !m.deleted,
              m.pinNotice == nil, !m.isUnsupportedFeature else { return nil }
        return (Array(QuickReaction.choices.prefix(6)), m.reactions[me])
    }

    private func handleCustomReact(_ rowId: String, _ selection: CMReactionSelection) {
        guard let idx = repo.indexById[rowId], idx < repo.items.count else { return }
        let m = repo.items[idx]
        switch selection {
        case .more:
            morePickerTarget = m
        case .emoji(let e):
            Task {
                await ChatService.setReaction(cid: cid, messageId: m.id, emoji: e,
                                              toAuthor: m.authorId, group: isGroup ? groupMembers : nil)
            }
        }
    }

    // Double-tap quick heart on a UIKit-routed row — mirrors the SwiftUI bubble's double-tap gesture.
    private func uikitQuickReact(_ rowId: String) {
        guard let idx = repo.indexById[rowId], idx < repo.items.count else { return }
        let m = repo.items[idx]
        guard m.sendState == nil else { return }
        // The user's chosen quick reaction, not a hard-coded heart (Settings > Appearance).
        let quick = QuickReaction.current
        let emoji: String? = m.reactions[me] == quick ? nil : quick
        Task {
            await ChatService.setReaction(cid: cid, messageId: m.id, emoji: emoji,
                                          toAuthor: m.authorId, group: isGroup ? groupMembers : nil)
        }
    }

    private func uikitBubbleModel(for rowId: String) -> UIKitBubbleModel? {
        guard Self.useUIKitBubbles else { return nil }
        guard !isGroup, !selecting, chatColorSpec == nil,
              let idx = repo.indexById[rowId], idx < repo.items.count else { return nil }
        guard !shouldShowDate(at: idx) else { return nil }             // date-header rows render the pill in SwiftUI
        // The "Unread Messages" divider is drawn by rowView in SwiftUI. A plain delivered 1:1 text took
        // the UIKit path, which draws a bubble and nothing else and measures itself the same way, so in
        // the commonest case the divider was missing from BOTH render and measurement.
        guard rowId != firstUnreadId else { return nil }
        let m = repo.items[idx]
        guard m.id != highlightId, m.sendState == nil,                 // delivered only
              m.replyTo == nil, m.reactions.isEmpty,
              !m.isFeatureMarker, !m.viewOnce, !m.forwarded,           // Forwarded tag is SwiftUI-only
              !m.isImage, !m.isVideo, !m.isGif, !m.isFile, !m.isAudio, !m.isAlbum, !m.isCall,
              m.mentions.isEmpty else { return nil }
        let text = m.safeText
        guard !text.isEmpty else { return nil }
        // Jumbomoji rows render borderless at up to 3.5x the body size — a shape the UIKit bubble path
        // does not draw and does not measure. They stay in SwiftUI.
        guard text.jumbomojiCount == 0 else { return nil }
        // Links (OG preview card + tappable ranges) stay in SwiftUI for now; '@' may be a username/mention.
        let lower = text.lowercased()
        guard !lower.contains("http"), !lower.contains("www."), !text.contains("@") else { return nil }

        let isMe = m.authorId == me
        let first = isFirstInCluster(at: idx)
        let last = isLastInCluster(at: idx)
        let big: CGFloat = 18, small: CGFloat = 6
        let radii: UIKitBubbleModel.Radii = isMe
            ? .init(topLeading: big, topTrailing: first ? big : small, bottomLeading: big, bottomTrailing: last ? big : small)
            : .init(topLeading: first ? big : small, topTrailing: big, bottomLeading: last ? big : small, bottomTrailing: big)
        let tick: UIKitBubbleModel.Tick
        if isMe {
            // Parity with the SwiftUI path (audit M5): a blocked contact's lastRead is ignored there
            // (otherLastRead passed as 0 when iBlocked) — the uikit tick must match, or a blocked chat
            // shows ✓✓ on text rows and ✓ on media rows, and a route flip visibly demotes the tick.
            let read = !repo.iBlocked && repo.otherLastReadMillis >= m.createdAt.timeIntervalSince1970 * 1000
            tick = read ? .read : .sent   // same rule as the SwiftUI bubble and the chat list
        } else { tick = .none }

        return UIKitBubbleModel(
            isMe: isMe, text: text, edited: m.edited,
            timeText: m.createdAt.formatted(date: .omitted, time: .shortened),
            tick: tick, radii: radii, topSpacing: first ? 14 : 2)
    }

    // UIKit message list. Reuses the SAME rowView, so every bubble feature is identical.
    // Jumps (reply/search) route through nativeScrollTarget; read receipts + jump-button count come from
    // the shared onChange(of: repo.items.count) handler on the container.
    private var nativeList: some View {
        NativeMessageList(
            rowIds: repo.items.map { $0.rowId },
            rowSignatures: rowSignatures,   // per-row content signature → list reconfigures only changed rows
            row: { id in
                guard let idx = repo.indexById[id], idx < repo.items.count else { return AnyView(EmptyView()) }
                return AnyView(rowView(at: idx, repo.items[idx], jumpTo: { jid in
                    // This tap was FOR the quote — keep the keyboard (the reference app keeps it too). Cancels
                    // the list's deferred tap-to-dismiss before it can run.
                    pendingKeyboardDismiss = false
                    Task {
                        await repo.ensureLoaded(jid)
                        await MainActor.run {
                            // Reply-to-deleted (tombstone): if the original is gone, say so
                            // instead of silently doing nothing. The quote itself still shows its saved
                            // snapshot, so the reply is never blank.
                            if repo.items.contains(where: { $0.id == jid }) { flashAndScroll(jid) }
                            else { showJumpToast("Original message was deleted") }
                        }
                    }
                }).padding(.horizontal, 12))
            },
            // UIKit bubble migration: plain 1:1 delivered text renders as a native UIKit cell. The models
            // are a frozen per-emission snapshot (routing can never flip between measure and render).
            uikitModels: uikitModels,
            // MUST stay directly after `uikitModels:` — argument expressions evaluate in source order, and
            // reading `uikitModels` above is what refreshes the cache this version comes from.
            uikitModelsVersion: uikitModelCache.version,
            uikitMenu: { id in uikitMenu(for: id) },
            onUikitDoubleTap: { id in uikitQuickReact(id) },
            // CUSTOM LONG-PRESS MENU (experiment): every row's actions, the bar's config, and the
            // keyboard policy — close on open, restore on close, the reference app's keyboardWasActive model.
            customMenuActions: { id in customMenuActions(for: id) },
            customReactConfig: { id in customReactInfo(for: id) },
            onCustomReact: { id, selection in handleCustomReact(id, selection) },
            onMenuCloseKeyboard: {
                let wasUp = inputFocused
                if wasUp {
                    inputFocused = false
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                                    to: nil, from: nil, for: nil)
                }
                return wasUp
            },
            onMenuRestoreKeyboard: { inputFocused = true },
            // STEP 6 REMOVED (owner's verdict, builds 408-411): the UIKit backgroundTap system made
            // the keyboard open/close feel wrong even with the instant-close gate, so tap-to-dismiss
            // is the 399 SwiftUI deferred gesture again — see listBody.
            onReachedTop: { repo.loadOlder() },
            selecting: selecting,   // selection-animation land gate (the checkbox slide isn't clobbered)
            // The reference behavior (user-approved 2026-07-13, replacing open-at-bottom): with unread
            // messages, the FIRST open lands at the first unread — the same row anchorUnread marks with
            // the divider. Computed synchronously (unreadOnOpen seeds from the cached conversation) so
            // it's ready when the list performs its first open; consumed exactly once.
            initialScrollId: {
                // Arrived by tapping the floating voice bar: open ON the note that is playing rather
                // than at the bottom, so there is no jump to watch. Only when it is already loaded,
                // which is the usual case since you were just in this chat. Anything further back is
                // paged in and scrolled to by the `.task` below instead. Read, not consumed — the task
                // is the one place that clears it.
                if let target = AppRouter.shared.pendingMessageId,
                   let row = repo.items.first(where: { $0.id == target })?.rowId {
                    return row
                }
                guard unreadOnOpen > 0 else { return nil }
                let msgs = repo.messages
                // Same rule as anchorUnread: with more unread than we hold, don't pretend the oldest
                // loaded row is the boundary (audit).
                guard unreadOnOpen <= msgs.count else { return nil }
                let idx = msgs.count - unreadOnOpen
                guard idx < msgs.count else { return nil }
                return repo.items.first { $0.id == msgs[idx].id }?.rowId
            }(),
            canSwipeReply: { id in
                repo.indexById[id].map { repo.items[$0].sendState == nil } ?? false
            },
            onSwipeReply: { id in
                if let idx = repo.indexById[id], idx < repo.items.count { beginReply(to: repo.items[idx]) }
            },
            loadingOlder: repo.loadingOlder,
            composerBarHeight: composerBarHeight,   // extra bottom clearance so the newest msg clears the bar
            menuActionTick: menuActionTick,         // SwiftUI menu action fired → hold reloads through its dismissal
            topOverlayHeight: searchActive ? 0 : pinBarHeight,   // floating date pill drops below the pin bar
            isAtBottom: $isAtBottom,
            scrollTarget: $nativeScrollTarget,
            // The floating date pill is now rendered + updated in UIKit (NativeMessageList) directly from
            // the scroll callback. We only hand it a pure rowId → day-label mapping; no SwiftUI state is
            // written on scroll, so scrolling never re-runs the conversation tree.
            dayLabelFor: { id in repo.indexById[id].map { dayLabel(repo.items[$0].createdAt) } }
        )
    }

    // Native-list jump: flash the message (highlightId) and scroll the collection view to it.
    @State private var jumpToast: String?
    private func showJumpToast(_ msg: String) {
        withAnimation(.easeOut(duration: 0.2)) { jumpToast = msg }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            withAnimation(.easeIn(duration: 0.25)) { if jumpToast == msg { jumpToast = nil } }
        }
    }

    // Pin/unpin + the reference-style in-chat notice. E2EE-SAFE: the snippet rides the ENCRYPTED text
    // pipeline as a feature marker (a plaintext system message would leak content to the server).
    // Older builds render the unknown marker as the graceful "newer version" notice.
    private func togglePin(_ m: Message) {
        if repo.pinnedMessageIds.contains(m.id) {
            Task { await ChatService.removePinnedMessage(cid, m.id) }   // the reference app posts no unpin notice
        } else if repo.pinnedMessageIds.count < Limits.pinnedMessagesPerChat {
            Task {
                await ChatService.addPinnedMessage(cid, m.id)
                try? await ChatService.sendText(
                    cid: cid,
                    text: Message.pinMarkerText(messageId: m.id, label: Self.pinLabel(m)),
                    group: isGroup ? groupMembers : nil)
            }
        }   // already at the pin max → ignore
    }

    // The notice's label, composed by the PINNER (who has the plaintext): a short quoted snippet for
    // text, a friendly noun for media — mirrors the reference app exactly.
    static func pinLabel(_ m: Message) -> String {
        if m.isImage || m.isAlbum { return "a photo" }
        if m.isVideo { return "a video" }
        if m.isAudio { return "a voice message" }
        if m.isFile { return "a file" }
        if m.isGif { return "a GIF" }
        let t = m.safeText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return "a message" }
        return t.count > 20 ? "\"\(t.prefix(20))…\"" : "\"\(t)\""
    }

    private func flashAndScroll(_ id: String) {
        nativeScrollTarget = repo.items.first { $0.id == id }?.rowId ?? id   // native list keys by rowId (clientId ?? id)
        highlightId = id
        // the reference app's found-result emphasis: the mark BRIEFLY draws the eye, then fades quickly and smoothly
        // (the bubble's own 0.4s ease drives the fade). The old 2.2s hold felt sluggish across every
        // jump-to flow (pinned / media "go to chat" / search); ~0.6s hold + 0.4s fade ≈ the reference app's timing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            if highlightId == id { withAnimation { highlightId = nil } }
        }
    }

    // MARK: - Message selection

    private func toggleSelect(_ id: String) {
        if selectedIds.contains(id) { selectedIds.remove(id) } else { selectedIds.insert(id) }
    }

    private func exitSelection() {
        withAnimation(.easeInOut(duration: 0.2)) { selecting = false; selectedIds = [] }
    }

    // Begin a reply (from the context menu OR the swipe-to-reply pan). Cancels any in-progress edit — they
    // can't both be active, or send would commit the edit and silently drop the reply.
    private func beginReply(to m: Message) {
        if editingMessage != nil { editingMessage = nil; setInputSilently(Drafts.shared.text(cid)) }
        withAnimation(.easeInOut(duration: 0.22)) { replyingTo = m }
        inputFocused = true   // replying = you're about to type → open the keyboard
    }

    // Does the current selection include any of MY messages (→ "Delete for Everyone" is offered)?
    // Tombstones don't count: they are already deleted for everyone (owner order), so a selection
    // of only placeholders offers Delete for Me alone, same as the single-message dialog.
    private var selectionHasMine: Bool {
        repo.items.contains { selectedIds.contains($0.id) && $0.authorId == me && !$0.deleted }
    }

    // everyone == true: my messages are removed for everyone, others hidden locally (mixed selection).
    // everyone == false: every selected message is hidden locally only (Delete for Me).
    private func bulkDelete(everyone: Bool) {
        let ids = selectedIds
        Task {
            var anyRefused = false
            for id in ids {
                guard let m = repo.items.first(where: { $0.id == id }) else { continue }
                if everyone && m.authorId == me, m.sendState == nil, !m.deleted {
                    // Tombstone locally FIRST, the same as the single-message path. These run one
                    // after another, so ten selected photos meant ten round trips with the list
                    // sitting still; now all ten flip at once and the server catches up behind them.
                    let undoable = await MainActor.run { repo.markDeletedLocally(id) }
                    // The single-message path was fixed to SAY when the server refuses; this one
                    // discarded the result, so a refused bulk delete left the messages in place with
                    // no alert and the selection already dismissed as if it had worked (audit).
                    if await !ChatService.deleteMessage(cid: cid, messageId: id) {
                        anyRefused = true
                        if undoable { await MainActor.run { repo.restoreAfterFailedDelete(id) } }
                    }
                } else {
                    await MainActor.run { deleteForMe(m) }   // also cancels unsent messages properly
                }
            }
            if anyRefused { await MainActor.run { showJumpToast("Some messages couldn't be deleted") } }
        }
        exitSelection()
    }

    /// THE one answer to "can this message be forwarded". Every forward path asks this and only this:
    /// the long-press menu, the selection bar's enabled state, and the bulk send itself.
    ///
    /// It is one function because it used to be three copies and they had already drifted. The
    /// long-press copy excluded view-once photos; the multi-select copy did not, so ticking a
    /// view-once photo in selection mode forwarded it to somebody else and the whole point of
    /// view-once was gone. The reference app keeps a single `isForwardable` on the selection item for exactly
    /// this reason (the reference implementation), and checks `wasRemotelyDeleted`,
    /// `isViewOnceMessage` and renderable content in that one place.
    ///
    /// - `sendState == nil`: still-sending messages have no id the other device has ever seen. Same
    ///   guard Reply, Edit, Pin and Info already share, for the reason written above the menu.
    private func canForward(_ m: Message) -> Bool {
        m.sendState == nil && !m.isCall && !m.isSystem && !m.deleted && !m.viewOnce
    }

    /// EVERY selected row must be forwardable, not merely one of them.
    ///
    /// It used to be `contains`, and that read the wrong way round: ticking a photo alongside a
    /// "You deleted this message" placeholder lit the arrow, then `bulkForwardStart` dropped the
    /// placeholder and sent one message where two were ticked. The count in the middle of the bar
    /// still said 2. Silently sending less than the person selected is worse than making them untick
    /// it, because they never find out. A tombstone stays SELECTABLE on purpose — the trash button is
    /// how you clear the placeholder off your own list — it just can't be part of a forward.
    ///
    /// The reference app's equivalent check is the same shape: empty is false, then one `guard
    /// item.isForwardable else { return false }` over every item.
    private var selectionIsForwardable: Bool {
        let picked = repo.items.filter { selectedIds.contains($0.id) }
        guard !picked.isEmpty else { return false }
        return picked.allSatisfy(canForward)
    }

    private func bulkForwardStart() {
        // Belt and braces: the button is already off unless every pick passes canForward.
        let msgs = repo.items.filter { selectedIds.contains($0.id) && canForward($0) }
            .sorted { $0.createdAt < $1.createdAt }
        guard !msgs.isEmpty else { return }
        bulkForward = msgs
    }

    // MARK: - In-chat search (top bar + step through matches)

    private func activateSearch() {
        withAnimation(.easeInOut(duration: 0.2)) { searchActive = true }
        searchQuery = ""; searchMatches = []; searchIndex = 0; lastSearchText = nil
        inputFocused = false
        Task {
            let corpus = await MessageSearch.loadChat(cid: cid, isGroup: isGroup, me: me)
            await MainActor.run { searchCorpus = corpus }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { searchFocused = true }
    }

    private func closeSearch() {
        searchFocused = false
        withAnimation(.easeInOut(duration: 0.2)) { searchActive = false }
        searchQuery = ""; searchMatches = []; highlightId = nil; lastSearchText = nil
        // Leave the conversation where the last result was — no scroll restore on close.
    }

    // Recompute matches as you type — our search semantics:
    //  • minimum 2 characters (shorter queries clear results)
    //  • identical-query dedup (arrow keys / focus changes don't re-run the search)
    //  • token-prefix AND matching, case/diacritic/width-insensitive ("hel wor" matches "Hello World")
    //  • corpus (history) + the LIVE window merged, so a just-sent or just-edited message is instantly
    //    searchable (the index updates on write; our corpus snapshot alone would be stale)
    //  • capped at the newest 500 matches (default max results)
    //  • the focused position is PRESERVED across query refinement (clamped), measured from the newest
    //    end — clamp the previous index rather than yanking you back to the first result
    private func updateSearchMatches() {
        let q = searchQuery.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else {
            searchMatches = []; lastSearchText = nil
            return
        }
        guard q != lastSearchText else { return }   // identical query → no re-run (dedup)
        lastSearchText = q
        let terms = ChatSearch.queryTerms(q)
        guard !terms.isEmpty else { searchMatches = []; return }

        // How far from the NEWEST match the user currently is (preserved across refinement).
        let distanceFromNewest = searchMatches.isEmpty ? 0 : max(0, (searchMatches.count - 1) - searchIndex)

        var seen = Set<String>()
        var pool: [InChatMessage] = []
        for m in searchCorpus where seen.insert(m.id).inserted { pool.append(m) }
        for m in repo.items where !m.text.isEmpty && !m.viewOnce && seen.insert(m.id).inserted {
            pool.append(InChatMessage(id: m.id, text: m.text, authorId: m.authorId,
                                      date: m.createdAt, tokens: ChatSearch.tokens(m.text)))
        }
        let matched = pool
            .filter { ChatSearch.matches(tokens: $0.tokens, terms: terms) }
            .sorted { $0.date < $1.date }
        searchMatches = Array(matched.suffix(500))   // keep the newest 500 (result cap)

        guard !searchMatches.isEmpty else { return }
        searchIndex = max(0, (searchMatches.count - 1) - min(distanceFromNewest, searchMatches.count - 1))
        goToCurrentMatch()
    }

    private func stepSearch(_ delta: Int) {
        guard !searchMatches.isEmpty else { return }
        searchIndex = min(max(0, searchIndex + delta), searchMatches.count - 1)
        goToCurrentMatch()
    }

    private func goToCurrentMatch() {
        guard searchMatches.indices.contains(searchIndex) else { return }
        let id = searchMatches[searchIndex].id
        // Coalesce rapid next/prev taps (lastOnly load queue): each tap supersedes the one
        // before, so N fast taps land ONE scroll on the final target instead of racing N ensureLoaded
        // pagers + N scroll animations.
        searchJumpSeq += 1
        let seq = searchJumpSeq
        Task {
            await repo.ensureLoaded(id)   // page older history in until the match is in the window
            await MainActor.run {
                guard seq == searchJumpSeq else { return }   // a newer jump superseded this one
                // THE REFERENCE APP'S RESULT NAVIGATION (user spec): jump to the match AND mark the found bubble —
                // the emphasis stays ~2s so the eye can land on which result was found, then fades
                // smoothly. flashAndScroll also translates id → rowId (the native list keys by rowId;
                // a deleted match resolves to no row and gracefully no-ops).
                flashAndScroll(id)
            }
        }
    }

    // Native toolbar header (real Liquid Glass + native back/swipe), same approach as the
    // Chats list. Avatar + name (+ presence) centered; voice + video as trailing glass items.
    // The native back button (leading) owns the real edge-swipe-back gesture.
    @ToolbarContentBuilder private var chatToolbar: some ToolbarContent {
        // Selection mode (reference design): "Delete All" (leading) · name (centre) · X (trailing).
        // Native toolbar buttons render as real Liquid Glass on iOS 26.
        if selecting {
            ToolbarItem(placement: .topBarLeading) {
                Button("Delete All") { showBulkDeleteConfirm = true }.tint(.red).disabled(selectedIds.isEmpty)
            }
            ToolbarItem(placement: .principal) {
                Text(title).font(.headline)
            }
            ToolbarItem(placement: .topBarTrailing) {
                // Sized and shaped like the call glyphs next door, not left as a bare SF Symbol: an
                // icon-only button's hit area is the GLYPH ITSELF, so the X was only tappable on the two
                // thin strokes (user report: "the x button touch area is so small"). The explicit frame
                // plus .contentShape makes the whole square live. Same lesson as the video-call minimise
                // chevron in build 381, which was dead for exactly this reason.
                Button { exitSelection() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .tint(.primary)
            }
        } else {
        // Avatar + name are the native UINavigationItem.titleView (see NavTitleView, installed in
        // threadCovers), left-aligned after the back button and sliding with the swipe-back — only the
        // call/video buttons live here in the toolbar.
        // 1:1 call buttons only — group calls need an SFU (not built yet). Show whenever we have a
        // resolved 1:1 partner (works for real cids AND demo chats like "demo-kasim" that have no
        // underscore; the old cid.contains("_") heuristic hid them in the preview).
        if !isGroup && !otherUid.isEmpty {
            ToolbarItem(placement: .topBarTrailing) {
                Button { CallService.shared.startCall(to: otherUid, name: title, photo: photoUrl) } label: {
                    callGlyph("ic_call_voice")
                }
                .tint(.primary)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { CallService.shared.startCall(to: otherUid, name: title, photo: photoUrl, video: true) } label: {
                    callGlyph("ic_call_video")
                }
                .tint(.primary)
            }
        } else if isGroup {
            ToolbarItem(placement: .topBarTrailing) {
                Button { startGroupCall(video: false) } label: { callGlyph("ic_call_voice") }.tint(.primary)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { startGroupCall(video: true) } label: { callGlyph("ic_call_video") }.tint(.primary)
            }
        }
        }   // end !selecting
    }

    // Custom call/video toolbar glyphs (template-tinted, sized to the toolbar).
    private func callGlyph(_ asset: String) -> some View {
        Image(asset).renderingMode(.template).resizable().scaledToFit().frame(width: 22, height: 22)
    }

    private func startGroupCall(video: Bool) {
        showGroupCall = true
        Task { await GroupCallService.shared.start(cid: cid, title: title, video: video) }
    }

    // Watch the group's call doc so a "Join call" bar appears when a call is active.
    private func startGroupCallListener() {
        groupCallListener?.remove()
        groupCallListener = Firestore.firestore().collection("groupCalls").document(cid)
            .addSnapshotListener { snap, _ in
                let d = snap?.data()
                var active = (d?["active"] as? Bool) ?? false
                // ZOMBIE GUARD: if the last participant crashed/force-quit, nobody wrote active=false
                // and the "Join call" bar would show FOREVER. Ignore call docs older than 4 hours.
                if active, let ts = d?["startedAt"] as? Timestamp,
                   Date().timeIntervalSince(ts.dateValue()) > 4 * 3600 {
                    active = false
                }
                groupCallActive = active
                groupCallVideo = (d?["video"] as? Bool) ?? false
            }
    }

    // Custom attach panel — slides up from the + button.
    // Top: one-tap recents strip (camera-roll photos + videos). Below: the pickers.
    private var attachPanel: some View {
        VStack(spacing: 0) {
            // (No custom grabber — the sheet's SYSTEM drag indicator already shows one; drawing our own
            // capsule produced the "two lines" at the top.)
            // Grid: X + "Recents ▾" album dropdown header, Camera tile, then recent photos/videos.
            AttachRecentsStrip(
                onCamera: {
                    showAttachPanel = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { showCamera = true }
                },
                onClose: { showAttachPanel = false },
                onPickPhoto: { ui in
                    // The editor opens OVER the media sheet (sheet stays underneath): X closes just the
                    // editor and lands BACK on the sheet to pick another image (user request — closing
                    // the sheet first meant X dumped you all the way to the chat).
                    panelEditImage = EditImageWrap(image: ui)
                },
                onPickVideo: { url in
                    // TAP a video → trim editor OVER the media sheet (sheet stays underneath): X closes just
                    // the editor and lands BACK on the sheet to pick another (was closing the sheet first,
                    // which dumped you all the way to the chat on a stray X).
                    panelVideoApprove = VideoWrap(url: url)
                },
                onSendVideos: { urls, caption in
                    showAttachPanel = false
                    // SELECT + Send → send each selected video directly (no editor). The caption rides
                    // ONCE, on the first video (was duplicated onto every video in the batch).
                    Task {
                        var cap = caption
                        for url in urls { await sendVideo(from: url, caption: cap); cap = "" }
                    }
                },
                onSendAlbum: { imgs, caption, viewOnce in
                    showAttachPanel = false
                    // Selected via checkboxes + captioned inline: 1 photo → send as one (caption + optional
                    // view-once); 2+ → send as one album with the caption (view-once is single-photo only).
                    Task {
                        if imgs.count == 1, let d = imgs[0].jpegData(compressionQuality: 0.9) {
                            await sendPhoto(d, viewOnce: viewOnce, caption: caption)
                        } else if imgs.count >= 2 {
                            await sendAlbum(imgs, caption: caption, hd: false)
                        }
                    }
                },
                onSendMixed: { items, caption, clientId in
                    // SELECT + Send with a mix (or 2+) → ONE grouped album message (photos + videos).
                    showAttachPanel = false
                    Task {
                        var ordered: [SendMedia] = []
                        for it in items {
                            switch it {
                            case .image(_, let ui): ordered.append(.image(ui))
                            case .video(_, let url, let thumb, let dur):
                                ordered.append(.video(url: url, thumb: thumb ?? UIImage(), duration: dur))
                            }
                        }
                        await sendMixedGroup(ordered, caption: caption, hd: false, clientId: clientId)
                    }
                },
                // The bubble the sheet posted on the Send tap, from its own grid thumbnails.
                onOptimisticGroup: { thumbs, isVideo, caption, clientId in
                    showAttachPanel = false
                    let previews = thumbs.map { $0.jpegData(compressionQuality: 0.7) ?? Data() }
                    repo.addPending(Message(localAlbum: previews, caption: caption, authorId: me,
                                            clientId: clientId, sendState: .sending,
                                            localAlbumIsVideo: isVideo))
                },
                onOptimisticFailed: { clientId in repo.markFailed(clientId: clientId) },
                onOpenMedia: { items in
                    // Tapping media while selecting → the mixed approval pager. A single item keeps its
                    // dedicated editor (image editor / video trim editor); 2+ open the pager. All open OVER
                    // the media sheet (sheet stays underneath) so X returns to it instead of the chat.
                    if items.count == 1, case .image(_, let ui) = items[0] {
                        panelEditImage = EditImageWrap(image: ui)
                    } else if items.count == 1, case .video(_, let url, _, _) = items[0] {
                        panelVideoApprove = VideoWrap(url: url)
                    } else if let clips = ThreadView.videoClips(from: items) {
                        panelMultiVideo = MultiVideoWrap(clips: clips)   // all videos → single-editor page + rail
                    } else {
                        panelMediaApprove = MediaWrap(items: items)
                    }
                },
                onCaptionFocused: { attachDetent = .large },
                hasSelection: $recentsHasSelection,
                // Declared last on the strip, so it goes last here — Swift matches these by position
                // as well as by name.
                removedIds: deselectedIds)
                .padding(.top, 10)
            // Source row (Photos/Files/GIF/Poll) — HIDDEN while items are selected (the caption + Send
            // bar in the recents strip takes its place).
            if !recentsHasSelection {
                // Horizontally scrollable so the row never clips a tile (5 tiles overflow a phone width
                // once Poll is added in groups) — swipe to reach them all.
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        // Order: GIF · Files · Location · Poll (groups only). The Contacts tile is gone
                        // (user 2026-07-29): sharing "a contact" is a phone-book idea, and Fariin has no
                        // phone book — you introduce someone by sharing their profile from THEIR
                        // profile page, which is where the action still lives.
                        attachTile("ic_gif_tile", "GIF") { showGifPicker = true }
                        attachTile("ic_file", "Files") { showFileImporter = true }
                        attachTile("ic_location", "Location") { showLocationShare = true }
                        if isGroup { attachTile("chart.bar", "Poll") { showPollComposer = true } }
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.vertical, 12)
            }
        }
        // Single-image editor presented OVER the media sheet (the sheet stays underneath): X dismisses
        // only the editor → straight back to the sheet to pick another image. Send delivers the photo
        // AND closes the sheet, landing in the chat.
        // Send from an editor OVER the sheet: the editor does NOT self-dismiss (selfDismissOnSend: false);
        // closing the SHEET tears down the whole stack in one motion. When the editor dismissed itself
        // first, the sheet re-appeared for a beat before closing (the flash the user reported).
        .fullScreenCover(item: $panelEditImage) { wrap in
            ChatImageEditor(source: wrap.image,
                            onSend: { data, caption, _, viewOnce in
                                Task { await sendPhoto(data, viewOnce: viewOnce, caption: caption) }
                                showAttachPanel = false
                            },
                            selfDismissOnSend: false)
        }
        // Single-video trim editor OVER the sheet: X returns to the sheet; Send delivers + closes the sheet.
        .fullScreenCover(item: $panelVideoApprove) { wrap in
            VideoApprovalView(url: wrap.url,
                              onSend: { finalURL, caption, hd in
                                  Task { await sendVideo(from: finalURL, caption: caption, hd: hd) }
                                  showAttachPanel = false
                              },
                              selfDismissOnSend: false)
        }
        // Mixed approval pager OVER the sheet: X returns to the sheet; Send delivers the group + closes it.
        .fullScreenCover(item: $panelMediaApprove) { wrap in
            MediaApprovalView(items: wrap.items,
                              onRemove: { deselectedIds.insert($0) },
                              onSend: { ordered, caption, hd in
                                  Task { await sendMixedGroup(ordered, caption: caption, hd: hd) }
                                  showAttachPanel = false
                              },
                              selfDismissOnSend: false)
        }
        // Multi-VIDEO editor OVER the sheet (all-video selections): the single video editor's exact page
        // + the thumbnail rail. Sends each clip in order; the caption rides once, on the first.
        .fullScreenCover(item: $panelMultiVideo) { wrap in
            VideoApprovalView(clips: wrap.clips, onSendMulti: { urls, caption, hd in
                Task {
                    var cap = caption
                    for u in urls { await sendVideo(from: u, caption: cap, hd: hd); cap = "" }
                }
                showAttachPanel = false
            }, selfDismissOnSend: false, onRemove: { deselectedIds.insert($0) })
        }
    }

    // Polls aren't built yet — a small "coming soon" sheet at a 60% detent (user request).
    private func comingSoonSheet(_ c: ComingSoonWrap) -> some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: c.icon).font(.system(size: 52, weight: .regular)).foregroundStyle(.secondary)
            Text(c.title).font(.title2.weight(.bold))
            Text("Coming soon.").font(.body).foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    // Attachment-button spec: a 76×50pt CAPSULE button
    // with the icon inside, and a footnote-medium label 8pt BELOW the capsule.
    private func attachTile(_ icon: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button {
            showAttachPanel = false
            // Let the sheet finish dismissing before presenting the next picker (avoids a clash).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { action() }
        } label: {
            VStack(spacing: 8) {
                // "ic_" names one of our own drawings; anything else is an SF Symbol.
                Group {
                    if icon.hasPrefix("ic_") {
                        Image(icon).renderingMode(.template).resizable().scaledToFit()
                            .frame(width: 22, height: 22)
                    } else {
                        Image(systemName: icon).font(.system(size: 20, weight: .medium))
                    }
                }
                    .foregroundStyle(.primary)
                    .frame(width: 76, height: 50)
                    .liquidGlass(Capsule(), interactive: true)   // real Liquid Glass capsule
                Text(label).font(.footnote.weight(.medium)).foregroundStyle(.primary)
            }
        }
        .buttonStyle(.plain)
    }

    // Download the encrypted file, decrypt it, write to a temp file, and preview it (QuickLook).
    private func openFile(_ message: Message) {
        guard let s = message.fileUrl, let url = URL(string: s), let meta = message.enc else { return }
        Task {
            guard let (cipher, _) = try? await MediaSession.shared.data(from: url),
                  let data = await Crypto.shared.decryptBytes(cid, cipher: cipher, meta: meta) else {
                await MainActor.run { sendError = "Couldn't open the file." }; return
            }
            let name = message.fileName ?? "file"
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(name)
            try? data.write(to: tmp)
            // PDFs open in the custom PDFKit reader (Liquid Glass); everything else uses QuickLook.
            let isPDF = name.lowercased().hasSuffix(".pdf") || data.prefix(4).elementsEqual([0x25, 0x50, 0x44, 0x46])   // "%PDF"
            await MainActor.run {
                if isPDF { pdfDoc = PDFDocWrap(url: tmp, title: name) }
                else { filePreview = PreviewFile(url: tmp) }
            }
        }
    }

    private func handlePickedFile(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        Task { await sendDocument(url) }
    }
    private func sendDocument(_ url: URL) async {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        // Check the size BEFORE materializing the whole file (attributes, not a full read).
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           size > Limits.fileUploadBytes {
            await MainActor.run { sendError = "File too large (max \(Limits.fileUploadBytes / (1024*1024)) MB)." }; return
        }
        guard let data = try? Data(contentsOf: url) else { return }
        guard data.count <= Limits.fileUploadBytes else {
            await MainActor.run { sendError = "File too large (max \(Limits.fileUploadBytes / (1024*1024)) MB)." }; return
        }
        let name = url.lastPathComponent
        // Optimistic bubble FIRST (instant feedback) — the encrypt+upload then runs in the background and
        // the server echo reconciles it by clientId. Was: awaited the whole upload before anything showed.
        let clientId = UUID().uuidString
        // Persist the document bytes keyed by clientId so a failed send can actually retry (the old
        // retry path had nothing to re-send for files).
        let retryURL = FileManager.default.temporaryDirectory.appendingPathComponent("pending-file-\(clientId)")
        try? data.write(to: retryURL)
        await MainActor.run {
            var pending = Message(localFileName: name, fileSize: data.count, authorId: me,
                                  clientId: clientId, sendState: .sending)
            pending.localMediaURL = retryURL.path
            // The preview is computed on THIS device (documentPreviewJPEG is a pure local render of
            // a PDF's first page / an image file's pixels), so the pending bubble can show the exact
            // tile the echo will carry. Without it the bubble was a 26pt spinner while sending and a
            // 44x58 page tile once it landed, so it visibly resized mid-send (owner report).
            pending.localImageData = ChatService.documentPreviewJPEG(fileName: name, data: data)
            repo.addPending(pending)
        }
        do {
            try await ChatService.sendFile(cid: cid, data: data, fileName: name, clientId: clientId, group: isGroup ? groupMembers : nil)
            try? FileManager.default.removeItem(at: retryURL)
        }
        catch { await MainActor.run { repo.markFailed(clientId: clientId); sendError = "Couldn't send the file. Try again." } }
    }

    // Live name: prefer the conversation's current displayName (which reads ContactNames observably), so
    // a nickname change in the profile updates the header INSTANTLY — the `title` passed at open is a
    // captured snapshot that never refreshed.
    private var liveTitle: String {
        let me = AuthService.shared.uid ?? ""
        return ConversationsRepository.shared.conversations.first { $0.id == cid }?.displayName(me) ?? title
    }

    // Avatar + name + presence shown in the chat header (kept glass-free — see chatToolbar).
    private var headerLabel: some View {
        // Measurements matched to a reference conversation header (iOS 26 variant): 40pt avatar,
        // 12pt avatar→name spacing, 17pt-semibold title (.headline), a 16×16 title-row icon at 5pt.
        HStack(spacing: 12) {
            AvatarView(name: liveTitle, photoUrl: photoUrl, size: 40)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(liveTitle).font(.headline).foregroundStyle(.primary).lineLimit(1)
                    // Who you are actually talking to. The header is the surface that matters most
                    // for this mark: it is on screen for the whole conversation, and it is the last
                    // thing somebody sees before they answer a stranger.
                    if !isGroup { VerifiedMark(uid: otherUid, size: 14) }
                    // Constant reminder that messages self-delete here —
                    // this timer being invisible is how a whole chat history vanished unnoticed.
                    if repo.disappearSeconds > 0 {
                        Image(systemName: "timer")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 16, height: 16)
                            .foregroundStyle(.secondary)
                    }
                }
                if let sub = presenceSubtitle {
                    Text(sub).font(.caption2)
                        .foregroundStyle(repo.otherTyping ? Color.accentColor : Color.secondary)
                        .lineLimit(1)
                        .animation(.easeInOut(duration: 0.2), value: repo.otherTyping)
                }
            }
            .fixedSize()
        }
    }

    // MARK: - @mentions (groups)

    // The "@token" currently being typed at the end of the input, or nil.
    private var mentionQuery: String? {
        guard isGroup, let r = input.range(of: "@[^\\s@]*$", options: .regularExpression) else { return nil }
        return String(input[r].dropFirst())
    }

    // Members matching the current @query (excluding me).
    private var mentionCandidates: [(uid: String, name: String)] {
        guard let q = mentionQuery else { return [] }
        let names = conversation?.names ?? [:]
        return groupMembers.filter { $0 != me }.compactMap { uid -> (uid: String, name: String)? in
            let n = names[uid] ?? ""
            guard !n.isEmpty else { return nil }
            return (q.isEmpty || n.lowercased().contains(q.lowercased())) ? (uid, n) : nil
        }
    }

    private func insertMention(_ uid: String, _ name: String) {
        if let r = input.range(of: "@[^\\s@]*$", options: .regularExpression) {
            input.replaceSubrange(r, with: "@\(name) ")
        }
        mentionMap[name] = uid
        UISelectionFeedbackGenerator().selectionChanged()
    }

    private func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        impact(.light)   // tactile send (parity with voice release)
        #if DEBUG
        if DemoMode.active {   // preview: echo locally, no encryption/Firestore
            input = ""; typingSent = false
            repo.addDemoMessage(text, from: me)
            return
        }
        #endif
        // Resolve which inserted @mentions are still present in the final text.
        let mentions = mentionMap.compactMap { text.contains("@\($0.key)") ? $0.value : nil }
        mentionMap = [:]
        input = ""
        let reply = replyingTo.map {
            ReplyRef(id: $0.id, authorId: $0.authorId,
                     text: replyQuoteText($0))
        }
        // Animated, exactly like the X button does it (see the reply banner's cancel). Clearing it
        // bare drops the banner's ~54pt out of the composer in one frame with no layout pass the
        // list can follow, so the inverted list kept the taller composer's bottom inset and left a
        // dead gap between the new bubble and the composer (owner: cancel lands right, send does
        // not). Same animation on every send path below.
        withAnimation(.easeInOut(duration: 0.2)) { replyingTo = nil }
        typingSent = false
        // Show the bubble INSTANTLY (optimistic), then reconcile when the server echoes it.
        // Native: the bubble just appears (no custom spring), like a plain list insert.
        let clientId = UUID().uuidString
        // The composer's link-preview draft rides the send: the pending bubble carries the plaintext
        // card (its image under a local draft key), and the sealed copy travels with the message.
        let draft = linkDraft
        linkDetectTask?.cancel()
        linkDraft = nil
        suppressedLinkUrl = nil
        var pendingPreview: Message.LinkPreviewData?
        if let d = draft {
            var imageKey: String?
            if let img = d.image {
                imageKey = "lp-draft-\(clientId)"
                DiskImageCache.shared.store(img, for: imageKey!)
            }
            pendingPreview = Message.LinkPreviewData(url: d.url.absoluteString, title: d.title,
                                                    desc: d.desc, imageUrl: imageKey, imageEnc: nil)
        }
        repo.addPending(Message(localText: text, authorId: me, clientId: clientId, replyTo: reply,
                                sendState: .sending, linkPreview: pendingPreview))
        broadcastTyping(false)   // serialized with any in-flight typing write (no stuck "typing…")
        // KILL THE KEEP-ALIVE HERE TOO. Sending clears typingSent directly, so the onChange flip
        // branch that normally invalidates this timer never runs, and clearing the field also
        // cancels the idle-stop that was the only other cleanup — the timer then re-broadcast
        // "typing…" every 10s forever and the other side never saw it stop (my own regression).
        typingBox.typingRefresh?.invalidate(); typingBox.typingRefresh = nil
        Task {
            await deliver(text: text, reply: reply, clientId: clientId, mentions: mentions, draft: draft)
        }
    }

    /// Delete-for-me that also CANCELS an unsent message (audit): a pending or failed text has
    /// `id == clientId`, so hiding it locally left its durable SendQueue entry behind, and the next
    /// chat open re-sent it — arriving under a NEW doc id the hide could never match, so a message
    /// the user deleted was delivered to the other person and reappeared. For those, drop the queue
    /// entry and the optimistic bubble instead. Delivered messages keep the plain local hide.
    private func deleteForMe(_ m: Message) {
        if m.sendState != nil {
            if let clientId = m.clientId {
                SendQueue.remove(clientId: clientId)
                MediaSend.shared.cancel(clientId)   // a media upload mid-flight dies with the bubble
                repo.removePending(clientId: clientId)
            }
            return
        }
        repo.hideForMe(m.id)
    }

    // Re-try a failed message — re-drives the SAME send path that produced it, with the SAME clientId.
    // Per-type routing (video checked BEFORE localImageData, which only holds its THUMBNAIL — the old
    // single-branch retry re-sent that thumbnail as a photo, and audio/file/album retries sent nothing).
    private func resend(_ m: Message) {
        let clientId = m.clientId ?? UUID().uuidString
        // The original send may have actually SUCCEEDED after the failure flip (slow network): if its
        // echo is already in the window, just drop the stale failed pending — never send a duplicate.
        if repo.messages.contains(where: { $0.clientId == clientId }) {
            repo.removePending(clientId: clientId)
            return
        }
        repo.removePending(clientId: clientId)

        if m.isVideo {
            // Video retry needs the transcoded bytes we persisted to tmp. If that file is gone (OS
            // purged tmp / relaunch), DO NOT fall through to the image branch — localImageData holds
            // only the POSTER thumbnail, so that path would silently send a still photo instead of the
            // video. Re-mark failed and surface it instead.
            guard let path = m.localMediaURL,
                  let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
                repo.addPending(m)   // keep the failed video bubble; the payload is unrecoverable
                repo.markFailed(clientId: clientId)
                sendError = "This video can't be re-sent — please pick it again."
                return
            }
            var p = Message(localVideoThumb: m.localImageData ?? Data(), duration: m.duration ?? 0,
                            width: m.width ?? 1, height: m.height ?? 1,
                            authorId: me, clientId: clientId, sendState: .sending)
            p.localMediaURL = path; p.text = m.text
            repo.addPending(p)
            Task {
                do {
                    try await ChatService.sendVideo(cid: cid, video: data, thumbnail: m.localImageData ?? Data(),
                                                    duration: m.duration ?? 0, width: m.width ?? 1, height: m.height ?? 1,
                                                    caption: m.text, clientId: clientId, group: isGroup ? groupMembers : nil)
                    try? FileManager.default.removeItem(atPath: path)
                } catch { await MainActor.run { repo.markFailed(clientId: clientId) } }
            }
        } else if m.isAudio, let data = m.localAudioData {
            repo.addPending(Message(localAudioData: data, duration: m.duration ?? 0, waveform: m.waveform,
                                    authorId: me, clientId: clientId, sendState: .sending))
            Task {
                do { try await ChatService.sendAudio(cid: cid, data: data, duration: m.duration ?? 0,
                                                     waveform: m.waveform, replyTo: m.replyTo,
                                                     clientId: clientId, group: isGroup ? groupMembers : nil) }
                catch { await MainActor.run { repo.markFailed(clientId: clientId) } }
            }
        } else if m.isAlbum, !m.localAlbum.isEmpty {
            repo.addPending(Message(localAlbum: m.localAlbum, caption: m.text,
                                    authorId: me, clientId: clientId, sendState: .sending))
            let album = m.localAlbum, text = m.text
            Task {
                await runRegisteredSend(clientId) {
                    try await ChatService.sendAlbum(cid: cid, images: album, caption: text,
                                                    clientId: clientId, group: isGroup ? groupMembers : nil)
                }
            }
        } else if m.isFile, let path = m.localMediaURL,
                  let data = try? Data(contentsOf: URL(fileURLWithPath: path)) {
            var p = Message(localFileName: m.fileName ?? "Document", fileSize: m.fileSize ?? data.count,
                            authorId: me, clientId: clientId, sendState: .sending)
            p.localMediaURL = path
            repo.addPending(p)
            Task {
                do {
                    try await ChatService.sendFile(cid: cid, data: data, fileName: m.fileName ?? "Document",
                                                   clientId: clientId, group: isGroup ? groupMembers : nil)
                    try? FileManager.default.removeItem(atPath: path)
                } catch { await MainActor.run { repo.markFailed(clientId: clientId) } }
            }
        } else if let data = m.localImageData {
            // Plain photo — retry keeps the caption AND the view-once flag (both were stripped before).
            var p = Message(localImageData: data, width: m.width ?? 1, height: m.height ?? 1,
                            authorId: me, clientId: clientId, sendState: .sending)
            p.text = m.text; p.viewOnce = m.viewOnce; p.replyTo = m.replyTo   // retry keeps the quote too
            repo.addPending(p)
            Task {
                do { try await ChatService.sendImage(cid: cid, data: data, replyTo: m.replyTo, clientId: clientId,
                                                     group: isGroup ? groupMembers : nil,
                                                     viewOnce: m.viewOnce, caption: m.text) }
                catch { await MainActor.run { repo.markFailed(clientId: clientId) } }
            }
        } else if !m.text.isEmpty {
            repo.addPending(Message(localText: m.text, authorId: me, clientId: clientId,
                                    replyTo: m.replyTo, sendState: .sending))
            Task { await deliver(text: m.text, reply: m.replyTo, clientId: clientId) }
        }
        // (empty text + no payload: nothing to resend — drop the pending rather than recreate a ghost)
    }

    // Send a photo with an instant optimistic bubble, then reconcile on the echo.
    // Send 2+ photos as ONE album (grid + one caption). Optimistic album bubble shows immediately.
    /// TEN PER ALBUM, THEN A NEW ALBUM. Picking twelve photos used to make ONE message of twelve, which
    /// the bubble could only show as ten tiles and a "+2" badge — a message you cannot actually see the
    /// contents of. Every messenger caps the group and starts another; twelve becomes 10 + 2.
    ///
    /// Chunked at the SEND, not in the bubble, so the cap is a property of the message rather than of one
    /// view: the album screen, the pager, the media gallery and the chat-list preview all count the same
    /// ten without each needing their own clamp. The caption rides the FIRST chunk only, the way a
    /// caption belongs to one message.
    private func sendAlbum(_ images: [UIImage], caption: String, hd: Bool) async {
        let datas = images.compactMap { $0.jpegData(compressionQuality: hd ? 0.95 : 0.85) }
        guard !datas.isEmpty else { return }
        for (i, chunk) in stride(from: 0, to: datas.count, by: Limits.albumMaxItems)
            .map({ Array(datas[$0 ..< min($0 + Limits.albumMaxItems, datas.count)]) })
            .enumerated() {
            await sendOneAlbum(chunk, caption: i == 0 ? caption : "")
        }
    }

    private func sendOneAlbum(_ datas: [Data], caption: String) async {
        let previews = datas.map { ChatService.downscaledJPEG($0) }
        let clientId = UUID().uuidString
        await MainActor.run {
            repo.addPending(Message(localAlbum: previews, caption: caption, authorId: me,
                                    clientId: clientId, sendState: .sending))
        }
        await runRegisteredSend(clientId) {
            try await ChatService.sendAlbum(cid: cid, images: datas, caption: caption,
                                            clientId: clientId, group: isGroup ? groupMembers : nil)
        }
    }

    /// Run a media send with its Task REGISTERED, so Cancel Sending can reach in and stop it, and
    /// with the cancelled outcome told apart from a real failure: a cancelled bubble is removed
    /// quietly (the user asked for that), a failed one is marked so Tap-to-retry appears.
    /// `onFailure` runs only for REAL failures, after the mark — for paths that also surface a
    /// message (the mixed-group send names its error).
    private func runRegisteredSend(_ clientId: String,
                                   onFailure: (@MainActor (Error) -> Void)? = nil,
                                   _ body: @escaping () async throws -> Void) async {
        let task: Task<Void, Error> = Task { try await body() }
        await MainActor.run { MediaSend.shared.register(clientId, task) }
        do {
            try await task.value
            await MainActor.run { MediaSend.shared.finish(clientId) }
        } catch {
            await MainActor.run {
                let cancelled = MediaSend.shared.wasCancelled(clientId) || error is CancellationError
                MediaSend.shared.finish(clientId)
                if cancelled {
                    repo.removePending(clientId: clientId)   // every-tile-X'd path; Cancel already removed it
                } else {
                    repo.markFailed(clientId: clientId)
                    onFailure?(error)
                }
            }
        }
    }

    // Send a MIXED media group (photos + videos in order) as ONE album message. A single lone item
    // takes its dedicated fast path (photo editor / video approval already handled those); this is the
    // 2+ / mixed case. Videos are transcoded first, then everything ships in one sendMixedAlbum call.
    /// `clientId` non-nil means the attach sheet ALREADY posted the bubble (from its grid thumbnails,
    /// on the Send tap) and this call must adopt it rather than post a second one.
    private func sendMixedGroup(_ ordered: [SendMedia], caption: String, hd: Bool,
                                clientId posted: String? = nil) async {
        // A lone item → the normal single-media send (keeps the existing UX). That path posts its own
        // bubble, so retire the group bubble first — otherwise it would sit "sending" forever (this
        // happens when several were picked but only one survived the resolve).
        if ordered.count == 1 {
            if let posted { await MainActor.run { repo.removePending(clientId: posted) } }
            switch ordered[0] {
            case .image(let ui):
                if let d = ui.jpegData(compressionQuality: hd ? 0.95 : 0.85) { await sendPhoto(d, caption: caption) }
            case .video(let url, _, _):
                await sendVideo(from: url, caption: caption, hd: hd)
            }
            return
        }

        // Optimistic grouped bubble: thumbnails in order + which are videos (play badge). Build BOTH
        // arrays in ONE pass so their indices ALWAYS align (a compactMap'd previews vs a map'd flags
        // list drifted apart when a thumbnail failed to encode → play badges on the wrong tiles).
        //
        // SKIPPED ENTIRELY when the sheet already posted the bubble: this loop is N full-resolution
        // JPEG encodes plus N decode-resize-re-encodes on the main thread, and doing it before first
        // paint was half of the delay the user timed. The sheet's grid thumbnails render the same grid.
        let clientId = posted ?? UUID().uuidString
        if posted == nil {
            var previews: [Data] = []
            var isVideoFlags: [Bool] = []
            for item in ordered {
                let (thumb, isVid): (UIImage, Bool) = {
                    switch item {
                    case .image(let ui): return (ui, false)
                    case .video(_, let t, _): return (t, true)
                    }
                }()
                let jpeg = thumb.jpegData(compressionQuality: 0.7).map { ChatService.downscaledJPEG($0) }
                    ?? Data()   // keep a placeholder so the index stays in lockstep with the flags
                previews.append(jpeg)
                isVideoFlags.append(isVid)
            }
            await MainActor.run {
                repo.addPending(Message(localAlbum: previews, caption: caption, authorId: me,
                                        clientId: clientId, sendState: .sending, localAlbumIsVideo: isVideoFlags))
            }
        }

        // Build the send items: images as-is, videos transcoded (HD toggle) to the delivery codec. If
        // ANY item fails to prepare, fail the WHOLE group (don't silently drop an item — the album
        // would ship with fewer items than the bubble showed).
        var sendItems: [ChatService.AlbumSendItem] = []
        for item in ordered {
            switch item {
            case .image(let ui):
                guard let d = ui.jpegData(compressionQuality: hd ? 0.95 : 0.85) else {
                    await MainActor.run { repo.markFailed(clientId: clientId); sendError = "Couldn't prepare one of the photos." }
                    return
                }
                sendItems.append(.image(d))
            case .video(let url, let thumb, let duration):
                guard let prepared = await VideoTranscoder.prepare(url, hd: hd) else {
                    await MainActor.run { repo.markFailed(clientId: clientId); sendError = "Couldn't process one of the videos." }
                    return
                }
                try? FileManager.default.removeItem(at: url)
                let thumbData = thumb.jpegData(compressionQuality: 0.8) ?? prepared.thumbnail
                sendItems.append(.video(prepared.data, thumbnail: thumbData,
                                        duration: duration > 0 ? duration : prepared.duration,
                                        width: prepared.width, height: prepared.height))
            }
        }
        guard !sendItems.isEmpty else { await MainActor.run { repo.markFailed(clientId: clientId) }; return }
        let items = sendItems
        // Same reasoning as sendVideo's catch: a failure that names no cause cannot be acted on
        // by the sender or fixed by anybody. A CANCEL is not a failure — the helper removes the
        // bubble quietly and never reaches the failure hook.
        await runRegisteredSend(clientId, onFailure: { error in
            print("sendMixedAlbum failed:", error)
            sendError = "Couldn't send. \(error.localizedDescription)"
        }) {
            try await ChatService.sendMixedAlbum(cid: cid, items: items, caption: caption,
                                                 clientId: clientId, group: isGroup ? groupMembers : nil)
        }
    }

    private func sendPhoto(_ data: Data, viewOnce: Bool = false, caption: String = "") async {
        let preview = ChatService.downscaledJPEG(data)
        let size = UIImage(data: preview)?.size ?? CGSize(width: 1, height: 1)
        let clientId = UUID().uuidString
        // A photo sent while replying carries the reply (like text/voice) and clears the bar.
        let reply = replyingTo.map {
            ReplyRef(id: $0.id, authorId: $0.authorId,
                     text: replyQuoteText($0))
        }
        await MainActor.run {
            var pending = Message(localImageData: preview, width: Double(size.width), height: Double(size.height),
                                  authorId: me, clientId: clientId, sendState: .sending)
            pending.viewOnce = viewOnce
            pending.text = caption   // caption rides inside the image bubble
            pending.replyTo = reply
            repo.addPending(pending)
            withAnimation(.easeInOut(duration: 0.2)) { replyingTo = nil }
        }
        do { try await ChatService.sendImage(cid: cid, data: data, replyTo: reply, clientId: clientId, group: isGroup ? groupMembers : nil, viewOnce: viewOnce, caption: caption) }
        catch { await MainActor.run { repo.markFailed(clientId: clientId) } }
    }

    // Save a chat photo to the camera roll (decrypts if needed) with a success haptic.
    @MainActor private func saveImageToPhotos(_ m: Message) async {
        // A still-UPLOADING album keeps its bytes in localAlbum — the single-image paths below are
        // all nil for it, so the menu's Save Image silently did nothing (audit). Save its photos
        // (video items skipped) with one shared authorization pass.
        if !m.localAlbum.isEmpty {
            let images = m.localAlbum.enumerated()
                .filter { i, _ in !(m.localAlbumIsVideo.indices.contains(i) && m.localAlbumIsVideo[i]) }
                .compactMap { UIImage(data: $0.element) }
            guard !images.isEmpty else { return }
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else { return }
            try? await PHPhotoLibrary.shared().performChanges {
                for image in images { PHAssetChangeRequest.creationRequestForAsset(from: image) }
            }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            return
        }
        var ui: UIImage?
        if let local = m.localImageData { ui = UIImage(data: local) }
        else if let s = m.imageUrl {
            if let cached = DiskImageCache.shared.memoryImage(s) { ui = cached }
            else if let cached = await DiskImageCache.shared.image(for: s) { ui = cached }
            else if let url = URL(string: s), let (cipher, _) = try? await MediaSession.shared.data(from: url) {
                if let meta = m.enc, let dec = await Crypto.shared.decryptBytes(cid, cipher: cipher, meta: meta) {
                    ui = UIImage(data: dec)
                } else { ui = UIImage(data: cipher) }
            }
        }
        guard let image = ui else { return }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { return }
        try? await PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest.creationRequestForAsset(from: image) }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    private func deliver(text: String, reply: ReplyRef?, clientId: String, mentions: [String] = [],
                         draft: LinkPreviewService.LinkDraft? = nil) async {
        // DURABLE: persist the send BEFORE the network call so a mid-send app kill doesn't lose the
        // message — it's re-driven on the next chat open (drainSendQueue). Removed once it lands.
        // (A queue re-drive after an app kill sends WITHOUT the preview — the draft lives in memory
        // only; the text always survives, which is the part that matters.)
        SendQueue.add(clientId: clientId, cid: cid, text: text, mentions: mentions, reply: reply,
                      ts: Date().timeIntervalSince1970)
        do {
            let preview = draft.map {
                ChatService.OutgoingLinkPreview(url: $0.url.absoluteString, title: $0.title,
                                                desc: $0.desc, imageJPEG: $0.imageJPEG)
            }
            try await ChatService.sendText(cid: cid, text: text, replyTo: reply, clientId: clientId,
                                           group: isGroup ? groupMembers : nil, mentions: mentions,
                                           preview: preview)
            SendQueue.remove(clientId: clientId)   // landed → no re-drive needed
        } catch {
            // Keep the message as a failed bubble (tap to retry); flag the encryption case. The queue
            // entry stays so the next chat open retries it automatically.
            await MainActor.run {
                repo.markFailed(clientId: clientId)
                if error is MissingRecipientKeyError {
                    sendError = isGroup
                        ? "No one in this group has set up encryption yet. Your message will send once a member opens Fariin."
                        : "\(title) hasn't opened Fariin yet, so encryption isn't set up. Your message will send once they do."
                }
            }
        }
    }

    // Re-drive any persisted text sends for this chat that never completed (app killed mid-send). Skips
    // ones that actually landed (clientId already on the server) to avoid duplicates.
    private func drainSendQueue() async {
        for entry in SendQueue.pending(for: cid) {
            // Already reconciled in this session's window? skip.
            if repo.messages.contains(where: { $0.clientId == entry.clientId }) { SendQueue.remove(clientId: entry.clientId); continue }
            if await SendQueue.alreadySent(cid: cid, clientId: entry.clientId) { SendQueue.remove(clientId: entry.clientId); continue }
            let reply: ReplyRef? = entry.replyId.map { ReplyRef(id: $0, authorId: entry.replyAuthor ?? "", text: entry.replyText ?? "") }
            await MainActor.run {
                if !repo.messages.contains(where: { $0.clientId == entry.clientId }) {
                    repo.addPending(Message(localText: entry.text, authorId: me, clientId: entry.clientId,
                                            replyTo: reply, sendState: .sending))
                }
            }
            await deliver(text: entry.text, reply: reply, clientId: entry.clientId, mentions: entry.mentions)
        }
    }

    // Call record as a message bubble. Outgoing = right-aligned accent
    // bubble; incoming & missed = left-aligned received bubble. Inside: a circular call
    // A newer-version feature this build can't render: a centered, system-notification-style card (icon +
    // explanation) — deliberately distinct from any chat bubble so it can't be read as normal content.
    private func unsupportedRow(_ m: Message) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.up.circle.fill").font(.system(size: 15))
            Text("This message was sent using a newer version of the app. Update to the latest version to view it.")
                .font(.system(size: 12, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.leading)
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Theme.received(dark).opacity(0.7),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(Color.secondary.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        .frame(maxWidth: 300)
        .frame(maxWidth: .infinity)   // centered in the thread
        .padding(.vertical, 6)
    }

    // Centered gray system event ("X added Y", "Z left", "renamed to…") — group only.
    // reference-style pin notice: "X pinned "snippet…"" / "X pinned a photo" — the system-row capsule
    // with the pinner's name bolded; tapping jumps to the pinned message (pages history in if needed).
    private func pinNoticeRow(_ m: Message, _ pin: PinNoticeCard,
                              jumpTo: @escaping (String) -> Void) -> some View {
        Button { jumpTo(pin.messageId) } label: {
            // ONE uniform line, exactly the day pill's treatment (user: make it the same, no
            // difference). The old per-word weight split is gone with it — "Today" is one weight,
            // so this is too.
            Text("\(m.authorId == me ? "You" : personName(m.authorId)) pinned \(pin.label)")
                .lineLimit(1)
                .modifier(ChatNoticePill())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
    }

    private func systemRow(_ m: Message) -> some View {
        Text(m.text)
            .multilineTextAlignment(.center)
            .modifier(ChatNoticePill())
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
    }

    // DISPLAY-TIME guard for reply-quote snippets: quotes persisted BEFORE the safeText fix carry the
    // raw "fariin-…:" marker forever (they're encrypted snapshots) — map them to friendly labels when
    // rendering, so old quotes clean up too.
    static func quoteLabel(_ t: String) -> String { quoteSafeLabel(t) }
    private static func _unusedQuoteLabelBody(_ t: String) -> String {
        if t.hasPrefix(Message.contactMarker) { return "Contact" }
        if t.hasPrefix(Message.locationMarker) { return "Location" }
        if t.range(of: Message.featureMarkerPattern, options: .regularExpression) != nil { return "Message" }
        return t
    }

    // icon, bold status, a muted subtitle (duration or "Tap to call back"), and the
    // timestamp bottom-right. Tap anywhere to call back.
    private func callRow(_ m: Message) -> some View {
        let mine = m.callerUid == me
        // LIVE STATES (owner's 2026-08-12 reference): the row exists from the first ring — "Ringing",
        // then "Ongoing" at connect — and recordCall finalises the SAME row in place. The age
        // fallbacks are the safety net for a writer that died mid-call: an orphan "ringing" renders
        // as a normal unanswered call, a stale "ongoing" as a plain ended one.
        let age = Date().timeIntervalSince(m.createdAt)
        let ringing = m.callOutcome == "ringing" && age < 120
        let ongoing = m.callOutcome == "ongoing" && age < 4 * 3600
        // Legacy "declined" records (written before declines were removed from the log — his
        // 2026-08-12 order) render exactly as missed: the caller reads "No answer",
        // the decliner reads the same red "Missed call" as an ignored ring.
        let missed = m.callOutcome == "missed" || m.callOutcome == "declined"
            || (m.callOutcome == "ringing" && age >= 120)
        let video = m.callVideo
        // Call semantics (user spec): "Missed call" (red) is ONLY for calls I RECEIVED and didn't
        // answer. When I was the CALLER and nobody picked up, it's an outgoing call with "No answer" —
        // neutral colors, outgoing arrow — never red, never "tap to call back" (I was the one calling).
        let incomingMissed = missed && !mine
        let statusText: String = {
            if video { return incomingMissed ? "Missed video call" : "Video call" }
            return incomingMissed ? "Missed voice call" : "Voice call"
        }()
        let time = m.createdAt.formatted(date: .omitted, time: .shortened)
        // Second line: status + time, kept short so the bubble stays compact.
        let detail: String = {
            if ringing { return "Ringing · \(time)" }
            if ongoing { return "Ongoing · \(time)" }
            if incomingMissed { return "Call back · \(time)" }   // short: the bubble wears the COMPACT width now
            if missed { return "No answer · \(time)" }            // MY unanswered outgoing call
            if let d = m.callDuration, d > 0 { return "\(callLogDuration(d)) · \(time)" }
            return "\(mine ? "Outgoing" : "Incoming") · \(time)"
        }()
        let iconName: String = {
            if video { return incomingMissed ? "video.slash.fill" : "video.fill" }
            if incomingMissed { return "phone.arrow.down.left" }
            return mine ? "phone.arrow.up.right" : "phone.arrow.down.left"
        }()
        // Match the REGULAR bubble palette so the call bubble follows the user's chosen chat colour instead
        // of always being the brand accent (user report: "call bubble is a different colour even when I
        // change the bubble colour"). myFill = the per-chat colour or the default bubble; text is white on it,
        // exactly like every other sent bubble (onMyBubble).
        let myBubbleFill: AnyShapeStyle = chatColorSpec?.fill ?? AnyShapeStyle(Theme.defaultBubble(dark))
        let iconColor: Color = incomingMissed ? .red : (mine ? .white : Theme.accent(dark))
        let circleBg: Color = mine ? Color.white.opacity(0.22)
            : (incomingMissed ? Color.red.opacity(0.14) : Theme.accent(dark).opacity(0.14))

        return HStack(spacing: 0) {
            if mine { Spacer(minLength: 60) }
            // No flexible Spacer inside -> the bubble hugs its content (compact, not a banner).
            // SIZE HISTORY, third calibration (do not relitigate without his word): first cut was
            // thin (15/12/34), his side-by-side bumped it one size up (17/14/40, ~62pt tall), and
            // on 2026-08-12 he called that "long" against his 544 screenshots — now the height
            // pieces come down (title 16, detail 13, disc 34) and he named the final number
            // himself: 58pt tall (34 disc + 12 vertical padding). The 232 width stays, which was
            // his separate, explicit choice.
            HStack(alignment: .center, spacing: 11) {
                ZStack {
                    Circle().fill(circleBg).frame(width: 34, height: 34)
                    Image(systemName: iconName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(iconColor)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(statusText)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(mine ? Color.white : .primary)
                        .lineLimit(1)
                    Text(detail)
                        .font(.system(size: 13))
                        .foregroundStyle(mine ? Color.white.opacity(0.75) : .secondary)
                        .lineLimit(1)
                }
            }
            // ONE WIDTH FOR EVERY CALL BUBBLE, AND IT IS THE COMPACT ONE — his order, correcting
            // the first cut of this fix which took the widest case. The size is set by the
            // longest TITLE ("Missed voice call", the one string that cannot shorten); the long
            // subtitle shortened to fit ("Tap to call back" → "Call back").
            //
            // FOURTH CALIBRATION, 2026-08-13, and this time both numbers are HIS, measured off his
            // own screenshot: 220 wide, 60 tall (was 232 wide). ⚠️ They are the bubble's OUTER size
            // now — the old comment added an inner 204 to 28pt of padding and called the height
            // "34 disc + 12 + 12 = 58", which was never what rendered: the two text lines stack to
            // ~37pt, taller than the 34pt disc, so the bubble was really ~61. A height nobody sets
            // is a height nobody can hold to, which is how a "58pt" bubble drifted three points.
            // Pinned, so the number in this comment is the number on the glass.
            .frame(width: 192, alignment: .leading)   // 192 + 28 padding = 220
            .padding(.horizontal, 14)
            .frame(height: 60)
            .background(mine ? myBubbleFill : AnyShapeStyle(Theme.received(dark)))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            // Tap target is ONLY the bubble — NOT the full-width row. The old .contentShape/
            // .onTapGesture sat on the outer HStack (which includes the empty-side Spacer), so
            // tapping the blank space anywhere on the row placed a call (accidental-call bug).
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            // The long press lifts THIS, not the full-width row. Without a published rect the menu
            // falls back to lifting the whole row, which is why the call row's menu never looked
            // like the one every other bubble gets.
            .modifier(CMBubbleRectReporter(id: m.id, radius: 16))
            // CONFIRM before calling back (user spec): a stray tap on a call row must never place a
            // call instantly. Native centered alert → Call / Cancel. A LIVE row (ringing/ongoing)
            // offers no call-back — that call is still happening.
            .onTapGesture { if !ringing, !ongoing { pendingCallBack = video ? .video : .voice } }
            .frame(maxWidth: UIScreen.main.bounds.width * 0.7, alignment: mine ? .trailing : .leading)
            if !mine { Spacer(minLength: 60) }
        }
    }

    // Call-log duration phrasing: "43 sec", "1:31", or "1:31:00".
    private func callLogDuration(_ s: Int) -> String {
        if s < 60 { return "\(s) sec" }
        if s < 3600 { return String(format: "%d:%02d", s / 60, s % 60) }
        return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }

    // "Unread Messages" divider (our design) — a thin accent line + label.
    private var unreadDivider: some View {
        HStack(spacing: 8) {
            Rectangle().fill(Color.accentColor.opacity(0.3)).frame(height: 1)
            Text("Unread Messages").font(.caption.weight(.semibold))
                .foregroundStyle(Color.accentColor).fixedSize()
            Rectangle().fill(Color.accentColor.opacity(0.3)).frame(height: 1)
        }
        .padding(.vertical, 8)
    }

    // Where the chat should land when it opens: the saved in-session spot if that message is still
    // loaded, otherwise the newest. Cold start / first open this session → no saved anchor → newest.
    private var openAnchor: (id: String, edge: UnitPoint) {
        if case .message(let id)? = ChatScrollStore.shared.anchor(for: cid),
           repo.items.contains(where: { $0.id == id }) {
            return (id, .top)
        }
        return ("BOTTOM", .bottom)
    }

    // Remember (in RAM) where we're looking so reopening this chat lands here. Only after the open
    // has SETTLED — during the load we're programmatically pinning, and saving then would feed the
    // pin back into itself. Called from row/BOTTOM onAppear only (teardown-safe).
    // Trailing-debounced save (0.5s after the last row appearance): per-appearance saves ran an O(n)
    // scan + a store write on every scroll tick — pure churn during scrolling (anti-the reference app pattern).
    private func schedulePersistScrollPosition() {
        visibleRows.persistWork?.cancel()
        let work = DispatchWorkItem { persistScrollPosition() }
        visibleRows.persistWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func persistScrollPosition() {
        guard revealed, settled else { return }
        if isAtBottom {
            ChatScrollStore.shared.save(cid, .bottom)
        } else if let topId = repo.items.first(where: { visibleRows.ids.contains($0.id) })?.id {
            ChatScrollStore.shared.save(cid, .message(topId))
        }
    }

    // Reveal the chat exactly at the open anchor with NO jump. LazyVStack row heights aren't final on
    // the first scrollTo (offscreen rows are unmeasured), so it lands approximately; a second pass on
    // the next runloop — after layout — corrects it. We reveal only after both passes, so a cold/first
    // open lands in its FINAL position instead of scrolling-then-settling visibly (the "jump"). A warm
    // reopen already has measured rows, so pass 2 is just a harmless no-op there.
    private func revealAtOpenAnchor(_ proxy: ScrollViewProxy, settlePasses: Int = 11) {
        let a = openAnchor
        // Re-pin to the anchor while hidden so the LazyVStack finishes building rows / async heights
        // settle, then reveal already-at-rest (no jump). WARM opens (measured rows) settle in 1 pass,
        // so they pass a small settlePasses -> revealed in ~60ms instead of ~280ms (kills the "blink"
        // on cached chats). COLD opens keep the full ~280ms so unmeasured rows don't jump.
        var passes = 0
        func tick() {
            proxy.scrollTo(a.id, anchor: a.edge)
            passes += 1
            if passes < settlePasses {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) { tick() }
            } else {
                proxy.scrollTo(a.id, anchor: a.edge)   // final exact pin
                withAnimation(.easeOut(duration: 0.12)) { revealed = true }   // soft fade, not a pop
            }
        }
        DispatchQueue.main.async { tick() }
        enableSlideInAfterReveal()
    }

    // Pin to the newest message across two frames: the first pin lands on the pre-insert layout, the
    // second (next runloop, after the new row is measured) corrects it — so a freshly-arrived bubble
    // can never leave a visible jump. Used for both my sends and received-while-at-bottom.
    private func pinBottomStable(_ proxy: ScrollViewProxy) {
        // Re-pin to the newest message over a few frames — a freshly-inserted bubble (especially a
        // voice/media widget whose height finalizes late) shifts the bottom a runloop or two after
        // insert, so a single pin left a visible jump. Pinning ~5x across ~0.1s absorbs that.
        var passes = 0
        func tick() {
            proxy.scrollTo("BOTTOM", anchor: .bottom)
            passes += 1
            if passes < 5 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) { tick() } }
        }
        DispatchQueue.main.async { tick() }
    }

    // Turn on the message-row slide-in transition a beat AFTER the chat has revealed, so the
    // opening batch appears with zero movement and only genuinely-new messages slide in.
    private func enableSlideInAfterReveal() {
        guard !settled else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { settled = true }
    }

    // Anchor the unread divider above the first unread message and land there on open.
    // Runs once; the last `unreadOnOpen` messages are treated as the unread block.
    private func anchorUnread(_ proxy: ScrollViewProxy) {
        guard !didAnchorUnread, unreadOnOpen > 0 else { return }
        let msgs = repo.messages
        guard !msgs.isEmpty else { return }
        // More unread than the loaded window (40 a page) → the real boundary is further up than
        // anything we hold, and `max(0, …)` used to clamp to the OLDEST LOADED row and label it the
        // start of unread, which is a claim about a message that isn't the boundary at all (audit).
        // Say nothing rather than mark the wrong message; the divider appears once enough is paged in.
        guard unreadOnOpen <= msgs.count else { return }
        let idx = msgs.count - unreadOnOpen
        guard idx < msgs.count else { return }
        // Just mark WHERE the unread divider goes — do NOT scroll to it. The chat always opens at
        // the BOTTOM (newest), like a standard messenger; the divider is a marker you scroll up to.
        // (Scrolling to the first unread dropped the user into old history / old missed calls.)
        firstUnreadId = msgs[idx].id
        didAnchorUnread = true
    }

    private func react(_ m: Message, _ emoji: String) {
        guard m.sendState == nil else { return }   // can't react to a message that isn't on the server yet
        let new = m.reactions[me] == emoji ? nil : emoji
        if let e = new { ReactionRecents.add(e) }
        Task { await ChatService.setReaction(cid: cid, messageId: m.id, emoji: new, toAuthor: m.authorId, group: isGroup ? groupMembers : nil) }
    }


    // Page in older history and keep the user's position (anchor the current top
    // message to the top after the older page prepends, so the list doesn't jump).
    private func loadOlderWithAnchor(_ proxy: ScrollViewProxy) {
        // Never paginate while the open is still settling: on a short history the top sentinel
        // is visible immediately, and the prepend + anchor-scroll fought the bottom pinning -
        // the conversation visibly jumped up and down right after opening (user report).
        guard settled else { return }
        guard repo.canLoadOlder, !repo.loadingOlder else { return }
        let anchor = repo.items.first?.id
        let pinnedAtBottom = isAtBottom
        repo.loadOlder {
            // Pinned at the bottom, a top-prepend doesn't move what you see — the anchor
            // scroll was the thing CAUSING the lurch ~1s after opening (user video). Only
            // preserve position when the user is actually reading history.
            guard let anchor, !pinnedAtBottom else { return }
            DispatchQueue.main.async { proxy.scrollTo(anchor, anchor: .top) }
        }
    }

    // Scroll to a message (e.g. the original of a tapped reply) and flash it briefly.
    private func jump(to id: String, _ proxy: ScrollViewProxy) {
        flashAndScroll(id)   // the UIKit list scrolls via the collection view (nativeScrollTarget)
    }

    // Tapped a "Status" reply quote → open that status if it's still live, else say it's gone.
    // The repo only holds unexpired stories, so "found" == still viewable.
    private func openStory(_ storyId: String, _ authorId: String, anchorId: String = "") {
        let repo = StoriesRepository.shared
        let active = (repo.others + [repo.mine].compactMap { $0 })
            .first { $0.authorUid == authorId && $0.stories.contains { $0.id == storyId } }
        guard var group = active else { statusUnavailable = true; return }
        // OPEN THE STORY THAT WAS ACTUALLY REPLIED TO (audit). The viewer positions each author's
        // bucket at its first UNSEEN item, so with several active stories a reply quote opened a
        // different one — losing the very context ("what did I reply to?") the tap is asking for.
        // The quote is a deep link to ONE item, so hand the viewer exactly that item.
        if let one = group.stories.first(where: { $0.id == storyId }) {
            group.stories = [one]
        }
        // The quote thumbnail is the flight's source. `deliveredToMe: true` — a reply quote only
        // exists because this story was sent to me and I answered it, which is a stronger proof of
        // audience than the chat list.
        StoryDoor.open(group, from: anchorId, deliveredToMe: true)
    }

    private func sendPicked(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        defer { photoItem = nil }
        if let data = try? await item.loadTransferable(type: Data.self) {
            await sendPhoto(data)
        }
    }

    // Multi-select (attachment-approval flow): one photo → the full editor; 2+ photos → the
    // approval screen (swipeable zoomable pages, ordered thumb rail, ONE caption, send in order).
    // Videos go straight into the send pipeline (separate transcode path), same as before.
    private func sendPickedMulti(_ items: [PhotosPickerItem]) async {
        guard !items.isEmpty else { return }
        let picked = items
        await MainActor.run { photoItems = [] }
        if picked.count == 1, !isVideoItem(picked[0]),
           let data = try? await picked[0].loadTransferable(type: Data.self),
           let ui = UIImage(data: data) {
            await MainActor.run { editImage = EditImageWrap(image: ui) }
            return
        }
        // Load every picked item IN ORDER (selection order = send order) into the unified
        // media list: a lone photo/video keeps its dedicated editor; anything else (multiple photos,
        // multiple videos, or a MIX) opens the mixed approval pager — swipe all, edit each, one caption.
        var items: [ApprovalMedia] = []
        for item in picked {
            if isVideoItem(item) {
                if let movie = try? await item.loadTransferable(type: PickedMovie.self) {
                    let asset = AVURLAsset(url: movie.url)
                    let dur = (try? await asset.load(.duration).seconds) ?? 0
                    let gen = AVAssetImageGenerator(asset: asset)
                    gen.appliesPreferredTrackTransform = true
                    gen.maximumSize = CGSize(width: 320, height: 320)
                    let thumb = (try? await gen.image(at: .zero).image).map { UIImage(cgImage: $0) }
                    items.append(.video(UUID().uuidString, movie.url, thumb, dur))
                }
            } else if let data = try? await item.loadTransferable(type: Data.self),
                      let ui = UIImage(data: data) {
                items.append(.image(UUID().uuidString, ui))
            }
        }
        guard !items.isEmpty else { return }
        await MainActor.run {
            if items.count == 1, case .image(_, let ui) = items[0] {
                editImage = EditImageWrap(image: ui)
            } else if items.count == 1, case .video(_, let url, _, _) = items[0] {
                videoToApprove = VideoWrap(url: url)
            } else if let clips = ThreadView.videoClips(from: items) {
                multiVideoApprove = MultiVideoWrap(clips: clips)   // all videos → single-editor page + rail
            } else {
                mediaToApprove = MediaWrap(items: items)
            }
        }
    }

    private func isVideoItem(_ item: PhotosPickerItem) -> Bool {
        item.supportedContentTypes.contains { $0.conforms(to: .movie) }
    }

    // Transcode → optimistic thumbnail bubble → E2EE upload (ChatService.sendVideo keeps
    // the sender's copy on-device; the recipient's player deletes the server object).
    private func sendVideo(from url: URL, caption: String = "", hd: Bool = false) async {
        // THE BUBBLE COMES FIRST, BEFORE THE TRANSCODE. It used to come after: this function awaited
        // `VideoTranscoder.prepare` and only then had a thumbnail to draw with, so tapping send on a
        // video did nothing visible for as long as the compression took — the owner timed it at 3.88
        // seconds on an eighteen second clip and it reads as the app ignoring the tap.
        //
        // A poster is one decoded frame, tens of milliseconds. Everything expensive now happens with
        // the bubble already on screen and its ring already turning, which is what every other send
        // path in this file does and the video path never did.
        guard let poster = await VideoTranscoder.poster(url) else {
            try? FileManager.default.removeItem(at: url)
            await MainActor.run { sendError = "Couldn't process this video." }
            return
        }
        let clientId = UUID().uuidString
        await MainActor.run {
            var pending = Message(localVideoThumb: poster.jpeg, duration: poster.duration,
                                  width: poster.width, height: poster.height,
                                  authorId: me, clientId: clientId, sendState: .sending)
            pending.text = caption
            repo.addPending(pending)
        }

        // Per-send HD button OR the global Sent Media Quality "High" → 1080p.
        //
        // AND IF THAT COMES OUT TOO BIG, GO AGAIN AT STANDARD RATHER THAN REFUSING TO SEND.
        //
        // Our "compression" can make a file BIGGER than the one it started with. A modern iPhone
        // records HEVC; the export writes H.264, which is roughly half as efficient. So at 1080p the
        // output can exceed the input — the owner's 18 second clip was a 23.7 MB HEVC source at 60fps
        // and came back over the 25 MB storage limit, which refused it with a message about
        // "permission" that named neither size nor quality.
        //
        // Telling somebody their video is too large when we could simply have sent it smaller is a
        // bad answer. Standard is 540p, which for the same clip is a few megabytes.
        let wantHD = hd || ChatService.highQualitySends
        var exported = await VideoTranscoder.prepare(url, hd: wantHD)
        if wantHD, let big = exported, big.data.count > Limits.videoMessageBytes {
            print("sendVideo: HD export was \(big.data.count / 1_048_576)MB, over the limit — retrying at standard")
            exported = await VideoTranscoder.prepare(url, hd: false)
        }
        guard let prepared = exported else {
            try? FileManager.default.removeItem(at: url)
            // The bubble is already on screen, so a failure has to be shown ON it. Before this the
            // function could return with only an alert, which would have been correct when nothing
            // had been drawn yet and is not correct now.
            await MainActor.run { repo.markFailed(clientId: clientId); sendError = "Couldn't process this video." }
            return
        }
        try? FileManager.default.removeItem(at: url)
        guard prepared.data.count <= Limits.videoMessageBytes else {
            await MainActor.run {
                repo.markFailed(clientId: clientId)
                // Says the actual size it reached, because "too long" was misleading: the owner's
                // clip was 18 seconds. Length is not what fails, weight is, and a 60fps 1080p clip
                // is heavy at any length. By the time this shows, the standard-quality retry above
                // has already been tried, so there is genuinely nothing smaller left to offer.
                sendError = "This video is \(prepared.data.count / 1_048_576) MB, and the most that can be sent is \(Limits.videoMessageBytes / 1_048_576) MB. Try a shorter clip."
            }
            return
        }
        // Persist the transcoded bytes to tmp keyed by clientId so a FAILED send can retry the REAL
        // video (the old retry path only had the thumbnail and re-sent it as a photo — data loss).
        let retryURL = FileManager.default.temporaryDirectory.appendingPathComponent("pending-video-\(clientId).mp4")
        try? prepared.data.write(to: retryURL)
        await MainActor.run { repo.attachRetryPayload(clientId: clientId, path: retryURL.path) }
        do {
            try await ChatService.sendVideo(cid: cid, video: prepared.data, thumbnail: prepared.thumbnail,
                                            duration: prepared.duration, width: prepared.width, height: prepared.height,
                                            caption: caption, clientId: clientId, group: isGroup ? groupMembers : nil)
            try? FileManager.default.removeItem(at: retryURL)   // delivered → retry payload no longer needed
        } catch {
            // SAY WHY. This used to swallow the error and leave the bubble reading "Not delivered"
            // with no reason anywhere — which is a dead end for the person sending (they cannot tell
            // whether to retry, wait for signal, or give up) and a dead end for anyone trying to fix
            // it, since the one fact that would identify the cause was thrown away at the moment it
            // was known. An 18s clip failing while a 7s clip in the same chat minutes later
            // succeeded is exactly the case this silence made impossible to diagnose.
            print("sendVideo failed:", error)
            await MainActor.run {
                repo.markFailed(clientId: clientId)
                sendError = "Couldn't send the video. \(error.localizedDescription)"
            }
        }
    }

    // When I've blocked this contact, the composer is replaced by an unblock bar —
    // you genuinely can't send while blocked (real enforcement, not cosmetic).
    // Top search bar: rounded field with inline clear + a circular X to close search.
    private var searchBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 16)).foregroundStyle(.secondary)
                TextField("Search", text: $searchQuery)
                    .font(.system(size: 17))   // native search-field text
                    .focused($searchFocused)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                    .onChange(of: searchQuery) { _, _ in updateSearchMatches() }
                if !searchQuery.isEmpty {
                    Button { searchQuery = "" } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 16)).foregroundStyle(.secondary)
                            // 32pt real target + contentShape: the bare 16pt glyph was nearly impossible
                            // to hit (only opaque pixels hit-test without a contentShape).
                            .frame(width: 32, height: 32).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12).frame(height: 44)   // substantial native search field (matches the X)
            .liquidGlass(Capsule(), interactive: false)
            Button { closeSearch() } label: {
                Image(systemName: "xmark").font(.system(size: 17, weight: .semibold)).foregroundStyle(.primary)
                    .frame(width: 44, height: 44).liquidGlass(Circle(), interactive: true)   // 44pt Apple tap target
                    // Whole circle is the tap target — without a contentShape only the thin ✕ glyph
                    // hit-tested, so taps on the glass circle fell through ("X not working").
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 8)
    }

    // Bottom bar shown during search (replaces the composer, sits above the keyboard): ↑/↓ through
    // matches + a count.
    private var searchNavBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 24) {
                Button { stepSearch(-1) } label: { Image(systemName: "chevron.up").font(.system(size: 16, weight: .semibold)) }
                    .disabled(searchIndex <= 0 || searchMatches.isEmpty)
                Button { stepSearch(1) } label: { Image(systemName: "chevron.down").font(.system(size: 16, weight: .semibold)) }
                    .disabled(searchIndex >= searchMatches.count - 1 || searchMatches.isEmpty)
            }
            .tint(.primary)
            .padding(.horizontal, 18).frame(height: 44)   // 44pt Apple tap target, matches the close X
            .liquidGlass(Capsule(), interactive: true)
            Spacer()
            if !searchMatches.isEmpty || !searchQuery.isEmpty {
                // Same rounded glass pill as the up/down arrow nav (same height / corner / background),
                // text centered. It's a status label, so the glass is non-interactive; search logic unchanged.
                Text(searchMatches.isEmpty ? "No results" : "\(searchIndex + 1) of \(searchMatches.count)")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .padding(.horizontal, 18).frame(height: 44)
                    .liquidGlass(Capsule(), interactive: false)
            }
        }
        .padding(.horizontal, 16).padding(.bottom, 6)
    }

    // Bottom action bar during selection (reference design): Delete (glass circle, leading), "N Selected"
    // (glass pill, centre), Forward (glass circle, trailing) — all real Liquid Glass, icons only.
    private var selectionActionBar: some View {
        HStack {
            Button { showBulkDeleteConfirm = true } label: {
                Image(systemName: "trash").font(.system(size: 18)).foregroundStyle(.red)
                    .frame(width: 48, height: 48).liquidGlass(Circle(), interactive: true)
                    .contentShape(Circle())   // whole circle is the tap target, not just the icon
            }
            .buttonStyle(.plain).disabled(selectedIds.isEmpty)
            Spacer()
            Text("\(selectedIds.count) Selected").font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                .padding(.horizontal, 22).frame(height: 44).liquidGlass(Capsule(), interactive: false)
            Spacer()
            Button { bulkForwardStart() } label: {
                Image(systemName: "arrowshape.turn.up.right").font(.system(size: 18)).foregroundStyle(.primary)
                    .frame(width: 48, height: 48).liquidGlass(Circle(), interactive: true)
                    .contentShape(Circle())   // whole circle is the tap target, not just the icon
            }
            // Off unless EVERY pick can be forwarded. See selectionIsForwardable for why the earlier
            // "any of them" reading was wrong. Tombstones, calls and system rows all switch it off.
            .buttonStyle(.plain).disabled(!selectionIsForwardable)
        }
        .padding(.horizontal, 20).padding(.bottom, 4)
    }

    /// ONE SHAPE FOR EVERY BAR THAT STANDS IN FOR THE COMPOSER.
    ///
    /// Owner: "dont use that Border design, use Apple design, follow apple and liquid glass… all
    /// redesign". Every one of these used `.background(.bar)`, a full-width system strip pinned to
    /// the bottom edge with a hairline along its top — the outlined slab he circled. It is the one
    /// thing on this screen that did not look like the rest of the app: the composer floats over the
    /// conversation as glass, the selection bar is a glass capsule, and then these arrived as a flat
    /// bordered panel.
    ///
    /// They are glass now, in the composer's own shape and its own inset, so swapping between typing
    /// and any of these states changes the words and nothing else about the furniture.
    private func composerNotice<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .liquidGlass(RoundedRectangle(cornerRadius: 26, style: .continuous))
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
    }

    private var blockedBar: some View {
        composerNotice {
            VStack(spacing: 6) {
                Text("You blocked \(title)").font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                Button("Unblock") { Task { await ChatService.setBlocked(cid, false) } }
                    .font(.subheadline.weight(.semibold))
                    .tint(.red)
            }
        }
    }

    // A group I'm no longer in (removed by an admin, or left on another device): the conv is
    // still cached but I'm not in `users`. Show a non-interactive bar instead of the composer.
    private var notAMember: Bool {
        guard !cid.contains("_") else { return false }       // 1:1 chats are never "removed"
        guard let conv = conversation else { return false }  // not loaded yet → don't assume
        return !conv.users.contains(AuthService.shared.uid ?? "")
    }

    private var removedBar: some View {
        composerNotice {
            Text("You're no longer a member of this group")
                .font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
        }
    }

    // Announcement mode: a non-admin member can't send (enforced server-side too).
    private var cannotSendAnnouncement: Bool {
        guard let conv = conversation, conv.isGroup else { return false }
        return !conv.canSend(AuthService.shared.uid ?? "")
    }

    private var announcementBar: some View {
        composerNotice {
            Label("Only admins can send messages", systemImage: "megaphone")
                .font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
        }
    }

    // A member an admin has restricted (reference-style timed mute) can't send until it expires.
    private var iAmMuted: Bool {
        guard let conv = conversation, conv.isGroup else { return false }
        return conv.isMutedMember(AuthService.shared.uid ?? "", now: Date().timeIntervalSince1970 * 1000)
    }

    private var restrictedBar: some View {
        composerNotice {
            Label("You're muted in this group", systemImage: "speaker.slash")
                .font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
        }
    }

    // Do we already share this chat (either side has sent something)? If so, messaging
    // always stays open — the Messages-privacy gate only blocks COLD new chats.
    private var hasChatHistory: Bool {
        // An ACCEPTED conversation is the whole definition of "we have talked", and it is the same
        // test the rules make. It used to be "any message exists", which under message requests would
        // have let a stranger's own unanswered request count as history and unlock the very gate it
        // was supposed to be waiting behind.
        if let c = conversation, !c.startedBy.isEmpty { return c.accepted }
        return !(conversation?.lastMessageCipher ?? "").isEmpty
            || repo.items.contains { !$0.text.isEmpty || $0.isImage || $0.isVideo || $0.isAudio || $0.isFile || $0.isGif }
    }

    /// Where this conversation stands as a message request. One value; see [MessageRequests].
    private var requestStance: MessageRequests.Stance {
        guard !isGroup, let c = conversation else { return .open }
        return MessageRequests.stance(c, myUid: me)
    }

    /// THEIR request, waiting for me. Accept or Delete, in the conversation itself — his spec was
    /// explicit that there is no separate requests inbox to go and find.
    private var requestBar: some View {
        composerNotice {
            VStack(spacing: 10) {
                // ONE LINE, his reference's wording. Who is asking, and their picture, are now the card
                // at the top of the conversation — saying the name again down here, plus a sentence
                // explaining what two labelled buttons already say, was three lines to answer yes or no.
                Text("Accept message request from \(title)?")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                HStack(spacing: 10) {
                    Button {
                        Task { try? await MessageRequests.decline(cid); dismiss() }
                    } label: {
                        Text("Delete").font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity).frame(height: 44)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
                    .liquidGlass(Capsule(), interactive: true)

                    Button {
                        Task { try? await MessageRequests.accept(cid) }
                    } label: {
                        Text("Accept").font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity).frame(height: 44)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    // TINTED GLASS, not a flat accent fill. Beside a glass Delete, a solid capsule
                    // read as a different material from a different app — and in light mode it
                    // photographed as a hard black slab. Apple's own tint keeps it clearly the
                    // primary action while both buttons stay the same substance.
                    .liquidGlass(Capsule(), interactive: true, tint: Color.accentColor)
                }
            }
        }
    }

    /// MY request, unanswered. One message is the whole allowance, so there is nothing to type into —
    /// a live composer here would only let someone write a second message and watch it fail.
    private var awaitingReplyBar: some View {
        composerNotice {
            VStack(spacing: 3) {
                Label("Message request sent", systemImage: "paperplane")
                    .font(.subheadline.weight(.semibold))
                Text("You can send another message once \(title) replies.")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    // The other person's Messages privacy (Settings > Privacy > Messages). "My Contacts" /
    // "No One" blocks me from starting a NEW chat with them if we've never talked. Enforced
    // here on the sender's client; existing chats are unaffected.
    private var cannotMessageThem: Bool {
        guard !isGroup, !repo.iBlocked else { return false }
        let audience = Audience(rawValue: repo.otherPrivacy["messages"] ?? "") ?? .everyone
        if audience == .everyone { return false }
        return !hasChatHistory
    }

    private var cannotMessageBar: some View {
        composerNotice {
            VStack(spacing: 3) {
                Label("You can't message \(title)", systemImage: "lock.fill")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                // "Their contacts" named something this app does not have, the same mistake the
                // Settings audit found in the auto-archive footer. The audience this reads is
                // Everyone or My Friends, and only the second one lands you here.
                Text("They only accept messages from their friends.")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    // The reply preview now nests INSIDE the input capsule (see inputRow).
    private var composerArea: some View {
        composer
            // LINK DETECTION while typing (debounced): resolve the first https link into a draft
            // preview card. Cleared when the text no longer holds a link; the X suppresses one URL.
            .onChange(of: input) { old, text in
                linkDetectTask?.cancel()
                guard let url = LinkPreviewService.firstURL(in: text) else {
                    if linkDraft != nil { withAnimation(.easeInOut(duration: 0.2)) { linkDraft = nil } }
                    suppressedLinkUrl = nil
                    return
                }
                if url.absoluteString == suppressedLinkUrl { return }
                if url == linkDraft?.url { return }
                // A PASTE arrives whole and complete, so there is nothing to wait for and the debounce
                // was pure dead time before the card appeared (owner report: "the preview is late").
                // TYPING still needs it, or every keystroke fires a fetch at a half-written url. The
                // jump in length is what separates them: a keystroke moves it by one.
                let pasted = text.count - old.count > 1
                linkDetectTask = Task {
                    if !pasted { try? await Task.sleep(nanoseconds: 400_000_000) }   // let typing settle
                    guard !Task.isCancelled else { return }
                    let d = await LinkPreviewService.shared.draft(for: url)
                    guard !Task.isCancelled, let d else { return }
                    await MainActor.run {
                        // The text may have changed while fetching — only show a still-current link.
                        guard LinkPreviewService.firstURL(in: input) == url else { return }
                        withAnimation(.easeInOut(duration: 0.2)) { linkDraft = d }
                    }
                }
            }
    }

    // The composer's draft card (user reference: the reference app shows the preview BEFORE sending):
    // thumb + title + description + domain, X to send without a preview.
    private func linkDraftRow(_ d: LinkPreviewService.LinkDraft) -> some View {
        HStack(spacing: 10) {
            if let img = d.image {
                Image(uiImage: img).resizable().scaledToFill()
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(d.title).font(.caption.weight(.semibold)).lineLimit(1)
                if !d.desc.isEmpty {
                    Text(d.desc).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Text(d.host).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    suppressedLinkUrl = d.url.absoluteString
                    linkDraft = nil
                }
            } label: {
                Image(systemName: "xmark.circle.fill").font(.system(size: 20)).foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 14).padding(.trailing, 12).padding(.vertical, 8)
    }

    // Active-reply preview row, shown inside the input capsule above the text field.
    private func replyPreviewRow(_ r: Message) -> some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 1.5).fill(Color.accentColor).frame(width: 3, height: 34)
            // Real media thumbnail when replying to a photo / GIF / video.
            if r.isImage, let url = r.imageUrl {
                SecureImageView(imageUrl: url, enc: r.enc, cid: cid)
                    .frame(width: 36, height: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            } else if r.isGif, let url = r.imageUrl {
                AnimatedGifView(url: url)
                    .frame(width: 36, height: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            } else if r.isVideo, let url = r.thumbUrl {
                SecureImageView(imageUrl: url, enc: r.thumbEnc, cid: cid)
                    .frame(width: 36, height: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Reply to \(r.authorId == me ? "yourself" : personName(r.authorId))")
                    .font(.caption.weight(.semibold)).foregroundStyle(Color.accentColor)
                replyContentPreview(r)
            }
            Spacer(minLength: 8)
            Button { withAnimation(.easeInOut(duration: 0.2)) { replyingTo = nil } } label: {
                Image(systemName: "xmark.circle.fill").font(.system(size: 20)).foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 14).padding(.trailing, 12).padding(.vertical, 8)
        // Consume taps so they don't fall THROUGH the (partly transparent) reply bar to the photo bubble
        // behind it (the X button keeps its own tap).
        .contentShape(Rectangle())
        .onTapGesture { }
    }

    // Inline edit preview: pencil + "Edit Message" + snippet + cancel (X).
    private func editPreviewRow(_ e: Message) -> some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 1.5).fill(Color.accentColor).frame(width: 3, height: 34)
            Image(systemName: "pencil").font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("Edit Message").font(.caption.weight(.semibold)).foregroundStyle(Color.accentColor)
                Text(e.text).font(.caption).lineLimit(1).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button { cancelEdit() } label: {
                Image(systemName: "xmark.circle.fill").font(.system(size: 20)).foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 14).padding(.trailing, 12).padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture { }
    }

    private func cancelEdit() {
        withAnimation(.easeInOut(duration: 0.2)) { editingMessage = nil }
        setInputSilently(Drafts.shared.text(cid))   // bring back whatever was drafted before the edit began (no phantom typing)
        inputFocused = false
    }

    // Save the inline edit, then clear the edit state (replaces the old full-screen sheet).
    private func saveEdit() {
        guard let e = editingMessage else { return }
        let newText = input.trimmingCharacters(in: .whitespacesAndNewlines)
        // Empty text = cancel the edit (an edit can't erase a message) — the old silent return
        // left the composer STUCK in edit mode with no way out.
        // Unchanged text = nothing to save; just leave edit mode.
        if !newText.isEmpty && newText != e.text {
            Task { try? await ChatService.editMessage(cid: cid, messageId: e.id, newText: newText, group: isGroup ? groupMembers : nil) }
        }
        withAnimation(.easeInOut(duration: 0.2)) { editingMessage = nil }
        setInputSilently(Drafts.shared.text(cid))   // the pre-edit draft (if any) was never sent — restore it (no phantom typing)
        inputFocused = false
    }

    // The actual replied content: waveform for voice, "Photo" for images, the text/emoji otherwise.
    @ViewBuilder private func replyContentPreview(_ r: Message) -> some View {
        if r.isAudio {
            HStack(spacing: 6) {
                Image(systemName: "mic.fill").font(.system(size: 11)).foregroundStyle(.secondary)
                WaveformBars(bars: r.waveform.isEmpty ? Array(repeating: 30, count: 16) : Array(r.waveform.prefix(28)),
                             progress: 0, played: Color.secondary, unplayed: Color.secondary.opacity(0.5)) { _ in }
                    .frame(width: 72, height: 14)
                Text(replyVoiceDuration(r)).font(.caption2).foregroundStyle(.secondary)
            }
        } else if r.isAlbum {
            let n = r.album.isEmpty ? r.localAlbum.count : r.album.count
            HStack(spacing: 4) {
                Image(systemName: "photo.on.rectangle").font(.system(size: 11)).foregroundStyle(.secondary)
                Text(r.text.isEmpty ? "\(n) Photos" : r.text).font(.caption).lineLimit(1).foregroundStyle(.secondary)
            }
        } else if r.isImage {
            Text(r.viewOnce ? "View-once photo" : "Photo").font(.caption).foregroundStyle(.secondary)
        } else if r.isGif {
            Text("GIF").font(.caption).foregroundStyle(.secondary)
        } else if r.isCall {
            // A call carries no text at all, so the banner drew an empty line under the name until
            // this branch existed. Its own glyph, like the file and voice rows above.
            HStack(spacing: 4) {
                Image(systemName: r.callVideo ? "video.fill" : "phone.fill")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Text(r.callVideo ? "Video call" : "Voice call")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } else if r.isVideo {
            Text("Video").font(.caption).foregroundStyle(.secondary)
        } else if r.isFile {
            HStack(spacing: 4) {
                Image(systemName: "doc.fill").font(.system(size: 11)).foregroundStyle(.secondary)
                Text(r.fileName ?? "File").font(.caption).lineLimit(1).foregroundStyle(.secondary)
            }
        } else {
            // quoteSafeLabel: a contact/location card's text is a raw kulan-…: marker (uid + storage
            // URL) — the live banner must show "Contact"/"Location", never the payload.
            Text(quoteSafeLabel(r.text)).font(.caption).lineLimit(1).foregroundStyle(.secondary)
        }
    }
    private func replyVoiceDuration(_ r: Message) -> String {
        let d = Int(r.duration ?? 0); return String(format: "%d:%02d", d / 60, d % 60)
    }

    // Subtle neutral fill (no glass, no shadow) — the native field tint.
    private var fieldFill: Color { dark ? Color(hex: 0x2A2A2E) : Color(hex: 0xEEEEF2) }

    // True while the finger is held down recording (not yet locked).
    // Driven by holdStarted (set on touch-down) NOT recorder.isRecording, so the recording
    // UI appears the instant you press — no waiting for the audio session to warm up.
    private var recordingHeld: Bool { holdStarted && !recordLocked }
    // Live finger translation, clamped to up/left (the two meaningful directions).
    private var clampedDrag: CGSize {
        // Rubber-band the visual mic offset: 1:1 up to the lock/cancel limit, then diminishing
        // resistance past it (the UIScrollView overscroll curve) so it feels physical, not hard-clamped.
        CGSize(width: Self.rubberband(recordDrag.width, limit: 90),
               height: Self.rubberband(recordDrag.height, limit: 100))
    }
    // iOS overscroll: within `limit` it's linear; beyond, r = limit + (1 − 1/(over·c/dim + 1))·dim.
    private static func rubberband(_ x: CGFloat, limit: CGFloat, dim: CGFloat = 220, c: CGFloat = 0.55) -> CGFloat {
        guard x < 0 else { return 0 }          // only up/left drags move the mic
        let d = -x
        if d <= limit { return x }
        let over = d - limit
        return -(limit + (1 - 1 / (over * c / dim + 1)) * dim)
    }

    /// THE PLATFORM'S OWN MODEL, not a number measured to the glass (owner, build 443: "sit
    /// naturally on the safe area, just like the reference app, rather than floating above it").
    ///
    /// Read out of the reference app's ConversationInputToolbar, which is the closest open implementation of the
    /// convention the reference app follows. Two things define it:
    ///
    ///   contentView.bottomAnchor.constraint(equalTo: bottomAnchor)   // the BAR's bottom, not the
    ///                                                                // safe area's
    ///   vMargin: 0.5 * (initialToolbarHeight - initialTextBoxHeight) // 0.5 * (56 - 40) = 8
    ///
    /// So the BAR's bottom edge rests on the safe area line and the system's inset is what lifts it
    /// clear of the home indicator; inside the bar the pill is centred, which leaves 8pt under it.
    /// `safeAreaBar` already does the first half for us, so the whole of our side is that 8.
    ///
    /// THE DEVICE-SPECIFIC PART IS THAT THERE ISN'T ONE, and that is the point of doing it this way.
    /// The previous version subtracted the device's inset to hit a fixed distance from the glass,
    /// which meant carrying our own idea of what every iPhone needs. Here iOS supplies it: 34pt of
    /// lift on an indicator phone, none on a Home-button one, and the 8 sits on top of whatever that
    /// is. Nothing to keep in step with new hardware.
    ///
    /// The keyboard case is the same 8, and now for a reason rather than by exception: up there the
    /// bar rides the keyboard, which is simply a different edge to rest on.
    private var composerBottomGap: CGFloat { 8 }

    private var composer: some View {
        VStack(spacing: 6) {
            if !mentionCandidates.isEmpty { mentionPicker }
            Group {
                if recordLocked { lockedRecordingBar } else { inputRow }
            }
        }
        // 24 at rest, 16 once the keyboard is up (owner 2026-08-02). The composer gets a little wider
        // exactly when you are typing into it, which is the moment the field needs the room.
        .padding(.horizontal, inputFocused ? 16 : 24)
        .padding(.top, 6)
        .padding(.bottom, composerBottomGap)
        // Both margins move with the focus, so they ride the keyboard's own curve instead of snapping
        // a frame before or after it.
        .animation(.easeOut(duration: 0.25), value: inputFocused)
        .overlay(alignment: .top) {
            if holdHint {
                Text("Hold to record, release to send")
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.black.opacity(0.8), in: Capsule())
                    .offset(y: -8)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            // The reference's little confirmation when the "1" is armed, in OUR notice style —
            // appears over the bar and goes by itself, same rhythm as the hold hint above.
            if voiceOnceToast {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 14))
                    Text("Set to one-time listen").font(.system(size: 13, weight: .medium))
                }
                .modifier(ChatNoticePill())
                .offset(y: -8)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        // Big red mic + lock, ON TOP of the whole composer so it's never clipped/behind the pill.
        .overlay(alignment: .bottomTrailing) {
            if recordingHeld { recordingMicOverlay }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: recordLocked)
    }

    // @-mention autocomplete shown above the input while typing "@" in a group.
    private var mentionPicker: some View {
        VStack(spacing: 0) {
            ForEach(mentionCandidates.prefix(5), id: \.uid) { c in
                Button { insertMention(c.uid, c.name) } label: {
                    HStack(spacing: 10) {
                        AvatarView(name: c.name, photoUrl: conversation?.photos[c.uid], size: 30)
                        Text(c.name).foregroundStyle(.primary).lineLimit(1)
                        VerifiedMark(uid: c.uid, size: 12)
                        Spacer()
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var inputRow: some View {
        // CRITICAL: the glass container's `grouped` flag must NOT depend on recordingHeld. When it
        // flipped on record-start, SwiftUI swapped GlassEffectContainer <-> plain content, which
        // re-created the entire subtree — destroying the mic's live DragGesture mid-touch (the
        // frozen/stuck recording). Kept constant, the subtree is stable and the gesture survives.
        // (No blur bridge now: the recording mic is a red circle, not a glass element.)
        composerGlassContainer(grouped: true) {
        HStack(alignment: .bottom, spacing: 8) {   // "+" outside-left; the field (with the mic INSIDE); Send
            // Hidden ENTIRELY while recording (the attach button is removed from the
            // toolbar during a voice memo). Collapsing via opacity/frame did NOT work — iOS 26's
            // native glassEffect ignores .opacity, so the "+" kept showing. Fully removing it is the
            // reliable fix; the mic is a separate stable slot (its own .id), so this sibling change
            // can't disturb the recording gesture.
            if !recordingHeld {
                Button {
                    // Fully resign the composer keyboard BEFORE opening the sheet, so iOS doesn't remember
                    // it as first responder and briefly RESTORE the keyboard when the sheet closes (the
                    // flash before the image editor opens).
                    let keyboardWasUp = inputFocused
                    inputFocused = false
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    if keyboardWasUp {
                        // Let the keyboard-HIDE animation start first: presenting in the same instant made
                        // iOS serialize the animations (sheet first), so the chat + composer stayed lifted
                        // at keyboard height under the open sheet and only settled once the presentation
                        // finished (the "still up, closes late" report). A few frames later, both run
                        // concurrently — keyboard slides down while the sheet slides up.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { showAttachPanel = true }
                    } else {
                        showAttachPanel = true
                    }
                } label: {
                    Image(systemName: sendingPhoto ? "ellipsis" : "plus")
                        .font(.system(size: 20, weight: .regular))
                        .foregroundStyle(.primary)
                        .contentTransition(.symbolEffect(.replace))   // smooth +/… swap
                        .frame(width: 40, height: 40)
                        .liquidGlass(Circle(), interactive: true)
                }
                .tint(.primary)
                .transition(.scale.combined(with: .opacity))   // smooth fade/scale out when recording starts
            }

            // The field holds reply preview + text/record row, with the camera kept INSIDE
            // on the right. The mic/send live OUTSIDE as a standalone right sibling (like "+").
            VStack(spacing: 0) {
                // Reply preview spans the FULL field width (so the X sits at the far right).
                if let r = replyingTo, !recordingHeld {
                    replyPreviewRow(r)
                        .transition(.move(edge: .top).combined(with: .opacity))
                    Divider().padding(.horizontal, 12)
                }
                if let e = editingMessage, !recordingHeld {
                    editPreviewRow(e)
                        .transition(.move(edge: .top).combined(with: .opacity))
                    Divider().padding(.horizontal, 12)
                }
                // Link-preview draft rides the same slot as the reply preview (reference behaviour).
                if let d = linkDraft, !recordingHeld, editingMessage == nil {
                    linkDraftRow(d)
                        .transition(.move(edge: .top).combined(with: .opacity))
                    Divider().padding(.horizontal, 12)
                }
                HStack(alignment: .bottom, spacing: 4) {
                    // Field content swaps between the text field and the recording bar…
                    if recordingHeld { recordingHoldRow } else { messageField }
                    // …sticker + camera show only when idle & empty…
                    if !recordingHeld && !hasText { inFieldGif; inFieldCamera }
                    // …and the MIC lives INSIDE the pill (clean idle: sticker · camera · mic in one bar).
                    // ONE stable slot gated by !hasText (unchanged during a recording) + a stable .id so
                    // the DragGesture survives record-start; zIndex keeps the red circle in front of the
                    // pill glass. The red is sized to FIT the 40px bar, so it never overflows/clips.
                    if !hasText { micButton.id("record-mic").zIndex(1) }
                }
                .frame(minHeight: 40)   // input row stays 40px even in voice mode
            }
            // Real Liquid Glass on the field in BOTH states — including the recording bar (user spec).
            // Interactive Liquid Glass restored (the field looked flat without it). Hold-to-record
            // speed is kept up by the snappy record-start animation + the pre-warmed audio session.
            .liquidGlass(RoundedRectangle(cornerRadius: 20, style: .continuous), interactive: true)

            // Send button (only while typing) — the mic lives INSIDE the pill now.
            rightButton
        }
        }
        .animation(.easeInOut(duration: 0.2), value: hasText)
        // Snappy so the recording bar appears near-instantly on hold (was 0.3s -> read as lag).
        .animation(.spring(response: 0.14, dampingFraction: 0.9), value: recordingHeld)
    }

    // Native iOS 26: group the composer's glass shapes (the + and the field) so they
    // render as ONE cohesive liquid-glass system, the way Apple's own bars do — instead
    // of two disconnected glass blobs. No-op layout-wise; pure native glass rendering.
    @ViewBuilder private func composerGlassContainer<C: View>(grouped: Bool = true, @ViewBuilder _ content: () -> C) -> some View {
        if grouped, #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: 8) { content() }
        } else {
            content()
        }
    }

    // Just the text field — trailing buttons are stable siblings (so the mic view never
    // unmounts when the field swaps to the recording row mid-hold).
    private var messageField: some View {
        TextField(requestStance == .firstMessage ? "Say hello" : "Message", text: $input, axis: .vertical)
            .font(.system(size: 17))
            .lineLimit(1...6)
            .focused($inputFocused)
            .padding(.leading, 14)
            .padding(.vertical, 9)   // single-line field height ~40 to match the + button
            .onChange(of: input) { _, v in
                // A first message to a stranger is capped. Trimmed as it is typed rather than
                // refused on send, so you can see the limit instead of losing what you wrote to it.
                if requestStance == .firstMessage, v.count > MessageRequests.firstMessageLimit {
                    input = String(v.prefix(MessageRequests.firstMessageLimit))
                    return
                }
                // Programmatic set (draft restore / edit teardown) — no typing implications (audit M6).
                if typingBox.suppressNext { typingBox.suppressNext = false; return }
                // Don't broadcast "typing" while we're seeding the field for an inline EDIT.
                let now = editingMessage == nil && !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                if now != typingSent {
                    typingSent = now
                    broadcastTyping(now)   // serialized — writes can't land out of order
                    // Receivers self-clear at 15s and composing produces no doc changes — the 10s
                    // refresh (a changing "text-<seconds>" value) keeps a long burst alive (audit).
                    typingBox.typingRefresh?.invalidate(); typingBox.typingRefresh = nil
                    if now {
                        typingBox.typingRefresh = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
                            broadcastTyping(true)
                        }
                    }
                }
                // Idle pause timer: typing auto-stops after 3s of no keystrokes (even with text still
                // in the field), so a parked draft doesn't show "typing…" forever on the other side.
                typingIdleStop?.cancel()
                if now {
                    let work = DispatchWorkItem {
                        guard typingSent else { return }
                        typingSent = false
                        broadcastTyping(false)
                        typingBox.typingRefresh?.invalidate(); typingBox.typingRefresh = nil
                    }
                    typingIdleStop = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
                }
            }
    }

    // Camera lives INSIDE the field (right), only when not typing/recording.
    // Solid, high-contrast icon (.primary = white in dark / black in light, 100% opacity) in a
    // a 40x40 tap target.
    private var inFieldCamera: some View {
        Button {
            // Same as "+": fully resign the keyboard BEFORE presenting, or iOS remembers the field
            // as first responder and flashes the keyboard back when the cover closes.
            inputFocused = false
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            showCamera = true
        } label: {
            Image("ic_camera").renderingMode(.template).resizable().scaledToFit()
                .frame(width: 24, height: 24).foregroundStyle(.primary)
                .frame(width: 40, height: 40)
        }
    }
    // One-tap GIFs from the field (big apps keep GIFs next to the camera, not buried in +).
    private var inFieldGif: some View {
        Button {
            // Same as "+": resign the keyboard first so it doesn't flash back after the picker.
            inputFocused = false
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            showGifPicker = true
        } label: {
            Image("ic_gif").renderingMode(.template).resizable().scaledToFit()
                .frame(width: 24, height: 24).foregroundStyle(.primary)
                .frame(width: 40, height: 40)
        }
    }

    // Standalone SEND button OUTSIDE the field (like "+"), only while typing. When not typing the
    // mic lives INSIDE the pill (next to sticker/camera), so there's no outside button then.
    @ViewBuilder private var rightButton: some View {
        if hasText {
            Button { if editingMessage != nil { saveEdit() } else { send() } } label: {
                Image(systemName: editingMessage != nil ? "checkmark" : "arrow.up")
                    .font(.system(size: 19, weight: .bold))
                    // Matches the bubble: white glyph on the chosen chat colour, or on the default systemBlue.
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    // Real Liquid Glass, tinted to MATCH the bubble colour (the chosen chat colour / default).
                    .liquidGlass(Circle(), interactive: true, tint: chatColorSpec?.swatch ?? Theme.defaultBubble(dark))
                    .contentTransition(.symbolEffect(.replace))
            }
            .transition(.scale.combined(with: .opacity))
        }
        // When not typing, the mic is INSIDE the pill (see the field row) — no button here.
    }

    // Live recording row inside the capsule: red dot + timer + "‹ slide to cancel".
    private var recordingHoldRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "mic.fill")
                .font(.system(size: 18)).foregroundStyle(.red)
                .symbolEffect(.pulse, options: .repeating)   // gentle live pulse
            RecordTimerText(recorder: recorder)
            Spacer(minLength: 8)
            HStack(spacing: 3) {
                Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold))
                Text("Slide to cancel").font(.system(size: 15))
            }
            .foregroundStyle(recordCancelArmed ? Color.red : Color.secondary)
            .animation(.easeInOut(duration: 0.15), value: recordCancelArmed)
            // Fade the hint as the finger slides toward the cancel threshold.
            .opacity(1.0 - min(1.0, Double(-clampedDrag.width) / 90.0) * 0.6)
            // Second Spacer: the hint sits CENTRED in the bar the way the reference draws it,
            // instead of hugging the trailing edge.
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 14).frame(height: 40)   // strict 40px during recording — no vertical distortion
    }

    // Hold-to-record (standard hold-to-record, our own code on the AudioRecorder engine):
    //   • press & hold the mic  → recording starts instantly (session is pre-warmed)
    //   • slide LEFT past the threshold, release → cancel (discard)
    //   • slide UP into the lock target → hands-free lock (finger can lift; bar takes over)
    //   • release without cancel/lock → send
    // Rubber-banded drag + haptics at each threshold. A quick tap (too short) flashes the hint.
    private static let cancelThreshold: CGFloat = 80
    private static let lockThreshold: CGFloat = 88
    private var lockProgress: CGFloat { min(1, max(0, -clampedDrag.height / Self.lockThreshold)) }

    // In-pill mic: the small idle icon (matches sticker/camera) AND the drag gesture's hit target.
    // While recording it's invisible (opacity 0) — the BIG red mic is drawn by `recordingMicOverlay`
    // on top of the whole composer, so it's never clipped by / behind the pill's glass. The gesture
    // still lives here (opacity doesn't affect hit-testing), keeping a stable identity (no freeze).
    private var micButton: some View {
        Image("ic_mic")
            .renderingMode(.template).resizable().scaledToFit()
            .foregroundStyle(.primary)                     // solid white (dark) / black (light)
            .frame(width: 22, height: 24)
            .frame(width: 40, height: 40)                  // 40x40 tap target
            .opacity(recordingHeld ? 0 : 1)
            // Instant UIKit hold gesture (minimumPressDuration 0) — fires on touch-down, no SwiftUI
            // arbitration lag. Overlay stays mounted during recording so it keeps tracking the drag.
            .overlay {
                HoldToRecordView(
                    onBegan: { beginHoldRecording() },
                    onChanged: { t in updateHoldRecording(t) },
                    onEnded: { t, cancelled in endHoldRecording(t, cancelled: cancelled) }
                )
            }
            .padding(.trailing, 4)                         // last icon 4pt from the bar edge
    }

    private func beginHoldRecording() {
        guard !holdStarted, !recordLocked else { return }
        // A live call OWNS the microphone. CallKit holds the audio session in manual mode and WebRTC has
        // the mic hot, so starting a recording here would either capture nothing or fight the call for the
        // session - and the user would only find out afterwards, from a silent voice note. Say so instead.
        if CallService.shared.state != .idle && CallService.shared.state != .ended {
            recordingBlockedByCall = true
            return
        }
        // Permission already DENIED: don't flip into the recording UI (nothing would be captured —
        // the bar ran with a frozen 0:00). Point the user at Settings instead. A first-ever hold
        // (undetermined) still falls through to requestAndStart(), which shows the system prompt.
        if AVAudioApplication.shared.recordPermission == .denied {
            micDenied = true
            return
        }
        holdStarted = true
        holdBeganAt = Date()
        recorder.requestAndStart()
        impact(.medium)
    }

    private func updateHoldRecording(_ t: CGSize) {
        guard holdStarted, !recordLocked else { return }
        recordDrag = t
        let armed = clampedDrag.width < -Self.cancelThreshold
        if armed != recordCancelArmed { recordCancelArmed = armed; impact(.soft) }
        if clampedDrag.height < -Self.lockThreshold { lockRecording() }
    }

    private func endHoldRecording(_ t: CGSize, cancelled: Bool) {
        guard holdStarted, !recordLocked else { return }   // locked = keep going, the bar owns it
        if cancelled || recordCancelArmed {
            cancelRecording()
        } else if Date().timeIntervalSince(holdBeganAt) < 0.30, abs(t.width) < 10, abs(t.height) < 10,
                  AVAudioApplication.shared.recordPermission == .granted {
            // ^ Permission GRANTED, deliberately NOT `recorder.isRecording`: a cold-started
            // recorder assembles itself asynchronously, so `isRecording` can still be false the
            // instant a real tap's finger lifts — that stricter guard read warm-up as "nothing
            // recording" and flashed the hint (his "sometimes forgets, tap again works" report).
            // With permission granted the recording IS coming, a beat behind the finger, and the
            // locked bar picks it up. A first-ever tap that lands on the permission prompt still
            // falls through to the hint: not granted yet, nothing to lock.
            // TAP TO RECORD HANDS-FREE — his order, and deliberately OUR OWN invention: the standard
            // messengers all flash a "hold to record" hint here (checked against their
            // apps 2026-08-11, in the voice research pass). Recording already started at touch-down,
            // so a quick clean tap simply keeps it running and jumps straight to the locked bar —
            // same destination as slide-to-lock, with no finger held. Measured by WALL CLOCK from
            // touch-down, not `recorder.elapsed`: on a cold audio session record() can lag behind
            // the finger, and a real tap would have read as elapsed 0 and fallen into the hint.
            lockRecording()
        } else if recorder.elapsed < 1.0 {
            // Match AudioRecorder.finish()'s 1.0s floor EXACTLY — a hold under 1s can't produce a note
            // (finish returns nil), so treat it as an accidental tap here instead of "sending" nothing.
            cancelRecording(); flashHoldHint()             // too short → discard + "hold to record"
        } else {
            sendRecording()
        }
    }

    // The BIG red mic + lock pill, rendered as an overlay ON TOP of the composer during recording,
    // aligned over the in-pill mic. Non-interactive (the gesture is on micButton); follows the drag.
    private var recordingMicOverlay: some View {
        ZStack(alignment: .center) {
            // Lock pill floats above, FIXED — the mic slides up to it.
            if !recordCancelArmed {
                lockTarget.offset(y: -86)
            }
            // The big mic under the finger, follows it 1:1. ACCENT, NOT RED — his screenshot of the
            // reference: the button is the chat colour sitting in a soft halo of itself; red is the
            // recording signal on the LEFT of the bar, not the button.
            //
            // THE HALO IS ALIVE — restored, not invented: `3c6674de` built exactly this on his
            // request (a halo that breathes on its own and SWELLS with the live voice level, the
            // reference's blob idea) and it was lost in a later mic rebuild. He asked for it again
            // on 2026-08-11 with the reference open. Two rings at different depths, both riding
            // the recorder's metered level, whose VU ballistics already smooth the motion.
            ZStack {
                let lvl = CGFloat(recorder.levels.last ?? 0)
                Circle().fill(Theme.accent(dark).opacity(0.12))
                    .frame(width: 78, height: 78)
                    .scaleEffect(1.10 + 0.85 * lvl + (micPulse ? 0.08 : 0))
                Circle().fill(Theme.accent(dark).opacity(0.22))
                    .frame(width: 78, height: 78)
                    .scaleEffect(1 + 0.40 * lvl)
                Circle().fill(Theme.accent(dark))
                    .frame(width: 56, height: 56)
                Image("ic_mic").renderingMode(.template).resizable().scaledToFit()
                    .frame(width: 24, height: 28).foregroundStyle(.white)
            }
            .animation(.easeOut(duration: 0.12), value: recorder.levels.last ?? 0)
            .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: micPulse)
            .onAppear { micPulse = true }
            .onDisappear { micPulse = false }
            .offset(x: clampedDrag.width, y: clampedDrag.height)
        }
        .padding(.trailing, 12).padding(.bottom, 0)   // centre over the in-pill mic
        .allowsHitTesting(false)
        .animation(.easeInOut(duration: 0.12), value: recordCancelArmed)
    }

    // Lock target floating above the mic — fills toward accent as you slide up, then locks.
    private var lockTarget: some View {
        VStack(spacing: 7) {
            Image(systemName: lockProgress > 0.7 ? "lock.fill" : "lock.open.fill")
                .font(.system(size: 17, weight: .semibold))
            Image(systemName: "chevron.up")
                .font(.system(size: 13, weight: .bold))
                .opacity(1 - lockProgress)
        }
        .foregroundStyle(.primary)               // native adaptive: black in light mode, white in dark
        .frame(width: 48)                        // bigger 48px pill (spec: looked small)
        .padding(.vertical, 14)
        .liquidGlass(Capsule(), interactive: true)   // real Liquid Glass (spec)
        .scaleEffect(0.92 + lockProgress * 0.12)
    }

    // Locked (hands-free) recording bar.
    /// TWO ROWS NOW — his 2026-08-11 side-by-side of ours against the reference: everything was
    /// packed into one row, so the waveform got whatever width was left after four buttons and
    /// read as a crumb. Both references give the WAVE the whole top strip and put the three
    /// controls in their own row underneath (trash · pause-or-mic · send), and the bottom bar's
    /// height is measured and fed back as the list inset, so the taller bar costs nothing.
    ///
    /// Pause opens the review; the red mic records the next stretch; send stitches. See
    /// AudioRecorder's segment note for why pause and append can never share one file.
    private var lockedRecordingBar: some View {
        VStack(spacing: 10) {
            // THE STRIP: the wave owns the width.
            HStack(spacing: 8) {
                if reviewingNote {
                    // REVIEWING: play it back. The waveform is the finished one, not the live meter —
                    // same component the sent bubble uses, so what you check is what they will see.
                    Button { togglePreview() } label: {
                        Image(systemName: previewPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 15)).foregroundStyle(Theme.accent(dark))
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    // SCRUBBABLE — his order with the reference's review open ("can we move sound
                    // wherever we want?"), reversing the old checking-is-not-editing stance. Same
                    // gesture machinery as the sent bubble: tap lands, horizontal drag scrubs,
                    // vertical is refused so nothing else moves.
                    WaveformBars(bars: previewWaveform.isEmpty ? Array(repeating: 30, count: 28) : previewWaveform,
                                 progress: previewProgress,
                                 played: Theme.accent(dark),
                                 unplayed: Theme.accent(dark).opacity(0.35),
                                 onSeek: { pct in seekPreview(pct) })
                        .frame(height: 22).frame(maxWidth: .infinity)
                    // Total on the right, the reference's order: play · wave · time.
                    Text(timeString(recorder.elapsed)).font(.system(size: 15).monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    // RECORDING: timer · live wave, the reference's order.
                    RecordTimerText(recorder: recorder)
                    RecordWaveform(recorder: recorder, color: Theme.accent(dark))
                        .frame(maxWidth: .infinity)
                }
                // ONE-TIME LISTEN — the "1" at the strip's end, both states, fill-when-armed like
                // the photo picker's badge. Arming it flashes the little confirmation over the bar.
                Button {
                    voiceViewOnce.toggle()
                    if voiceViewOnce {
                        withAnimation(.easeOut(duration: 0.2)) { voiceOnceToast = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                            withAnimation(.easeIn(duration: 0.25)) { voiceOnceToast = false }
                        }
                    }
                } label: {
                    Image(systemName: voiceViewOnce ? "1.circle.fill" : "1.circle")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(voiceViewOnce ? Color(hex: 0x3DA1FD) : .primary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(voiceViewOnce ? "One-time listen on" : "One-time listen off")
            }
            .padding(.horizontal, 14).frame(minHeight: 40)
            .liquidGlass(Capsule(), interactive: true)
            .clipShape(Capsule())   // keep the dotted waveform fully inside the pill's rounded edges

            // THE CONTROLS: trash · pause-or-mic · send, each in its own corner of the row.
            HStack {
                Button { cancelRecording() } label: {
                    Image(systemName: "trash.fill").font(.system(size: 18)).foregroundStyle(.red)
                        .frame(width: 40, height: 40).liquidGlass(Circle(), interactive: true)
                }
                Spacer()
                if reviewingNote {
                    // CONTINUE RECORDING — the reference's centre red mic. The next stretch; the
                    // stitcher joins them at send.
                    Button { resumeRecording() } label: {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 18)).foregroundStyle(.red)
                            .frame(width: 40, height: 40).liquidGlass(Circle(), interactive: true)
                            .contentShape(Circle())
                    }
                    .accessibilityLabel("Continue recording")
                } else {
                    // PAUSE IS THE ONE RECORDING CONTROL: it lands on the review with everything
                    // waiting. RED, not the accent — red is the recording signal everywhere here.
                    Button { beginPreview() } label: {
                        Image(systemName: "pause.fill")
                            .font(.system(size: 16, weight: .semibold)).foregroundStyle(.red)
                            .frame(width: 40, height: 40).liquidGlass(Circle(), interactive: true)
                            .contentShape(Circle())
                    }
                    .accessibilityLabel("Pause and listen back")
                }
                Spacer()
                Button { sendRecording() } label: {
                    // BLUE send button (white arrow on blue Liquid Glass), matching the composer send.
                    Image(systemName: "arrow.up").font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .liquidGlass(Circle(), interactive: true, tint: Theme.defaultBubble(dark))
                        .contentShape(Circle())
                }
            }
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.85), value: reviewingNote)
    }

    /// Pause: close the current stretch and show the review. NOT one-way any more — the red mic on
    /// the review bar records the next stretch, and send stitches them into one note.
    private func beginPreview() {
        Task {
            guard let (url, _, wf) = await recorder.pauseForReview() else {
                // Nothing recorded at all (or the stitch failed and the recorder cleaned up):
                // a cancel rather than an empty bar.
                cancelRecording()
                return
            }
            reviewingNote = true
            previewURL = url
            previewWaveform = wf
            previewProgress = 0
            impact(.light)
            // ⚠️ NO autoplay. The reference parks the pill with a play triangle waiting; hearing it
            // is a choice, and with Resume on the bar an unasked-for playback would talk over the
            // person deciding whether to keep going.
        }
    }

    /// The review bar's red mic: carry on recording where the pause left off (a new stretch).
    private func resumeRecording() {
        stopPreviewPlayback()   // clears reviewingNote + the preview player; segment files stay with the recorder
        recorder.resume()
    }

    private func togglePreview() {
        if previewPlaying { previewPlayer?.pause(); previewPlaying = false; stopPreviewTicker() }
        else { startPreviewPlayback() }
    }

    /// Drag or tap on the review waveform: move the playhead anywhere, playing or paused. Works
    /// before the first play too — startPreviewPlayback builds the player lazily and AVAudioPlayer
    /// honours a currentTime set while paused.
    private func seekPreview(_ pct: Double) {
        if previewPlayer == nil, let url = previewURL {
            previewPlayer = try? AVAudioPlayer(contentsOf: url)
            previewPlayer?.prepareToPlay()
        }
        guard let p = previewPlayer else { return }
        let clamped = max(0, min(1, pct))
        p.currentTime = clamped * p.duration
        previewProgress = clamped
    }

    /// Drives the review waveform. 20Hz, and only while the preview is actually running — the same rate
    /// the playback engine uses, so the two look identical in motion.
    private func startPreviewTicker() {
        previewTimer?.invalidate()
        // .common mode via the add below — a .default timer starves while a finger tracks the
        // chat's scroll, freezing the review progress mid-listen (same fix as the engine's tick).
        let t = Timer(timeInterval: 0.05, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard let p = previewPlayer else { return }
                if p.isPlaying {
                    previewProgress = p.duration > 0 ? p.currentTime / p.duration : 0
                } else {
                    // Ran to the end. Park it back at the start so pressing play hears it again from
                    // the top, which is what a person checking their own note wants.
                    previewPlaying = false
                    previewProgress = 0
                    p.currentTime = 0
                    stopPreviewTicker()
                }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        previewTimer = t
    }

    private func stopPreviewTicker() {
        previewTimer?.invalidate(); previewTimer = nil
    }

    private func startPreviewPlayback() {
        guard let url = previewURL else { return }
        if previewPlayer == nil {
            previewPlayer = try? AVAudioPlayer(contentsOf: url)
            previewPlayer?.prepareToPlay()
        }
        // The recorder leaves the session on .playAndRecord, which plays through the EARPIECE on some
        // handsets — a note you cannot hear reads as a note that did not record. Force the speaker
        // for the listen-back, then let the recorder re-warm its own session afterwards.
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .duckOthers])
        try? session.setActive(true)
        previewPlaying = previewPlayer?.play() ?? false
        if previewPlaying { startPreviewTicker() }
    }

    private func stopPreviewPlayback() {
        stopPreviewTicker()
        previewPlayer?.stop()
        previewPlayer = nil
        previewPlaying = false
        previewURL = nil
        previewWaveform = []
        previewProgress = 0
        reviewingNote = false
    }

    private func lockRecording() {
        holdStarted = false
        recordCancelArmed = false
        impact(.medium)   // lock
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            recordLocked = true
            recordDrag = .zero
        }
    }
    private func cancelRecording() {
        stopPreviewPlayback()   // before recorder.cancel(), which deletes the file underneath it
        recorder.cancel()
        AudioRecorder.discardDraft(cid)   // a binned note takes its parked draft with it
        notify(.warning)
        resetRecordingState()
    }

    /// Leaving the chat (or the app) with a locked session: stop, move the note to its per-chat
    /// draft on disk, and clear the bar. The next appearance of this chat adopts it back.
    private func parkRecordingDraft() {
        stopPreviewPlayback()
        recorder.parkDraft(cid: cid)
        resetRecordingState()
    }
    private func sendRecording() {
        // Sending from the review bar must not leave the note playing over the send. The bytes are
        // read by `finish()` inside stopAndSendAudio, which knows to use the finalized file.
        stopPreviewPlayback()
        // ⚠️ CAPTURED BEFORE resetRecordingState, which clears the flag — the Task below races the
        // reset, and reading the @State inside it sent every one-time note as ordinary.
        let once = voiceViewOnce
        Task { await stopAndSendAudio(viewOnce: once) }
        impact(.light)
        resetRecordingState()
    }
    private func resetRecordingState() {
        withAnimation { recordLocked = false; recordDrag = .zero; recordCancelArmed = false; holdStarted = false }
        voiceViewOnce = false   // the "1" arms ONE note; the next recording starts ordinary
    }
    private func flashHoldHint() {
        withAnimation(.easeOut(duration: 0.2)) { holdHint = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            withAnimation(.easeIn(duration: 0.25)) { holdHint = false }
        }
    }
    private func impact(_ s: UIImpactFeedbackGenerator.FeedbackStyle) {
        UIImpactFeedbackGenerator(style: s).impactOccurred()
    }
    private func notify(_ t: UINotificationFeedbackGenerator.FeedbackType) {
        UINotificationFeedbackGenerator().notificationOccurred(t)
    }

    private func timeString(_ t: TimeInterval) -> String {
        let s = Int(t); return String(format: "%d:%02d", s / 60, s % 60)
    }

    private func stopAndSendAudio(viewOnce: Bool = false) async {
        // If finish() returns nil at the boundary (elapsed vs live currentTime can differ ~0.05s),
        // still tear down cleanly so the recording UI never gets stuck. Keep replyingTo though:
        // a dropped too-short note must not destroy the reply target — the user just retries.
        // The draft folder goes either way: on success the note leaves as a message; on a nil
        // finish the segment files are already cleaned and stale meta must not resurrect them.
        defer { AudioRecorder.discardDraft(cid) }
        guard let (data, dur, wf) = await recorder.finish() else { return }
        // Optimistic: show the voice bubble INSTANTLY (springs in, playable from the local
        // recording), then reconcile when the upload echoes back — no dead lag on release.
        let clientId = UUID().uuidString
        // Bug 1: a voice note recorded while replying must carry the reply (works for photo/voice
        // targets too), and the reply bar must clear after sending.
        let reply = replyingTo.map {
            ReplyRef(id: $0.id, authorId: $0.authorId,
                     text: replyQuoteText($0))
        }
        await MainActor.run {
            // The optimistic bubble must carry the quote too — without it the voice reply
            // looked quote-less until the server echo reconciled (read as "reply didn't work").
            var pending = Message(localAudioData: data, duration: dur, waveform: viewOnce ? [] : wf,
                                  authorId: me, clientId: clientId, sendState: .sending)
            pending.replyTo = reply
            pending.viewOnce = viewOnce   // the optimistic bubble draws the pill, not the player
            repo.addPending(pending)
            withAnimation(.easeInOut(duration: 0.2)) { replyingTo = nil }
        }
        do { try await ChatService.sendAudio(cid: cid, data: data, duration: dur, waveform: wf, replyTo: reply, clientId: clientId, group: isGroup ? groupMembers : nil, viewOnce: viewOnce) }
        catch { await MainActor.run { repo.markFailed(clientId: clientId) } }
    }

    private func sendCaptured(_ data: Data) async {
        await sendPhoto(data)
    }
}

// Device-local record of consumed view-once photos (enforced on-device too: once opened, the
// bubble flips to "Viewed" and can never be reopened here).
enum ViewedOnce {
    private static let key = "viewedOnceMessageIds"
    static func contains(_ id: String) -> Bool {
        (UserDefaults.standard.stringArray(forKey: key) ?? []).contains(id)
    }
    static func mark(_ id: String) {
        var ids = UserDefaults.standard.stringArray(forKey: key) ?? []
        guard !ids.contains(id) else { return }
        ids.append(id)
        if ids.count > 500 { ids.removeFirst(ids.count - 500) }   // bounded
        UserDefaults.standard.set(ids, forKey: key)
    }
}

// Selection wrapper: in select mode a circular checkmark slides in on the LEADING edge
// (aligned to the row), the bubble's own gestures are disabled, the whole row toggles on tap, and a
// selected row gets a soft highlight. Off select mode, the row is untouched.
/// THE ONE LOOK FOR EVERY CENTRED IN-CHAT NOTICE — the day separator ("Today"), the "X pinned …"
/// notice and system rows. They had drifted apart: the day pill was primary text on frosted material
/// while the others were secondary grey on a flat received-bubble tint, so two pills a few lines
/// apart read as two different things (user screenshot, "make it the same, no difference"). One
/// modifier now owns the look, which is also what stops it drifting again.
struct ChatNoticePill: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.caption.weight(.semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.06), lineWidth: 0.5))
    }
}

// The empty-chat lock notice. Same family as ChatNoticePill — translucent, centred, hairline edge —
// but a rounded rect instead of a capsule: this text wraps to three lines, and a capsule drawn around
// three lines reads as a lozenge rather than a pill.
struct EmptyChatNotice: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.caption)
            .multilineTextAlignment(.center)
            .foregroundStyle(.primary)
            .frame(maxWidth: 280)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.white.opacity(0.06), lineWidth: 0.5))
            .padding(.horizontal, 24)
    }
}

struct SelectableRow: ViewModifier {
    let selecting: Bool
    let selected: Bool
    let onToggle: () -> Void
    func body(content: Content) -> some View {
        if selecting {
            HStack(spacing: 10) {
                // READS ON ANY BACKGROUND (user: hard to see in light mode / over a wallpaper). The old
                // unselected state was a hairline `circle` in secondary grey at 55% — it vanished over a
                // photo wallpaper and was barely there in light mode. the reference app's selection circle carries
                // its own contrast rather than borrowing the background's: a filled disc UNDER a light
                // ring, plus a soft shadow, so the control is legible over white, black, or a photo.
                ZStack {
                    Circle()
                        .fill(selected ? Color(hex: 0x3DA1FD) : Color.black.opacity(0.30))
                        .frame(width: 24, height: 24)
                    Circle()
                        .strokeBorder(Color.white.opacity(selected ? 0 : 0.92), lineWidth: 1.5)
                        .frame(width: 24, height: 24)
                    if selected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
                .shadow(color: .black.opacity(0.28), radius: 2, y: 1)
                .transition(.move(edge: .leading).combined(with: .opacity))
                content.allowsHitTesting(false)
            }
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
            .onTapGesture(perform: onToggle)   // checkbox only — no row highlight
        } else {
            content
        }
    }
}

// Upload indicator: a thin white arc spinning on a subtle dark disc (replaces the heavy
// frosted-material pinwheel) — one consistent look for photo / album / video uploads.
/// The upload spinner, rebuilt on the reference app's, read from their CircularProgressView and
/// CVAttachmentProgressView rather than eyeballed.
///
/// The difference is that theirs is in TWO phases, and ours was one. A constant arc spinning at a
/// constant speed reads as a generic "busy" marker. Theirs begins as nothing and OPENS into a half
/// circle while it turns, so the first second says "this has just started" before it settles into
/// waiting. That opening is the part that makes it feel like the upload rather than like a spinner.
///
///   • Phase one, 1s, ease in: the stroke grows from 0 to half the circle while rotating 270°.
///   • Phase two, 1s per turn, linear, forever: that half circle spins.
///
/// Their numbers, not approximations of them.
///
/// It stays INDETERMINATE on purpose. Firebase's `putFileAsync` reports no byte progress, so a
/// filling ring would be a lie about something we cannot measure. the reference app shows exactly this
/// spinner in their own `unknownProgress` state, which is the honest one here.
struct UploadingRing: View {
    /// The optimistic bubble's clientId. Given one, the ring reports real bytes.
    var clientId: String? = nil

    @ObservedObject private var uploads = UploadProgress.shared
    @State private var trimEnd: CGFloat = 0
    @State private var rotation: Double = 0

    private static let phaseOne: Double = 1     // stroke grows and does its initial turn
    private static let phaseTwo: Double = 1     // one full revolution, repeated
    private static let determinate: Double = 0.2   // the reference app's Animation.Determinate.duration

    /// nil until the first byte is reported — which is NOT the same as zero, and is why the ring
    /// spins at the start instead of sitting empty looking broken.
    private var fraction: Double? { uploads.fraction(clientId) }

    var body: some View {
        ZStack {
            // Their background is a blurred circle with a hairline border and a soft shadow, not a
            // flat black disc — so it sits ON the photo instead of punching a hole in it.
            Circle().fill(.ultraThinMaterial)
                .overlay(Circle().stroke(.white.opacity(0.1), lineWidth: 1))
                .shadow(color: .black.opacity(0.32), radius: 24)
                .frame(width: 46, height: 46)

            Group {
                if let fraction {
                    // DETERMINATE: the arc is the upload. Starts at the top and fills clockwise,
                    // each step eased over the reference app's 0.2s so a burst of progress events reads as one
                    // continuous movement rather than a series of jumps.
                    Circle().trim(from: 0, to: max(0.02, CGFloat(fraction)))
                        .stroke(.white, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.easeOut(duration: Self.determinate), value: fraction)
                } else {
                    // INDETERMINATE, the reference app's two phases: the stroke grows from nothing to half the
                    // circle while turning 270°, then that half circle spins for as long as it takes.
                    Circle().trim(from: 0, to: trimEnd)
                        .stroke(.white, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(rotation - 90))
                }
            }
            .frame(width: 26, height: 26)
        }
        .onAppear { startIndeterminate() }
    }

    private func startIndeterminate() {
        withAnimation(.easeIn(duration: Self.phaseOne)) {
            trimEnd = 0.5
            rotation = 270
        }
        // Phase two takes over exactly where phase one ended, so the turn never stutters: it
        // continues from 270 rather than restarting.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.phaseOne) {
            withAnimation(.linear(duration: Self.phaseTwo).repeatForever(autoreverses: false)) {
                rotation = 270 + 360
            }
        }
    }
}

struct MessageBubble: View, Equatable {
    // Equatable so SwiftUI skips re-rendering a bubble whose VALUE inputs are unchanged, even when
    // the parent re-evaluates and passes fresh closures (the re-render storm from typing / read
    // receipts / chat-list churn). Closures + @State are intentionally NOT compared.
    static func == (l: MessageBubble, r: MessageBubble) -> Bool {
        l.message == r.message && l.isMe == r.isMe && l.dark == r.dark && l.cid == r.cid
            && l.isGroup == r.isGroup && l.canPin == r.canPin && l.isPinned == r.isPinned
            && l.isHighlighted == r.isHighlighted && l.searchTerm == r.searchTerm
            && l.isFirstInCluster == r.isFirstInCluster && l.isLastInCluster == r.isLastInCluster
            && l.otherLastRead == r.otherLastRead && l.chatColor == r.chatColor
            && l.isViewedOnce == r.isViewedOnce && l.restricted == r.restricted
    }

    let message: Message
    let isMe: Bool
    let dark: Bool
    let cid: String
    var nameFor: (String) -> String = { _ in "" }
    var avatarFor: (String) -> String? = { _ in nil }
    var onReply: (Message) -> Void = { _ in }
    var onDelete: (Message) -> Void = { _ in }
    var onCancelSending: (Message) -> Void = { _ in }   // media still uploading → discard the pending send
    var onTapContact: (_ uid: String, _ name: String, _ photo: String?) -> Void = { _, _, _ in }   // card "message" → open chat
    var onTapImage: (Message) -> Void = { _ in }
    var onTapAlbum: (_ gallery: [Message], _ startId: String) -> Void = { _, _ in }
    /// Tapping a group of photos opens the ALBUM SCREEN (a scrollable list of the group) rather than
    /// jumping straight into one full-screen photo. See AlbumScreenView.
    var onOpenAlbum: (Message) -> Void = { _ in }
    var onTapVideo: (Message) -> Void = { _ in }
    var onReact: (String?) -> Void = { _ in }
    var onPin: (Message) -> Void = { _ in }
    var onForward: (Message) -> Void = { _ in }
    var onSelect: (Message) -> Void = { _ in }
    var onInfo: (Message) -> Void = { _ in }
    var onEdit: (Message) -> Void = { _ in }
    var onReactMore: (Message) -> Void = { _ in }
    // Link/username taps route UP to the screen (ONE dialog at ThreadView level) instead of every
    // bubble carrying its own confirmationDialog + alert: ~40 live cells each configured presentation
    // machinery, and a dialog anchored inside a recycled cell could be torn down under the user.
    var onConfirmLink: (URL) -> Void = { _ in }
    var onUserNotFound: () -> Void = {}
    var isGroup: Bool = false   // drives per-sender name labels above others' bubbles in groups

    /// Watched so an album tile dims the instant its X is tapped. An ObservedObject invalidates
    /// regardless of the Equatable gate above, which is wanted here — cancelling is rare and the
    /// bubble must react to it.
    @ObservedObject private var mediaSend = MediaSend.shared

    /// This album item's upload key ("clientId#index") while the message is still sending.
    private func albumItemKey(_ i: Int) -> String? {
        guard let clientId = message.clientId else { return nil }
        return MediaSend.itemKey(clientId, i)
    }
    var onTapReactions: () -> Void = {}
    var onTapSender: (String) -> Void = { _ in }
    var onOpenFile: (Message) -> Void = { _ in }
    var onSaveImage: (Message) -> Void = { _ in }
    var canPin: Bool = true
    var isPinned: Bool = false
    var restricted: Bool = false   // I'm muted in this group → can't react / edit (parity with the composer)

    private var fileSizeLabel: String {
        guard let b = message.fileSize else { return "Document" }
        if b >= 1_048_576 { return String(format: "%.1f MB", Double(b) / 1_048_576) }
        if b >= 1024 { return String(format: "%.0f KB", Double(b) / 1024) }
        return "\(b) B"
    }
    private var videoDurationLabel: String {
        let d = Int(message.duration ?? 0)
        return String(format: "%d:%02d", d / 60, d % 60)
    }
    var onResend: (Message) -> Void = { _ in }
    var onJumpTo: (String) -> Void = { _ in }
    // Resolve the ORIGINAL message a reply points at (from the loaded list), so a photo/video/GIF
    // reply can show a real thumbnail in the quote (reference-style) instead of "📷 Photo" text.
    // Returns nil if the original isn't loaded → the quote falls back to the text snippet.
    var resolveReplyOriginal: (String) -> Message? = { _ in nil }
    var onTapStory: (_ storyId: String, _ authorId: String, _ anchorId: String) -> Void = { _, _, _ in }
    /// This bubble's story-quote thumbnail is a door: register it as the flight's source. False for
    /// the bubble kinds that draw a quote but never open one, which must not file a rectangle the
    /// close could then fly home to.
    var storyQuoteOpens: Bool = false
    var isHighlighted: Bool = false
    var searchTerm: String = ""           // in-chat search: highlight this term inside the text
    var isFirstInCluster: Bool = true
    var isLastInCluster: Bool = true
    var otherLastRead: Double = 0
    var chatColor: ChatColorSpec? = nil   // per-chat custom bubble colour for MY messages (local)
    var isViewedOnce: Bool = false        // view-once photo already consumed on this device

    // Fill behind MY bubbles: the custom chat colour if set, else the default systemBlue (adaptive
    // light/dark — see Theme.defaultBubble).
    private var myFill: AnyShapeStyle { chatColor?.fill ?? AnyShapeStyle(Theme.defaultBubble(dark)) }

    // Text/meta on MY bubbles: both the custom colours AND the default systemBlue are vivid in BOTH
    // modes, so the text/glyphs are always WHITE.
    private var onMyBubble: Color { .white }

    @AppStorage("readReceipts") private var readReceiptsPref = true
    @State private var dragX: CGFloat = 0   // swipe-to-reply offset (SwiftUI bubbles move INSIDE the cell)
    @State private var swipeArmed = false   // past the commit point → the threshold haptic already fired
    @State private var swipeFollowing = false   // axis decided for THIS touch → follow every frame

    private var myUid: String { AuthService.shared.uid ?? "" }
    private var myReaction: String? { message.reactions[myUid] }

    // Stable per-sender color for group name labels (deterministic across launches).
    private var senderColor: Color {
        let palette: [Color] = [.blue, .purple, .pink, .orange, .green, .teal, .indigo, .red]
        let sum = message.authorId.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return palette[sum % palette.count]
    }

    // Message body: tappable URLs + @usernames + highlighted group @mentions.
    // Built ONCE — NSDataDetector / NSRegularExpression construction is expensive; doing it per
    // render per bubble was the main scroll-jank source.
    private static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    private static let mentionRegex = try? NSRegularExpression(pattern: "@([A-Za-z0-9_]{3,24})")

    // First https link in the text (for the Open-Graph preview card). Only web links, not kulan:// ones.
    private var firstLinkURL: URL? {
        guard message.text.contains("http"), let d = Self.linkDetector else { return nil }
        let r = NSRange(message.text.startIndex..., in: message.text)
        return d.matches(in: message.text, range: r).compactMap(\.url).first { $0.scheme == "https" }
    }

    private var bodyText: Text {
        let full = message.text
        var str = AttributedString(full)
        str.font = .system(size: 17)
        // In-chat search: highlight the matched TERM inside the text — never the whole
        // bubble. Applied before the plain-text fast path so text-only messages highlight too.
        // Gated at 2+ chars (the search floor) and matched case/diacritic/width-insensitively, so the
        // highlight finds exactly what the search matched (café highlights for "cafe").
        if searchTerm.count >= 2 {
            var from = full.startIndex
            while let r = full.range(of: searchTerm,
                                     options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                                     range: from..<full.endIndex) {
                let startOff = full.distance(from: full.startIndex, to: r.lowerBound)
                let len = full.distance(from: r.lowerBound, to: r.upperBound)
                let lo = str.index(str.startIndex, offsetByCharacters: startOff)
                let hi = str.index(lo, offsetByCharacters: len)
                str[lo..<hi].backgroundColor = Color.yellow
                str[lo..<hi].foregroundColor = Color.black
                from = r.upperBound
            }
        }
        // Fast path: plain text with no links/@/mentions skips ALL regex work (the common case).
        guard full.contains("http") || full.contains("@") || !message.mentions.isEmpty else { return Text(str) }
        let ns = full as NSString
        let whole = NSRange(location: 0, length: ns.length)

        // Map a UTF-16 NSRange to AttributedString indices (emoji-safe) and apply attributes.
        func style(_ nsRange: NSRange, link: URL?, underline: Bool = false) {
            guard let sr = Range(nsRange, in: full) else { return }
            let startOff = full.distance(from: full.startIndex, to: sr.lowerBound)
            let len = full.distance(from: sr.lowerBound, to: sr.upperBound)
            let lo = str.index(str.startIndex, offsetByCharacters: startOff)
            let hi = str.index(lo, offsetByCharacters: len)
            // WHITE on my bubble: the fill is systemBlue (or a vivid custom chat colour), so a blue
            // link was blue-on-blue and effectively invisible (owner's screenshot). The underline
            // still marks it as tappable. Received bubbles keep the standard blue.
            str[lo..<hi].foregroundColor = isMe ? onMyBubble : .blue
            if let link { str[lo..<hi].link = link }
            if underline { str[lo..<hi].underlineStyle = .single }
        }

        // Web links → tappable (blue, underlined).
        if let detector = Self.linkDetector {
            for m in detector.matches(in: full, range: whole) where m.url != nil {
                style(m.range, link: m.url, underline: true)
            }
        }
        // @usernames → kulan://u/<handle> (resolved on tap).
        if let re = Self.mentionRegex {
            for m in re.matches(in: full, range: whole) {
                let handle = ns.substring(with: m.range(at: 1))
                style(m.range, link: URL(string: "kulan://u/\(handle)"))
            }
        }
        // Group @mentions by display name → bold + accent (overrides the generic style).
        for uid in message.mentions {
            let token = "@\(nameFor(uid))"
            var idx = str.startIndex
            while idx < str.endIndex, let r = str[idx...].range(of: token) {
                str[r].font = .system(size: 17, weight: .semibold)
                if !isMe { str[r].foregroundColor = .accentColor }
                idx = r.upperBound
            }
        }
        return Text(str)
    }

    // How many emoji this message qualifies as "jumbomoji" with — 0 when it is an ordinary message.
    private var jumbomojiCount: Int { message.text.jumbomojiCount }

    /// the reference app's `CVComponentBodyText.textMessageFont`, verbatim: multipliers on the body point size.
    /// Their base is `UIFont.dynamicTypeBodyClamped.pointSize`; ours is the fixed 17pt every other bubble
    /// uses, which is the same number at the default Dynamic Type setting.
    static func jumbomojiPointSize(_ count: Int) -> CGFloat {
        let base: CGFloat = 17
        switch count {
        case 1: return base * 3.5
        case 2: return base * 3.0
        case 3: return base * 2.75
        case 4: return base * 2.5
        default: return base * 2.25   // 5, the maximum that still counts as jumbomoji
        }
    }

    // The message text + trailing time as one line (short) or wrapped (long) — shared by the plain and
    // the reply-quote layouts so the two stay identical.
    @ViewBuilder private var bodyLine: some View {
        if metaNeedsOwnLine {
            // LONG MESSAGE: the timestamp gets a REAL line of its own and the text is left completely
            // unreserved, so every line runs the full bubble width.
            //
            // Why this branch exists (user report + screenshot: a long paste wrapped ~55pt short on
            // EVERY line, with a tall empty column above the timestamp): the inline invisible
            // reservation is the right trick only when the time can actually share the last line. Once
            // `metaNeedsOwnLine` is true — a word too long to leave room, or a hard-wrapped paste —
            // the reservation begins with a newline, and a trailing run that starts a new line still
            // participates in the concatenated Text's width, so the wrap column shrank by the meta's
            // width for the whole paragraph. Reserving nothing, and giving the meta its own row, is
            // both simpler and exactly what the reference app does when the footer cannot share the last line.
            VStack(alignment: .trailing, spacing: 2) {
                bodyText
                    .foregroundColor(isMe ? onMyBubble : (dark ? .white : .black))
                    // SwiftUI paints link runs with the TINT, which would put blue links back on a
                    // blue bubble whatever the attributed colour says.
                    .tint(isMe ? onMyBubble : Color.accentColor)
                    .fixedSize(horizontal: false, vertical: true)   // wrap, never ellipsis
                    .frame(maxWidth: .infinity, alignment: .leading)
                metaRow
            }
        } else {
            // SHORT MESSAGE: the text flows FULL WIDTH and only the LAST line reserves room for the
            // timestamp. An HStack { text; time } instead reserved a full-height column beside the
            // text, so EVERY line wrapped early. Here we append an INVISIBLE inline run that mirrors
            // the metaRow (same font/glyphs → exact same width) to the end of the text, so only the
            // last line leaves a gap, then overlay the REAL time bottom-trailing on top of that gap.
            (bodyText + metaPlaceholder.foregroundColor(.clear))
                .foregroundColor(isMe ? onMyBubble : (dark ? .white : .black))
                .tint(isMe ? onMyBubble : Color.accentColor)   // links follow the bubble, see above
                // NEVER truncate: take the height the wrap actually needs. Inside a self-sizing cell
                // a Text offered slightly less width than it was measured at will drop the overflow
                // and paint an ellipsis rather than grow, which is the "…" on a message with plenty
                // of room below it (owner report). fixedSize makes growing the only option.
                .fixedSize(horizontal: false, vertical: true)
                .overlay(alignment: .bottomTrailing) { metaRow.padding(.bottom, 1) }
        }
    }

    // Same as bodyLine but the TEXT fills the hugged column FIRST, so the overlaid time anchors to the
    // bubble's right edge — not the text's natural right edge. Used only in the reply-quote layout, where
    // the QUOTE can drive the bubble wider than the body: with plain bodyLine the time landed mid-bubble
    // (user report: reply timestamp not right-aligned). The frame's .infinity is clamped by the overlay's
    // offered width (= the template's hugged bubble width), so long text still wraps at the bubble cap.
    @ViewBuilder private var bodyLineFilled: some View {
        if metaNeedsOwnLine {
            // Same own-line treatment as bodyLine — the two MUST branch identically or the template
            // and the visible copy would measure to different heights.
            VStack(alignment: .trailing, spacing: 2) {
                bodyText
                    .foregroundColor(isMe ? onMyBubble : (dark ? .white : .black))
                    // SwiftUI paints link runs with the TINT, which would put blue links back on a
                    // blue bubble whatever the attributed colour says.
                    .tint(isMe ? onMyBubble : Color.accentColor)
                    .fixedSize(horizontal: false, vertical: true)   // wrap, never ellipsis
                    .frame(maxWidth: .infinity, alignment: .leading)
                metaRow
            }
        } else {
            (bodyText + metaPlaceholder.foregroundColor(.clear))
                .foregroundColor(isMe ? onMyBubble : (dark ? .white : .black))
                .tint(isMe ? onMyBubble : Color.accentColor)   // links follow the bubble, see above
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .bottomTrailing) { metaRow.padding(.bottom, 1) }
        }
    }

    // the reference app's footer rule: the timestamp shares the message's LAST line when it fits, else drops to
    // its OWN line. The inline invisible spacer below reserves the trailing room for the fit case; when
    // the widest unbreakable word leaves no room for the time (a long word / gibberish token that fills
    // the bubble width), the reservation can't push it — the time then painted OVER the text (user
    // report). This detects that case deterministically (UIKit text measurement, no SwiftUI feedback)
    // and forces the time onto its own line.
    /// True when the timestamp cannot share the message's last line — a word too long to leave room
    /// beside it. When true, `bodyLine` gives the meta a real row of its own and reserves NOTHING
    /// inline, so the text keeps the full bubble width on every line.
    private var metaNeedsOwnLine: Bool { metaNeedsOwnLine(inWidth: maxBubbleWidth - 30) }

    /// The same test against an ARBITRARY content width, so a media caption can ask it about the media
    /// box it actually wraps in rather than about the text bubble's width.
    private func metaNeedsOwnLine(inWidth textAvail: CGFloat) -> Bool {
        let bodyFont = UIFont.systemFont(ofSize: 17)
        let metaFont = UIFont.systemFont(ofSize: 10)
        var metaStr = message.edited ? "edited " : ""
        metaStr += timeString
        var metaW = (metaStr as NSString).size(withAttributes: [.font: metaFont]).width
        // The read pair, ALWAYS — same constant reservation metaPlaceholder makes, so this test and the
        // reservation can never disagree about how wide the footer is (they must agree, or the
        // invisible template and the visible copy measure to different heights).
        if isMe { metaW += 25 }
        metaW += 8                // gap between the last word and the time
        let longestWord = message.text.split(whereSeparator: { $0.isWhitespace })
            .map { (String($0) as NSString).size(withAttributes: [.font: bodyFont]).width }.max() ?? 0
        return longestWord + metaW > textAvail
    }

    /// A media caption + its timestamp, in a bubble `width` points wide.
    ///
    /// THE CAPTION GETS THE WHOLE BUBBLE. Every media caption used to be
    /// `HStack { Text; Spacer; metaRow }`, and an HStack reserves its siblings' width for the FULL
    /// HEIGHT of the row — so the timestamp cut ~70pt off EVERY line of the caption, not just the last
    /// one. On a long caption that reads as a bubble with a tall empty column down the right-hand side,
    /// which is exactly what the user photographed, and he named the cause himself: "the problem is
    /// right side timestamp line".
    ///
    /// Text bubbles never had this because they use the reservation trick instead: an invisible inline
    /// run at the end of the text, so only the LAST line leaves a gap, with the real timestamp overlaid
    /// on it. Captions now use the same two branches for the same reasons — including the long-message
    /// branch, where a reservation that begins on a new line would shrink the wrap column for the whole
    /// paragraph, so the meta takes a real row and the text reserves nothing.
    @ViewBuilder private func captionBody(width: CGFloat) -> some View {
        let fg = isMe ? onMyBubble : (dark ? Color.white : .black)
        Group {
            if metaNeedsOwnLine(inWidth: width - 24) {   // 2 × 12pt caption insets
                VStack(alignment: .trailing, spacing: 2) {
                    Text(message.text).font(.system(size: 17))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    metaRow
                }
            } else {
                (Text(message.text).font(.system(size: 17))
                    + metaPlaceholder(ownLine: false).foregroundColor(.clear))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .bottomTrailing) { metaRow.padding(.bottom, 1) }
            }
        }
        .foregroundStyle(fg)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(width: width, alignment: .leading)
        // The double-tap react that the media bubble denies itself (tap counting would sit between
        // a single tap and the viewer opening) lives HERE instead, per the user's split: the caption
        // opens nothing on tap, so the wait costs it nothing. Photo area = instant open, caption
        // area = quick react — two zones, one bubble. Same body as the text bubble's double-tap.
        .contentShape(Rectangle())
        .highPriorityGesture(
            TapGesture(count: 2).onEnded {
                guard message.sendState == nil, !restricted, !message.deleted else { return }
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                let quick = QuickReaction.current
                onReact(myReaction == quick ? nil : quick)
            }
        )
    }

    // A Text that renders IDENTICALLY to metaRow (edited? · time · tick?) but is drawn clear — used only
    // to reserve the trailing space on the message's last line. Same fonts/symbols → widths match exactly.
    // A leading newline drops the reservation (and thus the overlaid time) to its own line when the text
    // leaves no room for it on the last line.
    private var metaPlaceholder: Text { metaPlaceholder(ownLine: metaNeedsOwnLine) }

    /// `ownLine` is passed in rather than re-derived, because the caller already knows the answer FOR
    /// ITS OWN WIDTH. A caption asked about the media box; re-deriving here would answer about the text
    /// bubble instead, and the two can disagree — which would prepend a newline to a reservation the
    /// caller had just decided could sit on the last line.
    private func metaPlaceholder(ownLine: Bool) -> Text {
        var t = Text(ownLine ? "\n  " : "  ")   // own line for long text; else a small gap
        if message.edited { t = t + Text("edited ").italic() }
        t = t + Text(timeString)
        // ONE CONSTANT WIDTH FOR EVERY SEND STATE, which is the point (user report + photo: "pending
        // message and sended message is using different bubble size, the problem is the timestamp").
        //
        // This used to mirror whatever metaRow was drawing at that instant — nothing while sending
        // (metaRow shows a clock there, which this never reserved), one checkmark delivered, two once
        // read. Since the reservation is what the last line wraps against, and the bubble hugs that
        // width, the bubble RESIZED as the message progressed: it grew the moment the send landed and
        // grew again when the other side read it. Reserving the widest state always — the read pair —
        // makes the bubble the same size the whole way through. The real metaRow is overlaid at the
        // trailing edge, so a narrower state just leaves invisible slack behind the timestamp.
        if isMe {
            t = t + Text(" ") + Text(Image(systemName: "checkmark")) + Text(Image(systemName: "checkmark"))
        }
        return t.font(.system(size: 10))
    }

    // Route a tapped link: web URL -> "Open link?" confirm; kulan://u/<handle> -> open the
    // person (or show "doesn't exist"). Returns .handled so iOS never opens it directly.
    private func routeTappedURL(_ url: URL) -> OpenURLAction.Result {
        if url.scheme == "kulan", url.host == "u" {
            let handle = url.lastPathComponent
            Task { @MainActor in
                if let u = await ChatService.findByHandle(handle) {
                    AppRouter.shared.pendingChatName = u.name
                    AppRouter.shared.pendingChatPhoto = u.photoUrl
                    AppRouter.shared.pendingChatId = ChatService.convId(myUid, u.id)
                } else {
                    onUserNotFound()
                }
            }
            return .handled
        }
        onConfirmLink(url)
        return .handled
    }

    // Aggregate uid->emoji into (emoji, count, mine), most-popular first (standard logic,
    // our own pill design). Ties broken by emoji for a stable order.
    private var reactionCounts: [(emoji: String, count: Int, mine: Bool)] {
        // A tombstone is a placeholder, never a reactable message — and this empty return is
        // STRUCTURAL, not cosmetic: reactions on a tombstone can still exist in flight (a reaction
        // landing in the same instant as the delete, an old build writing onto the stripped doc),
        // and every badge, overhang and tap surface derives from this one value. Empty here means
        // a deleted row cannot render or respond to reactions no matter what the data says.
        guard !message.deleted else { return [] }
        return Dictionary(grouping: message.reactions.values, by: { $0 })
            .map { (emoji: $0.key, count: $0.value.count, mine: message.reactions[myUid] == $0.key) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.emoji > $1.emoji }
    }

    private var isRead: Bool {
        message.createdAt.timeIntervalSince1970 * 1000 <= otherLastRead
    }

    private var timeString: String {
        message.createdAt.formatted(date: .omitted, time: .shortened)
    }

    // Time + status, shown INSIDE the bubble bottom-right. Status = clock while sending,
    // red "!" if it failed, ONE check when delivered, TWO checks once the other person has read it.
    //
    // The read state used to be `checkmark.circle.fill` — still a SINGLE glyph, just inside a circle,
    // in the same colour at 9pt. That is why read receipts looked broken: the data was arriving and
    // the tick was upgrading, but the upgrade was invisible. The chat list already drew real double
    // ticks (MainShell `ticksView`); the thread now matches it.
    @ViewBuilder private var metaRow: some View {
        HStack(spacing: 3) {
            if message.edited { Text("edited").font(.system(size: 10)).italic() }
            Text(timeString).font(.system(size: 10))
            if isMe {
                switch message.sendState {
                case .sending:
                    // THE CLOCK EARNS ITS PLACE (owner's fast-screenshot test, 2026-08-12): the
                    // reference app never shows a clock on a healthy send — the tick lands before
                    // the eye can catch a pending state. So the slot stays EMPTY for the first
                    // 0.8s; a normal send flips to ✓ inside that window and the clock is never
                    // seen. Only a send still pending after the window shows it — the honest
                    // slow-network indicator, which is all the clock was ever for.
                    PendingClockGlyph(bornAt: message.createdAt)
                case .failed:
                    Image(systemName: "exclamationmark.circle.fill").font(.system(size: 10)).foregroundStyle(.red)
                case nil:
                    // Overlapping pair, same spacing as the chat list's ticks.
                    HStack(spacing: -2.5) {
                        Image(systemName: "checkmark")
                        // NOT gated on our own readReceipts pref. The chat list's ticks never were
                        // (MainShell ticksView), so with the pref off the list showed 2 ticks while the
                        // bubbles showed 1 for the very same message - the asymmetry the user reported.
                        // Privacy lives on the WRITE (ChatService.markRead returns early when the pref is
                        // off, so we don't broadcast our own reads); hiding information the other side
                        // already sent us was just an inconsistency.
                        if isRead { Image(systemName: "checkmark") }
                    }
                    .font(.system(size: 9, weight: .semibold))
                }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: isRead)
        .foregroundStyle(isMe ? onMyBubble.opacity(0.7) : Color.secondary)
    }

    // Bubbles cap at 72% of screen width and wrap; the right (sent) / left (received)
    // edge stays a clean, uniform line regardless of length.
    private var maxBubbleWidth: CGFloat { UIScreen.main.bounds.width * 0.72 }

    /// The sending clock with its 0.8s grace window — see the `.sending` case above. The glyph is
    /// drawn at opacity 0 during the grace so the slot's size never shifts; `bornAt` anchors the
    /// window to the message (a recycled cell for an already-slow send shows the clock at once).
    private struct PendingClockGlyph: View {
        let bornAt: Date
        @State private var showClock: Bool
        init(bornAt: Date) {
            self.bornAt = bornAt
            _showClock = State(initialValue: Date().timeIntervalSince(bornAt) > 0.8)
        }
        var body: some View {
            Image(systemName: "clock")
                .font(.system(size: 9, weight: .semibold))
                .opacity(showClock ? 1 : 0)
                .task {
                    guard !showClock else { return }
                    let remaining = 0.8 - Date().timeIntervalSince(bornAt)
                    if remaining > 0 {
                        try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                    }
                    guard !Task.isCancelled else { return }
                    withAnimation(.easeIn(duration: 0.15)) { showClock = true }
                }
        }
    }

    // Photo bubble sized to the image's natural aspect (capped), not a forced square.
    private var imageDisplaySize: CGSize {
        let maxW: CGFloat = 240, maxH: CGFloat = 340
        guard let w = message.width, let h = message.height, w > 0, h > 0 else {
            return CGSize(width: 220, height: 220)
        }
        let aspect = CGFloat(w / h)
        var dw = maxW, dh = dw / aspect
        if dh > maxH { dh = maxH; dw = dh * aspect }
        return CGSize(width: dw, height: dh)
    }

    /// Video bubble box. Same as `imageDisplaySize`, plus the PHOTO path's caption min-width floor.
    /// Without it a portrait video (aspect ~0.46 → ~157pt wide) forced the caption to 157pt, so a long
    /// caption wrapped at roughly one word per line and the bubble became absurdly tall. The photo path
    /// has always applied this floor; video never did.
    private var videoBox: CGSize {
        var s = imageDisplaySize
        guard !message.text.isEmpty else { return s }
        let boxMax = min(maxBubbleWidth, 350)
        let textW = (message.text as NSString)
            .size(withAttributes: [.font: UIFont.systemFont(ofSize: 17)]).width + 24   // 2 × 12pt insets
        s.width = min(boxMax, max(s.width, textW))
        return s
    }

    // Fused-cluster corners (our look): full 18pt outer corners; the interior corners
    // on the sending side shrink to 6pt so a same-sender run reads as one block.
    private var bubbleCorners: RectangleCornerRadii {
        let big: CGFloat = 18, small: CGFloat = 6
        if isMe {
            return RectangleCornerRadii(
                topLeading: big, bottomLeading: big,
                bottomTrailing: isLastInCluster ? big : small,
                topTrailing: isFirstInCluster ? big : small)
        } else {
            return RectangleCornerRadii(
                topLeading: isFirstInCluster ? big : small,
                bottomLeading: isLastInCluster ? big : small,
                bottomTrailing: big, topTrailing: big)
        }
    }

    // Reaction pills (our own design): up to 3 emoji+count capsules, my reaction tinted
    // with the brand accent, the rest neutral, and a "+N" capsule when there are more.
    /// Does a single tap on this bubble OPEN something? Media does: the viewer, the player, the album
    /// pager. Those bubbles must not carry a double-tap recogniser, because tap counting forces every
    /// single tap to wait and see whether a second one follows.
    private var opensOnTap: Bool {
        // NOT gifs. A gif bubble has no tap action at all — it plays where it sits and opens
        // nothing — so there is no single tap for the double-tap recogniser to hold up, and the one
        // reason to give up the shortcut does not apply to it. Listing it here cost the gesture and
        // bought nothing, which is why double-tap to react did nothing on a gif (owner's report).
        //
        // FILES belong here too (owner order): tapping a file opens its preview, and the
        // double-tap recogniser made that tap wait for the maybe-second tap — a visible pause
        // before the document appeared. Reacting on a file is the long-press bar, like any other
        // bubble that opens on tap.
        message.isImage || message.isVideo || message.isAlbum || message.isFile
    }

    @ViewBuilder private var reactionBadges: some View {
        let all = reactionCounts
        if !all.isEmpty {
            let shown = Array(all.prefix(3))
            let extra = all.count - shown.count
            // A LITTLE BIGGER than it originally was (user 2026-07-29: "add small size not big" — a
            // small increase, not a large one). The growth is in the GLYPH, 12→14, with the capsule's
            // padding left where it was: the emoji is what you actually read at this size, and adding
            // padding instead would have inflated the capsule without making the reaction any easier
            // to see. The count follows at 11→12 so it stays subordinate to the emoji beside it.
            HStack(spacing: 4) {
                ForEach(shown, id: \.emoji) { r in
                    HStack(spacing: 3) {
                        Text(r.emoji).font(.system(size: 14))
                        if r.count > 1 {
                            Text("\(r.count)").font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(r.mine ? Color.accentColor : .secondary)
                        }
                    }
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(r.mine ? Color.accentColor.opacity(0.18) : Theme.received(dark), in: Capsule())
                    .overlay(Capsule().stroke(Color.accentColor.opacity(r.mine ? 0.9 : 0), lineWidth: 1))
                }
                if extra > 0 {
                    Text("+\(extra)").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(Theme.received(dark), in: Capsule())
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { onTapReactions() }
        }
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            if isMe { Spacer(minLength: 0) }
            // Group: sender avatar on the LEFT of others' messages (shown once, on the last
            // bubble of the cluster; space reserved above so the cluster stays aligned).
            if isGroup && !isMe {
                if isLastInCluster {
                    AvatarView(name: nameFor(message.authorId), photoUrl: avatarFor(message.authorId), size: 28)
                        .onTapGesture { onTapSender(message.authorId) }
                } else {
                    Color.clear.frame(width: 28, height: 1)
                }
            }
            VStack(alignment: isMe ? .trailing : .leading, spacing: 3) {
                // Sender name above others' messages in a group (colored, once per cluster).
                if isGroup && !isMe && isFirstInCluster {
                    HStack(spacing: 4) {
                        Text(nameFor(message.authorId))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(senderColor)
                        VerifiedMark(uid: message.authorId, size: 11)
                    }
                    .padding(.leading, 12)
                    .onTapGesture { onTapSender(message.authorId) }
                }
                // "Forwarded" tag — the owner's pick (the big messengers behavior, our drawing):
                // above the bubble like the group sender name, ONE insertion point for every
                // bubble type instead of patching each content branch.
                if message.forwarded {
                    HStack(spacing: 3) {
                        Image(systemName: "arrowshape.turn.up.right.fill").font(.system(size: 9))
                        Text("Forwarded").font(.system(size: 11)).italic()
                    }
                    .foregroundStyle(.secondary)
                    .padding(isMe ? .trailing : .leading, 12)
                }
                // Status reply: caption + BIG story card floating on the wallpaper ABOVE the bubble
                // (reference look, our own take) — replaces the small in-bubble quote for status replies.
                if let reply = message.replyTo, reply.isStatus {
                    // The card is part of the message: it rides the reply-swipe with the bubble
                    // and swiping the card itself also starts the reply (user report: only the
                    // bubble responded, the photo was deaf).
                    storyReplyHeader(reply)
                        .offset(x: dragX)
                        .simultaneousGesture(replySwipeGesture)
                }
                content
                    // Jump-to flash: a brief dim pulse using the bubble's OWN shape + cluster corners, so
                    // it covers exactly the bubble with no generic-rounded-rect over/under-hang (user
                    // report). On content (not the outer row) so it hugs the bubble and rides the swipe
                    // offset; reactions/sender-name stay un-dimmed like the reference app.
                    .overlay(
                        UnevenRoundedRectangle(cornerRadii: bubbleCorners, style: .continuous)
                            .fill(Color.primary.opacity(isHighlighted ? 0.18 : 0))
                            .allowsHitTesting(false)
                    )
                    // Tappable links/usernames inside the bubble route through here. The "Open link?"
                    // confirm + user-not-found alert are presented ONCE at the ThreadView level (via
                    // onConfirmLink/onUserNotFound) — not per bubble.
                    .environment(\.openURL, OpenURLAction { url in routeTappedURL(url) })
                    // DELETED HERE (experiment): the SwiftUI .contextMenu. Long press for EVERY row is
                    // presented by the custom system (CMContextMenu.swift) — the list snapshots this
                    // bubble and lays out bar · message · menu itself. The items moved verbatim into
                    // ThreadView.customMenuActions(for:). This modifier is what tells the list where
                    // the bubble actually is, so the press lifts the BUBBLE, not the whole row.
                    .modifier(CMBubbleRectReporter(id: message.rowId, radius: 18,
                                                   // reaction badge hangs 13pt below the bubble — the
                                                   // lift must crop that deep or it slices the badge
                                                   bottomOverhang: reactionCounts.isEmpty ? 0 : 13))
                    // Double-tap to quick-react. The emoji is the user's choice (Settings > Appearance >
                    // Quick Reaction), read here AND in uikitQuickReact so both row paths agree.
                    //
                    // NOT ON MEDIA (user 2026-07-29: "video and images please remove double tap react,
                    // I need to open fast"). A double-tap recogniser makes every SINGLE tap wait to find
                    // out whether a second one is coming — that wait is unavoidable, it is how tap
                    // counting works — so on a photo or a video it sat between the tap and the viewer
                    // opening. Text has nothing to open, so the wait costs it nothing and it keeps the
                    // shortcut; media pays for it on every single tap, which is the common action.
                    // Reacting to media is still there through long press, where the bar now lives.
                    .highPriorityGesture(
                        TapGesture(count: 2).onEnded {
                            guard message.sendState == nil, !restricted, !message.deleted else { return }   // not until on server; muted can't react
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            let quick = QuickReaction.current
                            onReact(myReaction == quick ? nil : quick)
                        },
                        // `.subviews` = this gesture is off, the media's own tap still fires.
                        including: opensOnTap ? .subviews : .all
                    )
                    // REACTIONS HANG OFF THE BUBBLE'S EDGE, not in the gap below it (user: a badge
                    // floating between two bubbles belongs to neither, so you cannot tell WHICH
                    // message was reacted to — his circled screenshots). The standard messengers both
                    // attach it to the bubble, overlapping the corner it belongs to: trailing for my
                    // messages, leading for theirs. The overlay MUST come BEFORE .offset(dragX) or it
                    // is aligned to the un-moved layout frame and the swipe leaves it parked (the
                    // owner's question caught exactly that: it was ordered after, so it never rode).
                    .overlay(alignment: isMe ? .bottomTrailing : .bottomLeading) {
                        reactionBadges
                            // Follows the badge's height: a taller badge hangs a little further, or it
                            // would ride up over the bubble's corner instead of off it.
                            .offset(x: isMe ? -10 : 10, y: 13)
                            .animation(.spring(response: 0.35, dampingFraction: 0.6), value: message.reactions)
                    }
                    // SWIPE-TO-REPLY (build-285 model, restored): move the bubble via SwiftUI .offset
                    // INSIDE the cell — the cell frame never changes, so neighbors can't drift and
                    // nothing duplicates. Only SwiftUI-hosted bubbles (reply/image/video/etc.) render
                    // MessageBubble; native text cells keep the UIKit pan. The reply arrow sits in the
                    // vacated space (added after the offset so it stays put). Applied AFTER the badge
                    // overlay, so bubble and badge slide as one.
                    .offset(x: dragX)
                    .simultaneousGesture(replySwipeGesture)
                    // Reserve the overhang so the badge cannot collide with the next bubble. Measured
                    // by the sizer like any other row content, so heights stay honest.
                    // Matches the overhang above — reserve less than the badge hangs and it collides
                    // with the next bubble, reserve more and there is a gap nothing draws into.
                    .padding(.bottom, reactionCounts.isEmpty ? 0 : 13)   // pop in/out
                if isMe && message.sendState == .failed {
                    Button { onResend(message) } label: {
                        Label("Not delivered. Tap to retry", systemImage: "arrow.clockwise")
                            .font(.system(size: 11, weight: .medium)).foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 1)
                }
            }
            // (Jump-to flash moved onto `content` above so it uses the bubble's exact shape + cluster
            // corners — this row-level generic rounded rect over/under-hung the actual bubble.)
            .frame(maxWidth: maxBubbleWidth, alignment: isMe ? .trailing : .leading)
            if !isMe { Spacer(minLength: 0) }
        }
        .animation(.easeInOut(duration: 0.4), value: isHighlighted)   // smooth found-result fade (reference-like)
        // Reply arrow at a FIXED spot inside the right edge (not riding the bubble → never off-screen).
        // It fades/scales in with the swipe distance and is revealed in the gap the bubble vacates.
        .overlay(alignment: .trailing) {
            Image(systemName: "arrowshape.turn.up.left.fill")
                .font(.system(size: 16)).foregroundStyle(.secondary)
                .opacity(Double(min(abs(min(dragX, 0)) / 50, 1)))
                .scaleEffect(0.7 + 0.3 * min(abs(min(dragX, 0)) / 50, 1))
                .padding(.trailing, 14)   // consistent inset from the screen's right edge, always visible
                .allowsHitTesting(false)
        }
    }

    // The build-285 reply-swipe, shared by the bubble AND the story-reply card so the whole
    // message answers the gesture as one piece.
    private var replySwipeGesture: some Gesture {
        DragGesture(minimumDistance: 18)
            .onChanged { v in
                // No reply-swipe on a tombstone: there is nothing to quote, and the composer would
                // open a reply box pointing at "You deleted this message" (owner report). Gated here
                // at the movement source — dragX never moves, so onEnded can never fire a reply.
                guard message.sendState == nil, !message.deleted, !VoiceScrubState.active else { return }
                // THE WAVEFORM IS A NO-REPLY ZONE (user's "red area"). Refused for the whole touch,
                // whichever way it goes, because the flag is raised on the waveform's first movement -
                // earlier than this gesture's own 18pt threshold. Ownership, not arbitration: the two
                // gestures are both simultaneous, so racing them is what kept failing. The rest of the
                // voice card still swipes to reply normally.
                guard !VoiceScrubState.touchOnWaveform else { return }
                // AXIS DECIDED ONCE PER TOUCH, THEN FOLLOW EVERY FRAME. The old per-frame
                // `abs(w) > abs(h)` guard froze the bubble on any frame where the finger drifted more
                // vertically than horizontally mid-swipe — stale offset for a frame, then a catch-up
                // jump, which is the "not smooth, not following my finger" report. A UIKit pan decides
                // its axis at recognition and then never re-litigates it; this now does the same.
                if !swipeFollowing {
                    guard abs(v.translation.width) > abs(v.translation.height) else { return }
                    swipeFollowing = true
                }
                // CLAMP THE VALUE, DO NOT GATE THE ASSIGNMENT (the swipe-back fix, kept).
                //
                // REBASE BY THE ACTIVATION DISTANCE: `translation` counts from TOUCH-DOWN, but this
                // gesture only begins after 18pt of travel — so the bubble's first rendered frame
                // teleported 18pt to catch up with the finger. The UIKit pan's translation starts at
                // zero at recognition, which is why plain text felt right and media bubbles did not.
                // Same gesture, same app, one coordinate base apart.
                let t = min(0, v.translation.width + 18)
                dragX = t > -70 ? t : -70 + max(-30, (t + 70) * 0.25)   // rubber-band past -70
                // Buzz the INSTANT the swipe crosses the commit point, so the finger feels that a
                // reply is armed — and again (once) if you pull back under it. This is what the plain
                // text cells (the UIKit swipe path) already did; media/voice/reply bubbles only
                // buzzed after release, so on those you couldn't feel the threshold at all.
                if dragX <= -50, !swipeArmed {
                    swipeArmed = true
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                } else if dragX > -50, swipeArmed {
                    swipeArmed = false
                }
            }
            .onEnded { _ in
                // If the waveform took over mid-drag, put the bubble back. The UIKit path calls
                // resetSwipe for exactly this case; the SwiftUI path just returned and left it offset.
                if VoiceScrubState.active, dragX != 0 {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.72)) { dragX = 0 }
                    swipeArmed = false
                }
                // ⚠️ THE BELT THAT USED TO CLEAR `touchOnWaveform` HERE IS GONE, AND IT HAD TO GO.
                //
                // It was written when the flag was raised by the waveform's `.began`, as insurance
                // against it sticking. The flag is now claimed at TOUCH-DOWN and released in the
                // recogniser's own `reset()`, which UIKit runs at the end of every gesture however
                // it finishes — so nothing can stick, and there is nothing left to insure.
                //
                // Worse, it is now a bug: this gesture ends at ITS threshold, which can be while the
                // finger is still down and still scrubbing. Clearing another live gesture's
                // ownership flag mid-gesture is the exact class of cross-ownership that produced the
                // report this fix is for. One owner, one lifetime.
                let fire = !VoiceScrubState.active && dragX <= -50
                swipeArmed = false
                swipeFollowing = false
                if fire { onReply(message) }   // haptic already fired at the threshold, don't double-buzz
                // Snappier, more physical return than the old 0.4/0.8 spring: it leaves the finger
                // quickly and settles without a floaty tail.
                withAnimation(.spring(response: 0.28, dampingFraction: 0.72)) { dragX = 0 }
            }
    }

    @ViewBuilder private var content: some View {
        // TOMBSTONE FIRST, ahead of every type test. The content fields are stripped server-side, so
        // a deleted photo would otherwise fall into the image branch with no url and draw an empty
        // grey box. The slashed circle and the italic are what make it read as "removed" rather than
        // as a message that failed to load.
        if message.deleted {
            // A deleted message is a NOTICE, not a message — so it must not wear the bubble. The
            // first version reused the bubble fill, which meant the sender's side took the chat
            // colour and the placeholder screamed in purple (owner screenshot, with the reference app's
            // quiet "You unsent a message" capsule as the reference). This is our own take on that
            // register: a fixed neutral capsule on BOTH sides — hairline ring, near-transparent
            // fill, secondary text — identical in every chat colour, still sitting on the sender's
            // side so the conversation flow keeps who-did-what. No time or tick: a notice has no
            // delivery state to report.
            HStack(spacing: 6) {
                Image(systemName: "trash.slash")
                    .font(.system(size: 12))
                    .foregroundStyle(isMe ? onMyBubble.opacity(0.8) : .secondary.opacity(0.7))
                Text(isMe ? "You deleted this message" : "This message was deleted")
                    .font(.system(size: 15))
                    .foregroundStyle(isMe ? onMyBubble : .secondary)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            // THE BUBBLE'S OWN FILL, no tint and no material (owner 2026-08-03, correcting the soft
            // tint he had just picked: "always use same color like other bubble, no different
            // colour, if i change color change it"). So: my side takes the chat colour exactly as a
            // message does, their side takes the received grey, and both follow a colour change the
            // moment it is made because they read the same `myFill` every other bubble reads.
            //
            // This deliberately reverses the neutral placeholder from 447 on his word. The reason it
            // went neutral then still stands and is worth knowing if it is ever reported again: a
            // placeholder in a vivid bubble is louder than the message it replaced. Two things keep
            // it quieter than the original version he rejected — it is still a CAPSULE rather than a
            // bubble, and it still carries no time and no tick.
            .background(isMe ? myFill : AnyShapeStyle(Theme.received(dark)), in: Capsule())
        } else if message.isAudio, message.viewOnce {
            // ONE-TIME VOICE: a pill, exactly the view-once photo's idiom further down this chain —
            // never the waveform player. The pill itself is live (it watches the engine for its one
            // listen); the bubble chrome here matches the photo pill's.
            OneTimeVoicePill(message: message, cid: cid, isMe: isMe, dark: dark,
                             consumed: isViewedOnce,
                             tint: isMe ? onMyBubble : (dark ? Color.white : .black),
                             meta: AnyView(metaRow),
                             // The photo pill's route: through onTapImage into the view-once
                             // cover, whose audio branch is the voice page and whose dismissal
                             // is the consumption mark.
                             onOpen: { onTapImage(message) })
                .padding(.horizontal, 15).padding(.vertical, 11)
                .background(isMe ? myFill : AnyShapeStyle(Theme.received(dark)))
                .clipShape(Capsule())
        } else if message.isAudio {
            // WIDTH-ON-PLAY ROOT CAUSE (deep dive): VoiceMessageView is a DETERMINISTIC 212pt wide (play
            // button 42 + HStack spacing 12 + waveform 158) in every playback state — the speed toggle sits
            // inside a 158-wide frame narrower than the waveform, so it can NEVER widen the bubble. The real
            // culprit was the `HStack { Spacer(minLength:0); metaRow }` I added for the timestamp: a greedy
            // Spacer inside the bubble. Its ideal width is 0 (first layout hugs 212), but on the cell
            // RECONFIGURE that fires when `player != nil` flips true on the first play, SwiftUI re-resolved
            // the Spacer toward the proposed maxBubbleWidth → that one bubble bloomed and ate the gap to its
            // neighbors. (Media bubbles never bloom because their metaRow is an .overlay, which doesn't
            // affect size.) Fix = pin the column to the known 212 and drop the Spacer: no flexible child
            // left to re-resolve, so the bubble is provably 212 before/during/after playback. metaRow
            // right-aligns via the VStack's .trailing alignment; the fixed frame also clamps replyQuote's
            // fill so nothing can bloom.
            // THE WIDTH IS STILL A CONSTANT, IT IS JUST NO LONGER THE SAME CONSTANT FOR EVERY NOTE.
            // `contentWidth` is worked out from the message's own `duration` and nothing else, so it is
            // identical at pre-measure and at render and in every playback state — which is the property
            // the bloom fix actually needed. (History: 212 fixed → grow-with-duration 154…202 →
            // back to FIXED at 238 on 2026-08-11 night, "people are adopted to the reference app's size" —
            // a constant satisfies the determinism rule trivially.)
            //
            // metaRow is no longer a row of its own here. It is handed INTO the voice view and laid over
            // the trailing edge of the duration line, so the clock and the duration share one line the
            // way both reference apps do. An overlay adds no size, which is the shape this very comment
            // says is safe.
            VStack(alignment: .leading, spacing: 4) {
                replyQuoteBox(fillWidth: true)
                VoiceMessageView(message: message, cid: cid, isMe: isMe, dark: dark,   // waveform scrub sets VoiceScrubState → the reply pan yields
                                 trailingMeta: { AnyView(metaRow) })
            }
            .frame(width: VoiceMessageView.contentWidth(for: message), alignment: .leading)
            .padding(.horizontal, 13)
            // 8: the middle of tonight's two orders — first "slim like the reference app" (7), then, after
            // living with it, "people are adopted to the reference app's size" (the fixed-wide, slightly
            // taller shape in VoiceMessageView).
            .padding(.vertical, 8)
            .background(isMe ? myFill : AnyShapeStyle(Theme.received(dark)))
            .clipShape(UnevenRoundedRectangle(cornerRadii: bubbleCorners, style: .continuous))
        } else if message.isFile {
            VStack(alignment: .leading, spacing: 4) {
                replyQuote
                // NOT a Button: inside the hosted cell a Button's press gesture claimed the touch, so
                // long-press (context menu) and swipe-to-reply never fired on file bubbles. A tap
                // gesture opens the file; everything else bubbles up normally.
                HStack(spacing: 10) {
                    // Spinner while the optimistic file is still uploading; then the reference-style
                    // page preview when the sender attached one (PDF first page / image file), and
                    // the plain document icon for every other type and for old messages.
                    // ONE tile size per file, before and after the send lands. The local preview is
                    // checked FIRST so an uploading PDF already shows its page at the same 44x58 the
                    // echo will use; a file with no preview keeps the 26pt slot in both states. Only
                    // the spinner moves between them, so the bubble never resizes mid-send.
                    if let d = message.localImageData, let ui = UIImage(data: d) {
                        Image(uiImage: ui).resizable().scaledToFill()
                            .frame(width: 44, height: 58)
                            .background(Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .stroke(Color.black.opacity(0.12), lineWidth: 0.5))
                            .overlay {
                                if message.sendState == .sending {
                                    ZStack {
                                        Color.black.opacity(0.25)
                                        ProgressView().progressViewStyle(.circular).tint(.white)
                                    }
                                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                                }
                            }
                    } else if let t = message.thumbUrl, !t.isEmpty {
                        SecureImageView(imageUrl: t, enc: message.thumbEnc, cid: cid)
                            .frame(width: 44, height: 58)
                            .background(Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .stroke(Color.black.opacity(0.12), lineWidth: 0.5))
                    } else if message.sendState == .sending {
                        ProgressView().progressViewStyle(.circular)
                            .tint(isMe ? onMyBubble : Color.accentColor)
                            .frame(width: 26, height: 26)
                    } else {
                        Image(systemName: "doc.fill").font(.system(size: 26))
                            .foregroundStyle(isMe ? onMyBubble : Color.accentColor)
                            .frame(width: 26, height: 26)   // same slot the spinner used
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(message.fileName ?? "Document")
                            .font(.system(size: 15, weight: .medium)).lineLimit(1)
                        Text(fileSizeLabel).font(.caption)
                            .foregroundStyle(isMe ? onMyBubble.opacity(0.8) : .secondary)
                    }
                }
                .foregroundStyle(isMe ? onMyBubble : (dark ? .white : .black))
                .contentShape(Rectangle())
                .onTapGesture { if message.sendState == nil { onOpenFile(message) } }   // only opened files
                HStack(spacing: 0) { Spacer(minLength: 0); metaRow }   // time+tick on files (was missing)
            }
            .padding(.horizontal, 13).padding(.vertical, 10)
            .background(isMe ? myFill : AnyShapeStyle(Theme.received(dark)))
            .clipShape(UnevenRoundedRectangle(cornerRadii: bubbleCorners, style: .continuous))
        } else if message.isGif {
            VStack(alignment: .leading, spacing: 4) {
                replyQuote
                if let url = message.imageUrl {
                    AnimatedGifView(url: url)
                        .frame(width: imageDisplaySize.width, height: imageDisplaySize.height)
                        .clipShape(UnevenRoundedRectangle(cornerRadii: bubbleCorners, style: .continuous))
                        // The UIKit-backed gif region isn't an interactive SwiftUI area, so long-press
                        // (context menu) and swipe-to-reply never engaged over it. A clear, hit-testable
                        // overlay makes SwiftUI own the region; touches then reach the ancestor gestures.
                        .overlay(Color.clear.contentShape(Rectangle()))
                        .overlay(alignment: .bottomTrailing) {
                            metaRow.padding(.horizontal, 7).padding(.vertical, 3)   // time+tick over the gif (was missing)
                                .background(.black.opacity(0.35), in: Capsule()).foregroundStyle(.white).padding(7)
                        }
                }
            }
        } else if message.isVideo {
            // ONE bubble: video on top, caption flush below sharing a single background + outline
            // as one unit — the caption was previously not rendered at all ("video + caption not
            // working"). With a caption the meta lives in the caption row; a bare video floats it.
            let hasCaption = !message.text.isEmpty
            VStack(alignment: .leading, spacing: 4) {
                replyQuote
                VStack(alignment: .leading, spacing: 0) {
                    Group {
                        if let data = message.localImageData, let ui = UIImage(data: data) {
                            Image(uiImage: ui).resizable().scaledToFill()          // optimistic local thumbnail
                        } else if let url = message.thumbUrl {
                            // The blurred poster while the thumbnail downloads, exactly as a photo
                            // bubble has done since BlurHash was added. It was never passed here, so
                            // a received video showed the grey shimmer even though the hash now
                            // travels with the message — see `sendVideo`.
                            SecureImageView(imageUrl: url, enc: message.thumbEnc, cid: cid,
                                            placeholderHash: message.blurhash)
                        } else {
                            Rectangle().fill(Color.gray.opacity(0.18))
                        }
                    }
                    .frame(width: videoBox.width, height: videoBox.height)
                    .clipped()
                    // Native zoom hero: the player grows out of this thumbnail and the drag-down close
                    // shrinks back into it (same as photos).
                    .modifier(MediaRectReporter(id: message.id, scope: .chat))   // live bubble rect
                    .overlay {   // upload ring while sending, play disc once delivered
                        if message.sendState == .sending {
                            ZStack { Color.black.opacity(0.18); UploadingRing(clientId: message.rowId) }
                        } else {
                            Image(systemName: "play.fill")
                                .font(.system(size: 22)).foregroundStyle(.white)
                                .padding(16)
                                .background(.black.opacity(0.45), in: Circle())
                        }
                    }
                    .overlay(alignment: .topLeading) {   // length chip, top corner
                        HStack(spacing: 4) {
                            Image(systemName: "video.fill").font(.system(size: 10))
                            Text(videoDurationLabel).font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(.black.opacity(0.35), in: Capsule())
                        .padding(7)
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if !hasCaption {
                            metaRow
                                .padding(.horizontal, 7).padding(.vertical, 3)
                                .background(.black.opacity(0.35), in: Capsule())
                                .foregroundStyle(.white)
                                .padding(7)
                        }
                    }
                    // The whole video rect must be the tap target, for the same reason the photo
                    // bubble says so twenty lines up: its thumbnail is a SecureImageView, which goes
                    // tap-transparent once loaded so its gated-download tap cannot block the viewer.
                    // Without this the parent had no hit area left and the only thing still taking
                    // touches was the play disc overlay — so the video opened when you hit the little
                    // circle and did nothing anywhere else (owner's report). The photo bubble was
                    // fixed for this once; the video bubble never was.
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if message.sendState == .failed { onResend(message) }
                        else if message.sendState == nil { onTapVideo(message) }   // only delivered videos play
                    }
                    // Caption INSIDE the same bubble (the caption is the message body).
                    if hasCaption { captionBody(width: videoBox.width) }
                }
                .frame(width: videoBox.width)
                .background(isMe ? myFill : AnyShapeStyle(Theme.received(dark)))
                .clipShape(UnevenRoundedRectangle(cornerRadii: bubbleCorners, style: .continuous))
            }
        } else if message.isAlbum {
            // Album (2+ photos as ONE message): a MOSAIC GRID inside the bubble + one caption.
            // Restored from `abde537^` at the user's request — that commit had replaced this with
            // fanned/tilted floating cards, which read as a messy scattered pile rather than the
            // clean grid every messenger uses.
            VStack(alignment: .leading, spacing: 0) {
                // HUG THE MOSAIC, don't force the full album width. The solver returns the exact block the
                // photos make, and for shapes that do not fill the width that block is narrower — pinning
                // the bubble to `albumWidth` left bare bubble down one side (user: "left and right empty
                // bubbles").
                //
                // The hug is on the GRID ALONE, and that is the fix for the overflowing caption
                // (2026-07-29). It used to sit on the whole VStack, which meant the caption `Text` was
                // asked for its IDEAL width too — and a Text's ideal width is the whole string on ONE
                // line. So a long caption made the stack's ideal width hundreds of points wider than the
                // screen; the outer `.frame(maxWidth: maxBubbleWidth)` could clamp the frame but not
                // re-wrap content that had already refused the proposal, so the bubble ran off the right
                // edge with its text cut (user: "if i add that caption image is using different width").
                albumGrid
                    .fixedSize(horizontal: true, vertical: false)
                // The caption wraps at the album's own width — never wider, so the bubble keeps a
                // definite size, and never narrower, so the timestamp stays on the trailing edge.
                if !message.text.isEmpty { captionBody(width: albumWidth) }
            }
            .background(isMe ? myFill : AnyShapeStyle(Theme.received(dark)))
            .clipShape(UnevenRoundedRectangle(cornerRadii: bubbleCorners, style: .continuous))
            // THE WHOLE-BUBBLE UPLOAD RING IS GONE (the agreed per-item spec): every sending tile
            // now carries its own ring, its own bytes and its own X — see `albumTile`. One ring
            // centred on the bubble could not say which image was slow, could not cancel one of
            // them, and its centre fought the play badge's (the build-458 smear).
            .overlay(alignment: .bottomTrailing) {
                // No caption → the time floats on the grid, like a bare photo bubble.
                if message.text.isEmpty {
                    metaRow.padding(.horizontal, 7).padding(.vertical, 3)
                        .background(.black.opacity(0.35), in: Capsule()).foregroundStyle(.white).padding(7)
                }
            }
        } else if message.isImage, message.viewOnce {
            // View-once photo: never rendered inline — a "① Photo" pill. The recipient taps it
            // to open the full-screen viewer EXACTLY once; after that it reads "Viewed" and is inert.
            // The sender's own pill is always inert (senders can't reopen).
            let viewed = isViewedOnce
            HStack(spacing: 8) {
                Image(systemName: viewed ? "circle.slash" : "1.circle")
                    .font(.system(size: 18, weight: .semibold))
                Text(viewed ? "Viewed" : "Photo")
                    .font(.system(size: 15, weight: .medium)).italic(viewed)
                metaRow   // time on EVERY bubble — the received pill was the one exception (audit)
            }
            .foregroundStyle((isMe ? onMyBubble : (dark ? Color.white : .black)).opacity(viewed ? 0.6 : 1))
            .padding(.horizontal, 15).padding(.vertical, 11)
            .background(isMe ? myFill : AnyShapeStyle(Theme.received(dark)))
            .clipShape(Capsule())
            .contentShape(Capsule())
            .onTapGesture {
                guard !isMe, !viewed, message.sendState == nil else { return }
                onTapImage(message)   // ThreadView marks it viewed when the viewer closes
            }
            // DOUBLE-TAP REACT, but ONLY where the single tap above is inert: your own view-once
            // photo, or one already viewed. Both are cases where a tap does nothing today, so there
            // is nothing to delay and nothing to mis-fire.
            //
            // Deliberately NOT offered on a received, unviewed one. A single tap there OPENS AND
            // CONSUMES the photo, and adding tap-counting would make every open wait to see whether
            // a second tap is coming — the same reason the ordinary photo bubble denies itself this
            // and hands it to the caption instead. A view-once pill has no caption, so the choice is
            // react or instant open, and instant open wins on the one that can be burned.
            // Long-press still reaches the reaction bar in every case.
            .highPriorityGesture(
                TapGesture(count: 2).onEnded {
                    guard isMe || viewed, message.sendState == nil, !restricted, !message.deleted else { return }
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    let quick = QuickReaction.current
                    onReact(myReaction == quick ? nil : quick)
                },
                including: (isMe || viewed) ? .all : .subviews
            )
        } else if message.isImage {
            // ONE bubble: the photo on top, the caption flush below, sharing a
            // single background + a single rounded outline — never two separate bubbles.
            // Media sizing algorithm (our own measure rules):
            // aspect clamped to [0.35, 2.857] (very tall/wide images clamp, squares fill
            // the box), the box height caps at the max media width, the CAPTION reserves only a MIN-width
            // floor (it never stretches or distorts the media beyond that), tiny originals never upscale,
            // and the caption wraps at the bubble width with 12pt insets.
            let hasCaption = !message.text.isEmpty
            let box: CGSize = {
                let boxMax = min(maxBubbleWidth, 350)   // max media message width cap
                let aspect: CGFloat = {
                    guard let w = message.width, let h = message.height, w > 0, h > 0 else { return 1 }
                    return min(max(CGFloat(w / h), 0.35), 2.857)
                }()
                // Caption min-width floor: single-line caption width + 2×12pt text insets, capped at the box.
                // MEASURED AT 17, the size the caption actually renders at below — it used to measure at
                // 15, so every floor came out ~12% short and a caption that would have fitted on one line
                // wrapped early, leaving the dead space at the end of the line the user photographed.
                let minW: CGFloat = hasCaption
                    ? min(boxMax, (message.text as NSString).size(withAttributes: [.font: UIFont.systemFont(ofSize: 17)]).width + 24)
                    : 0
                var w = boxMax * aspect, h = boxMax
                w = max(w, minW)
                if w > boxMax { w = boxMax; h = boxMax / aspect }
                // Anti-upscale: never enlarge a tiny original (but never drop below 150pt either).
                if let sw = message.width, let sh = message.height {
                    let srcShort = CGFloat(min(sw, sh)), dispShort = min(w, h)
                    if dispShort > srcShort, dispShort > 150 {
                        let f = max(150, srcShort) / dispShort
                        w *= f; h *= f
                    }
                }
                return CGSize(width: w.rounded(), height: h.rounded())
            }()
            VStack(alignment: .leading, spacing: 4) {
                replyQuote
                VStack(alignment: .leading, spacing: 0) {
                    Group {
                        if let data = message.localImageData, let ui = UIImage(data: data) {
                            Image(uiImage: ui).resizable().scaledToFill()          // optimistic local photo
                        } else if let url = message.imageUrl {
                            SecureImageView(imageUrl: url, enc: message.enc, cid: cid,
                                            placeholderHash: message.blurhash,     // blurred preview while downloading
                                            gated: true)   // photos auto-download policy can hold this until tapped
                        } else {
                            Rectangle().fill(Color.gray.opacity(0.18))
                        }
                    }
                    .frame(width: box.width, height: box.height)
                    .clipped()   // a tall captioned photo fills+crops — never bleeds over the caption below
                    // Native zoom hero (same mechanism as the story close): the viewer grows out of this
                    // bubble and the drag-down dismiss shrinks back into it, following the finger.
                    .modifier(MediaRectReporter(id: message.id, scope: .chat))   // live bubble rect
                    .overlay {   // clean upload indicator (ring in a frosted disc)
                        if message.sendState == .sending {
                            ZStack {
                                Color.black.opacity(0.18)
                                UploadingRing(clientId: message.rowId)
                            }
                        }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        // With a caption the time lives in the caption row; on a bare photo it floats on the image.
                        if !hasCaption {
                            metaRow
                                .padding(.horizontal, 7).padding(.vertical, 3)
                                .background(.black.opacity(0.35), in: Capsule())
                                .foregroundStyle(.white)
                                .padding(7)
                        }
                    }
                    // The whole photo rect must be the tap target. SecureImageView goes
                    // tap-transparent once loaded (allowsHitTesting(waitingTap)) so its gated-download
                    // tap doesn't block the viewer — but without this contentShape the parent had no
                    // hit area left, so tapping a loaded photo did nothing (couldn't open the viewer).
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if message.sendState == .failed { onResend(message) }
                        else { onTapImage(message) }   // uploading photos open too — the viewer shows the local copy
                    }
                    // Caption INSIDE the same bubble (the caption is the message body).
                    if hasCaption { captionBody(width: box.width) }
                }
                .frame(width: box.width)
                .background(isMe ? myFill : AnyShapeStyle(Theme.received(dark)))
                .clipShape(UnevenRoundedRectangle(cornerRadii: bubbleCorners, style: .continuous))
            }
        } else if let poll = message.poll {
            // POLL: question + options with live vote bars. Content is E2EE (rides the encrypted text
            // marker); votes live in a per-voter subcollection. Renders in a normal bubble.
            VStack(alignment: .leading, spacing: 8) {
                PollBubbleContent(poll: poll, cid: cid, messageId: message.id, isMe: isMe, dark: dark)
                HStack { Spacer(); metaRow }
            }
            .foregroundStyle(isMe ? onMyBubble : (dark ? .white : .black))
            .padding(12)
            .frame(width: maxBubbleWidth * 0.9)
            .background(isMe ? myFill : AnyShapeStyle(Theme.received(dark)))
            .clipShape(UnevenRoundedRectangle(cornerRadii: bubbleCorners, style: .continuous))
        } else if let loc = message.locationCard {
            // SHARED LOCATION card: pin + label + coordinates; tap opens Apple Maps at the spot.
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: "mappin.circle.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(.red, isMe ? Color.white : Color.primary.opacity(0.9))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(loc.label ?? "Location").font(.system(size: 16, weight: .semibold)).lineLimit(1)
                        Text(String(format: "%.5f, %.5f", loc.lat, loc.lon))
                            .font(.caption).opacity(0.8)
                    }
                    Spacer(minLength: 6)
                    Image(systemName: "chevron.right").font(.system(size: 14, weight: .semibold)).opacity(0.7)
                }
                HStack { Spacer(); metaRow }
            }
            .foregroundStyle(isMe ? onMyBubble : (dark ? .white : .black))
            .padding(12)
            .frame(width: maxBubbleWidth * 0.85)
            .background(isMe ? myFill : AnyShapeStyle(Theme.received(dark)))
            .clipShape(UnevenRoundedRectangle(cornerRadii: bubbleCorners, style: .continuous))
            .contentShape(Rectangle())
            .onTapGesture {
                let q = (loc.label ?? "Shared Location").addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "Location"
                if let u = URL(string: "http://maps.apple.com/?ll=\(loc.lat),\(loc.lon)&q=\(q)") {
                    UIApplication.shared.open(u)
                }
            }
        } else if let card = message.contactCard {
            // SHARED CONTACT card (user design): avatar + name + chevron, time+ticks, and a full-width
            // "message" pill that opens a chat with that contact. Rides the normal encrypted text
            // pipeline (a "fariin-contact:" marker), so no new message fields / rules changes.
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    AvatarView(name: card.name, photoUrl: card.photo, size: 44)
                    Text(card.name).font(.system(size: 17, weight: .semibold)).lineLimit(1)
                    // A shared contact is a recommendation from somebody you trust, which is exactly
                    // the shape a con takes. The mark belongs on the card, not only on the profile
                    // it opens.
                    VerifiedMark(uid: card.uid, size: 14)
                    Spacer(minLength: 6)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold)).opacity(0.7)
                }
                HStack { Spacer(); metaRow }
                Text("message")
                    .font(.system(size: 16, weight: .medium))
                    .frame(maxWidth: .infinity).frame(height: 40)
                    .background((isMe ? Color.white.opacity(0.22) : Color.primary.opacity(0.08)), in: Capsule())
                    .contentShape(Capsule())
                    .onTapGesture { onTapContact(card.uid, card.name, card.photo) }
            }
            .foregroundStyle(isMe ? onMyBubble : (dark ? .white : .black))
            .padding(12)
            .frame(width: maxBubbleWidth)
            .background(isMe ? myFill : AnyShapeStyle(Theme.received(dark)))
            .clipShape(UnevenRoundedRectangle(cornerRadii: bubbleCorners, style: .continuous))
        } else if jumbomojiCount > 0, message.replyTo == nil || message.replyTo?.isStatus == true,
                  firstLinkURL == nil {
            // JUMBOMOJI — the reference app's behaviour, read from their source (2026-07-28) rather than eyeballed.
            //
            //   From the reference implementation (display-text sizing):
            //     public static let kMaxJumbomojiCount: Int = 5
            //     guard string.containsOnlyEmojiIgnoringWhitespace else { return 0 }
            //     let emojiCount = string.removeCharacters(characterSet: .whitespacesAndNewlines).count
            //     if emojiCount > kMaxJumbomojiCount { return 0 }
            //
            //   From the reference implementation (body-text font sizing) — multipliers on the body point size:
            //     1 → 3.5   2 → 3.0   3 → 2.75   4 → 2.5   5 → 2.25
            //
            //   From the reference implementation (message state):
            //     var isBorderlessJumbomojiMessage: Bool {
            //         isTextOnlyMessage && (bodyText?.isJumbomojiMessage == true)
            //     }
            //
            // Three things that fall out of those and are easy to get wrong: SIX or more emoji is a
            // completely ordinary message with a bubble (not "capped at 5"); whitespace is ignored for
            // the emoji-only test AND stripped before counting, so "🙂 🙂" is two; and borderless applies
            // only to a TEXT-ONLY message, so an emoji-only REPLY keeps its bubble — which is why the
            // quote and link-preview cases are excluded here rather than inside the count.
            //
            // EXCEPT a STORY reply (owner order): its quote is the card drawn ABOVE the bubble by
            // storyReplyHeader, never inside content — so nothing shares the bubble with the emoji
            // and there is no reason to box it. An emoji story reply renders exactly like an emoji
            // message, card on top.
            //
            // the reference app's borderless message keeps the bubble VIEW and makes it transparent
            // (isBubbleTransparent), so the text insets and the footer position are unchanged. Same here:
            // only the fill is dropped, so spacing and alignment match an ordinary bubble exactly.
            VStack(alignment: .trailing, spacing: 2) {
                Text(message.text)
                    .font(.system(size: Self.jumbomojiPointSize(jumbomojiCount)))
                    .foregroundColor(isMe ? onMyBubble : (dark ? .white : .black))
                metaRow
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 10)
        } else {
            // Single-column Grid (the reference structure, ONE layout pass): the column hugs the WIDEST
            // row (usually the body text), and the reply quote's maxWidth:.infinity fills that column —
            // so a one-character reply never collapses into a tiny box above a wide message, and a long
            // quote still widens the bubble. This replaces the measured quoteFillWidth preference, which
            // broke inside the hosted cells (state reset on reconfigure + the pre-measured first pass
            // rendered before the measurement existed → the tiny box came back).
            // THE REFERENCE APP'S QUOTE/BUBBLE SIZING MODEL (verified from the reference implementation
            // source): MEASURE every part at its NATURAL width (quote truncates when long), the bubble
            // hugs the WIDEST part; RENDER with fill — the quote stretches to that hugged width.
            // In SwiftUI: an invisible natural-width TEMPLATE defines the hug (it wraps normally at the
            // proposed 72% cap, so long text + the timestamp reservation behave exactly like a plain
            // bubble — the fixedSize attempt fed the text its UNWRAPPED ideal, which clipped it and
            // painted the time over the words); the VISIBLE copy overlays it and fills. The overlay
            // cannot influence the host's size, so nothing is greedy. Quote internals untouched; its
            // one-line snippet keeps template and visible heights identical.
            VStack(alignment: .leading, spacing: 4) {
                replyQuote   // NATURAL width — measurement only (its 150pt floor applies)
                if let lp = message.linkPreview {
                    // Only what TRAVELLED with the message renders (the reference app's model) — no viewer-side
                    // fetch, so old messages without an embedded preview stay plain links.
                    LinkPreviewCard(preview: lp, cid: cid, isMe: isMe, dark: dark)
                }
                bodyLine     // natural width, wraps at the proposed bubble cap
            }
            .opacity(0)                       // template: measured, never seen
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 4) {
                    // FILL the hugged width — and it has to be the quote's OWN fillWidth knob, not a
                    // .frame() from out here. replyQuoteBox applies its tint with .background() at the end
                    // of its own chain, so a frame added by the caller lands AFTER the background is
                    // already sized: the box stayed content-sized and merely sat leading-aligned in a wider
                    // slot, leaving bare bubble to its right whenever the BODY was the wider part (user
                    // report: "when I reply short text the reply quote looks half, right side"). Same trap
                    // the voice bubble hit, which is why fillWidth exists.
                    replyQuoteBox(fillWidth: true)
                    // The embedded link-preview card (sender-fetched, travelled with the message).
                    if let lp = message.linkPreview {
                        LinkPreviewCard(preview: lp, cid: cid, isMe: isMe, dark: dark)
                    }
                    // Text + time: the invisible trailing reservation + overlaid time (the reference app does the
                    // same body/footer overlap). FILLED like the quote (user report): when the QUOTE
                    // drives the bubble width, an unstretched body line kept its trailing edge — and the
                    // time — mid-bubble; filling anchors the time to the bubble's right edge, always.
                    bodyLineFilled
                }
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 10)
            .background(isMe ? myFill : AnyShapeStyle(Theme.received(dark)))
            .clipShape(UnevenRoundedRectangle(cornerRadii: bubbleCorners, style: .continuous))
        }
    }

    private var albumWidth: CGFloat { min(maxBubbleWidth, 300) }

    // Aspect (w/h) of album item i, for choosing the mosaic arrangement. 1 (square) when unknown.
    private func albumAspect(_ i: Int) -> CGFloat {
        if message.album.indices.contains(i), message.album[i].height > 0 {
            return CGFloat(message.album[i].width / message.album[i].height)
        }
        // THE OPTIMISTIC ALBUM HAS NO `album` YET — it only has `localAlbum`, the preview JPEGs. Falling
        // through to 1 here meant every pending photo measured as a SQUARE, so the mosaic solved one
        // arrangement while sending and a completely different one the moment the server echo arrived
        // with real dimensions. That is the user's "pending uses one design, after sending uses another".
        //
        // The previews are the same pictures, so their proportions are already correct — read them
        // instead of guessing. Decoding just the header is enough for a size, and the result is cached by
        // the row's measured height, so this does not run per frame.
        if message.localAlbum.indices.contains(i),
           let ui = UIImage(data: message.localAlbum[i]), ui.size.height > 0 {
            return ui.size.width / ui.size.height
        }
        return 1
    }

    // Album MOSAIC (not a uniform grid): 2 = side-by-side (or stacked when the shots are
    // wide), 3 = one large + two stacked, 4 = 2×2, 5+ = 2×2 with a "+N" on the last. Photos crop-to-fill
    // their cells; the caption rides below in the SAME bubble (handled by the album branch).
    // Portrait card for the stacked-album look (4:5, capped to the bubble width).
    private var albumCardSize: CGSize {
        let w = min(maxBubbleWidth * 0.70, 228)
        return CGSize(width: w, height: (w * 1.16).rounded())
    }

    // ONE photo card: image cropped to Apple continuous ("squircle") rounded corners, NO border, with a soft
    // shadow so the stacked cards separate. Each card is its own zoom-hero source (matches the viewer covers).
    private func albumCard(_ i: Int, _ size: CGSize) -> some View {
        albumImage(i)
            .frame(width: size.width, height: size.height)
            .overlay {
                if albumItemIsVideo(i) {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: min(size.width, size.height) * 0.22))
                        .foregroundStyle(.white.opacity(0.95)).shadow(color: .black.opacity(0.4), radius: 3)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .shadow(color: .black.opacity(0.18), radius: 4, x: 0, y: 2)
            // Album tiles reported a hero anchor but never a LIVE RECT, so drag-closing an album
            // photo had no destination: the copy drifted off into nothing instead of flying back
            // to its tile, which is what single photos have done all along.
            // 22 = the tile's own clip radius above; the modifier's 14 default made the copy land on a
            // rounder shape than the tile it was flying into.
            .modifier(MediaRectReporter(id: "\(message.id)-\(i)", scope: .chat, cornerRadius: 22))
    }

    // The image/poster content of an album item (local optimistic bytes, else the decrypted remote photo).
    @ViewBuilder private func albumImage(_ i: Int) -> some View {
        if !message.localAlbum.isEmpty, message.localAlbum.indices.contains(i), let ui = UIImage(data: message.localAlbum[i]) {
            Image(uiImage: ui).resizable().scaledToFill()
        } else if message.album.indices.contains(i) {
            let it = message.album[i]
            // The message carries ONE blur hash, taken from the first tile, so only the first tile
            // can honestly use it. Giving every tile the first one's blur would show people a sketch
            // of the wrong photo, which is worse than a plain hold.
            SecureImageView(imageUrl: it.imageUrl, enc: it.enc, cid: cid,
                            placeholderHash: i == 0 ? message.blurhash : nil)
        } else {
            Rectangle().fill(Color.gray.opacity(0.18))
        }
    }

    // Stacked / fanned cards. 2–3 photos FAN OUT (front card centered, the rest tilted behind, peeking left/
    // right); 4+ form a DECK (up to 4 cards, subtle alternating rotation + outward offset for depth). Front
    // card is always the first photo, on top. Tapping the stack opens the full album gallery.
    @ViewBuilder private func albumStack(_ n: Int) -> some View {
        let s = albumCardSize
        ZStack {
            if n <= 2 {
                // Peek the back card INWARD (away from the screen edge the bubble hugs) so its tilted
                // corner is never clipped: my messages hug the right → back card leans left; received hug
                // the left → back card leans right.
                if n == 2 { albumCard(1, s).rotationEffect(.degrees(isMe ? -7 : 7)).offset(x: isMe ? -18 : 18, y: 6) }
                albumCard(0, s)
            } else if n == 3 {
                // Loose organic fan (reference): two cards spread UP-and-OUT behind, tilted; the front card
                // sits lower-center with a slight lean, overlapping both.
                albumCard(1, s).rotationEffect(.degrees(-14)).offset(x: -30, y: -14)   // back left
                albumCard(2, s).rotationEffect(.degrees(8)).offset(x: 34, y: -6)       // back right
                albumCard(0, s).rotationEffect(.degrees(3)).offset(x: 2, y: 16)        // front, on top
            } else {
                let visible = min(n, 4)
                ForEach(Array((1..<visible).reversed()), id: \.self) { i in
                    let dir: CGFloat = (i % 2 == 1) ? -1 : 1
                    albumCard(i, s)
                        .rotationEffect(.degrees(Double(dir) * (5 + Double(i) * 1.5)))
                        .offset(x: dir * CGFloat(16 + i * 5), y: CGFloat(-6 - i * 2))
                }
                albumCard(0, s)                                    // front, on top
            }
        }
        .padding(.horizontal, n <= 2 ? 16 : 46)   // room for the tilt/peek so it isn't clipped by neighbors
        .padding(.vertical, n <= 2 ? 12 : 30)
        .contentShape(Rectangle())
        .onTapGesture { if message.sendState == nil { openAlbumItem(0) } }
    }

    // THE MOSAIC, driven by the photos' real shapes (MediaGroupLayout, which is the reference app's algorithm
    // written as our own code — see that file's header).
    //
    // What this replaces: a switch on the COUNT with hardcoded fractions (W * 0.56, c * 1.2, 2x2 squares)
    // and a single `wide = albumAspect(0) > 1.15` test on the FIRST photo only. Every album therefore came
    // out roughly square whatever was in it, and nine tall photos and nine wide photos produced the same
    // grid (user: "Dont use always square, it must use the size of the picture").
    //
    // Now every item's aspect goes in, the solver returns exact frames, and they are placed absolutely.
    // Stacks cannot express this: a row's height depends on the ratios of the items IN it, so the
    // arrangement is solved first and laid out second.
    /// REAL album indices still visible to me. "Delete for Me" on one photo hides the synthetic
    /// "<messageId>-<index>" id, and every gallery honors that (expandedGalleryItems) — the chat's
    /// own grid was the last place the deleted photo still showed (audit). The solver keeps working
    /// on a plain 0..<count list; only the mapping back to the real item changes.
    private var visibleAlbumIndices: [Int] {
        let count = message.localAlbum.isEmpty ? message.album.count : message.localAlbum.count
        guard message.localAlbum.isEmpty else { return Array(0..<count) }   // optimistic: nothing hidden yet
        return (0..<count).filter { !HiddenMessages.isHidden("\(message.id)-\($0)") }
    }

    @ViewBuilder private var albumGrid: some View {
        let visible = visibleAlbumIndices
        let n = max(visible.count, 2)
        let shown = min(n, 10)   // the reference app's album ceiling; anything beyond rides a "+N" on the last tile
        let sizes = (0 ..< shown).map { CGSize(width: albumAspect(visible[safe: $0] ?? $0), height: 1) }
        // A square box: the width is the bubble's, and the height only bounds the hand-tuned 2/3/4
        // arrangements, exactly as the reference app bounds them.
        let solved = MediaGroupLayout.solve(itemSizes: sizes,
                                            maxSize: CGSize(width: albumWidth, height: albumWidth))
        ZStack(alignment: .topLeading) {
            ForEach(solved.tiles, id: \.index) { tile in
                // tile.index is a DISPLAY slot; everything below wants the real album index.
                albumTile(visible[safe: tile.index] ?? tile.index, tile.rect.width, tile.rect.height,
                          extra: tile.index == shown - 1 ? n - shown : 0)
                    .offset(x: tile.rect.minX, y: tile.rect.minY)
            }
        }
        .frame(width: solved.size.width, height: solved.size.height, alignment: .topLeading)
    }

    // Is album item `i` a video? (works for both the optimistic bubble and the delivered message)
    private func albumItemIsVideo(_ i: Int) -> Bool {
        if message.localAlbumIsVideo.indices.contains(i) { return message.localAlbumIsVideo[i] }
        if message.album.indices.contains(i) { return message.album[i].isVideo }
        return false
    }

    private func albumTile(_ i: Int, _ w: CGFloat, _ h: CGFloat, extra: Int = 0) -> some View {
        Group {
            if !message.localAlbum.isEmpty, message.localAlbum.indices.contains(i), let ui = UIImage(data: message.localAlbum[i]) {
                Image(uiImage: ui).resizable().scaledToFill()
            } else if message.album.indices.contains(i) {
                let it = message.album[i]
                // First tile only — see the note in `albumImage`.
                SecureImageView(imageUrl: it.imageUrl, enc: it.enc, cid: cid,
                                placeholderHash: i == 0 ? message.blurhash : nil)   // photo, or video poster
            } else {
                Rectangle().fill(Color.gray.opacity(0.18))
            }
        }
        .frame(width: w, height: h).clipped()
        .overlay {
            // Video item → a play glyph + duration badge over its poster.
            //
            // NOT WHILE THE ALBUM IS STILL UPLOADING — the tile shows ITS OWN upload ring then (the
            // agreed per-item spec; the whole-bubble ring whose centre fought this badge's is gone).
            // A play badge means "this is ready, tap it", which is not true mid-upload anyway.
            if albumItemIsVideo(i), extra == 0, message.sendState != .sending {
                ZStack {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: min(w, h) * 0.28))
                        .foregroundStyle(.white.opacity(0.95))
                        .shadow(color: .black.opacity(0.4), radius: 3)
                    if message.album.indices.contains(i), message.album[i].duration > 0 {
                        VStack { Spacer(); HStack {
                            Text(albumVideoDuration(message.album[i].duration))
                                .font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(.black.opacity(0.5), in: Capsule())
                            Spacer()
                        } }.padding(5)
                    }
                }
            }
            // WHILE SENDING: this tile's own ring, filling with this tile's own bytes (keys are
            // "clientId#index", written by sendAlbum/sendMixedAlbum), an X to cancel exactly this
            // item, and a dim once it is cancelled. One indicator per image was the owner's spec.
            //
            // NOT ONCE THIS ITEM IS DONE. `sendState` is per-MESSAGE — it stays `.sending` until
            // the whole batch commits — so a finished tile kept its overlay while siblings
            // uploaded, and with its bytes gone from UploadProgress the ring degraded to a
            // forever-spinner (his screenshot). `doneItems` is per-item truth: the overlay drops
            // the instant THIS transfer lands and the tile shows its plain preview.
            if message.sendState == .sending, extra == 0, let key = albumItemKey(i),
               !mediaSend.isItemDone(key) {
                if mediaSend.isItemCancelled(key) {
                    ZStack {
                        Color.black.opacity(0.55)
                        Image(systemName: "xmark")
                            .font(.system(size: min(w, h) * 0.2, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.8))
                    }
                } else {
                    ZStack {
                        Color.black.opacity(0.18)
                        // The X lives INSIDE the ring now (owner 2026-08-05: "the X should be
                        // placed inside the upload loading indicator"), the reference app's arrangement:
                        // one centred control that is both the progress and the cancel. The disc
                        // is the tap target. NOT a Button — a Button's press gesture claims
                        // touches inside a hosted cell and has locked chat scrolling before.
                        ZStack {
                            UploadingRing(clientId: key)
                            Image(systemName: "xmark")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                        .frame(width: 46, height: 46)
                        .contentShape(Circle())
                        .onTapGesture { mediaSend.cancelItem(key) }
                    }
                }
            }
            if extra > 0 {
                ZStack { Color.black.opacity(0.5); Text("+\(extra)").font(.title.weight(.bold)).foregroundStyle(.white) }
            }
        }
        .contentShape(Rectangle())
        // Each album CELL is its own zoom-hero source (same native transition as single photos/videos —
        // user spec). The synthetic per-item ids ("<msgId>-<i>") match the viewer covers' sourceIDs; the
        // +N cell taps through its own visible cell, so every open has a real source.
        // Album tiles reported a hero anchor but never a LIVE RECT, so drag-closing an album
        // photo had no destination: the copy drifted off into nothing instead of flying back
        // to its tile, which is what single photos have done all along.
        .modifier(MediaRectReporter(id: "\(message.id)-\(i)", scope: .chat))
        // Tapping a tile opens THAT item straight in the viewer (user rule, 2026-07-28): with 10 or
        // fewer items every photo is already visible in the mosaic, so a list screen in between is a
        // second tap for nothing. The album list sheet earns its place only when there is more than
        // the mosaic shows — an album of 11+ (old messages; new sends cap at 10) — or via a "+N"
        // overflow tile, whose whole meaning is "there is more to see than this grid".
        .onTapGesture {
            guard message.sendState == nil else { return }
            if message.album.count > 10 || extra > 0 { onOpenAlbum(message) }
            else { openAlbumItem(i) }
        }
    }

    private func albumVideoDuration(_ s: Double) -> String {
        let t = Int(s.rounded()); return String(format: "%d:%02d", t / 60, t % 60)
    }

    // Tap an album photo → open the full-screen viewer paged over EVERY photo in the album (an
    // album opens as a swipeable gallery, starting on the tapped photo). Each album item becomes a
    // synthetic image Message so ImageViewerView can page through them.
    private func openAlbumItem(_ i: Int) {
        guard message.album.indices.contains(i) else { return }
        let it = message.album[i]
        // Video item → play it full-screen (synthetic video Message from its videoUrl/videoEnc, keyed by
        // a per-item id so VideoCache stores each album video separately).
        if it.isVideo, let vurl = it.videoUrl, let venc = it.videoEnc {
            let d: [String: Any] = ["type": "video", "videoUrl": vurl, "enc": venc.asDict,
                                    "thumbUrl": it.imageUrl, "thumbEnc": it.enc.asDict,
                                    "authorId": message.authorId, "width": it.width, "height": it.height,
                                    "duration": it.duration]
            // Mailman is already album-safe: groups never delete; in 1:1 the author (sender) never
            // deletes (guarded), so viewing your own album video keeps the server copy for the recipient.
            let vmsg = Message(id: "\(message.id)-\(i)", data: d, cid: cid, crypto: Crypto.shared)
            onTapVideo(vmsg)
            return
        }
        // Image items → page through ONLY the album's images (skip videos) in the full-screen gallery.
        let imageItems = message.album.enumerated().filter { !$0.element.isVideo }
        let gallery: [Message] = imageItems.map { idx, im in
            let data: [String: Any] = ["type": "image", "imageUrl": im.imageUrl, "enc": im.enc.asDict,
                                       "authorId": message.authorId, "width": im.width, "height": im.height]
            return Message(id: "\(message.id)-\(idx)", data: data, cid: cid, crypto: Crypto.shared)
        }
        onTapAlbum(gallery, "\(message.id)-\(i)")
    }

    /// Is the story this reply points at certainly gone?
    ///
    /// Decided LOCALLY, with no lookup: a story lives 24 hours (StoriesService posts every one with
    /// `expiresAt = now + 24h`), so a reply older than that cannot still have a story behind it. That
    /// makes the test free, correct without a network round trip, and right even offline. A reply that
    /// never captured a thumbnail is treated the same way, because there is nothing to show either.
    private func storyReplyExpired(_ reply: ReplyRef) -> Bool {
        if reply.storyThumbUrl?.isEmpty ?? true { return true }
        // DELETED counts as gone, not just the 24-hour clock (owner order): the author pulling
        // their story down should flip this card to "Story unavailable" the same as expiry —
        // before this, the card kept rendering a thumbnail whose story no longer existed (grey
        // box once the file was gone). The stories repository hears deletions AND expiries live,
        // and it is the exact resolution the card's TAP uses, so show and tap now agree. Absence
        // only counts once the repository has actually loaded — an empty unloaded repo would
        // otherwise read as "everything deleted" for the first beat of a cold start.
        let stories = StoriesRepository.shared
        if stories.didLoad, !stories.hasLive(storyId: reply.id, author: reply.authorId) { return true }
        return Date().timeIntervalSince(message.createdAt) > 24 * 3600
    }

    // The BIG floating story card above the bubble (status replies render here, not in the quote box):
    // secondary caption line, then a tall rounded story thumbnail that opens the status on tap.
    @ViewBuilder private func storyReplyHeader(_ reply: ReplyRef) -> some View {
        let me = AuthService.shared.uid
        VStack(alignment: isMe ? .trailing : .leading, spacing: 5) {
            Text(isMe ? (reply.authorId == me ? "You replied to your story" : "You replied to their story")
                      : (reply.authorId == me ? "Replied to your story" : "Replied to their story"))
                .font(.system(size: 12)).foregroundStyle(.secondary)
            if storyReplyExpired(reply) {
                // EXPIRED, AND IT SAYS SO. Before, an expired story left this header as a bare "You
                // replied to their story" line with nothing under it — the card simply vanished and the
                // reply read as though something had failed to load. A story is a 24-hour object, so
                // the honest thing is to state that it is gone rather than leave a hole where it was.
                Text("Story unavailable")
                    .font(.system(size: 12)).foregroundStyle(.tertiary)
            } else if let thumb = reply.storyThumbUrl, !thumb.isEmpty {
                // ACCENT BAR + CARD, the way a reply quote is built everywhere else in the app: a
                // rounded rule on the leading edge, then the quoted thing. The story card was the one
                // quote in the conversation that floated with no rule beside it (user's reference
                // screenshot has one), so it did not read as a quotation at all.
                HStack(alignment: .center, spacing: 9) {
                    Capsule()
                        .fill(Color.primary.opacity(0.35))
                        .frame(width: 5, height: 140)
                    // ~92x160 (measured from the reference): small enough to read as a story CARD,
                    // not a sent photo. Hairline stroke separates light stories from the wallpaper.
                    // fitCanvas: the WHOLE photo shows (aspect-fit over its own canvas), never a
                    // crop — the preview must show exactly what opening the story shows (6 people
                    // in the story = 6 people in the card, user rule). Threshold = the card's own
                    // aspect so a card-tall photo still fills edge-to-edge with no bars.
                    StoryImage(url: thumb, fitCanvas: true, cardFillThreshold: 140.0 / 80.0)
                        .frame(width: 80, height: 140)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
                        // Unique per MESSAGE (two replies can quote the same story — two rectangles
                        // under one key would let the story fly home to the wrong bubble).
                        .modifier(ReplyStoryAnchor(active: storyQuoteOpens, id: "reply-\(message.id)",
                                                   cornerRadius: 14))
                        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .onTapGesture { onTapStory(reply.id, reply.authorId, "reply-\(message.id)") }
                }
            }
        }
        .padding(.bottom, 2)
    }

    /// The quote as used by most bubbles: its tinted box HUGS its content.
    @ViewBuilder private var replyQuote: some View { replyQuoteBox(fillWidth: false) }

    /// `fillWidth: true` stretches the tinted box to the full available width BEFORE the background is
    /// applied. The voice bubble is a fixed 212pt column, and the caller's `.frame(maxWidth: .infinity)`
    /// lands AFTER `.background()` inside the quote — so the tint stayed content-sized and the rest of
    /// the row was empty space to its right. Only the voice path opts in; every other bubble keeps the
    /// hugging behaviour untouched.
    @ViewBuilder private func replyQuoteBox(fillWidth: Bool) -> some View {
        if let reply = message.replyTo, !reply.isStatus {
            let fg = isMe ? onMyBubble : (dark ? Color.white : .black)
            // The original message (if still loaded) so a media reply shows its real thumbnail.
            let original = resolveReplyOriginal(reply.id)
            HStack(spacing: 7) {
                // Left accent line signalling a quoted reply.
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(fg.opacity(0.7))
                    .frame(width: 3)
                // Status reply → show the status thumbnail.
                if reply.isStatus, let thumb = reply.storyThumbUrl, !thumb.isEmpty {
                    StoryImage(url: thumb)
                        .frame(width: 30, height: 38)
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                        // Unique per MESSAGE (two replies can quote the same story — two rectangles
                        // under one key would let the story fly home to the wrong bubble).
                        .modifier(ReplyStoryAnchor(active: storyQuoteOpens, id: "reply-\(message.id)",
                                                   cornerRadius: 5))
                } else if let o = original, !o.deleted {
                    // Photo / GIF / video / album reply → real thumbnail (reference-style preview).
                    // Never for a deleted original: its thumbnail is gone from Storage, so this would
                    // draw an empty box next to the words saying it was deleted.
                    replyMediaThumb(o)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(reply.authorId == AuthService.shared.uid ? "You" : nameFor(reply.authorId))
                        .font(.caption.weight(.semibold)).foregroundStyle(fg.opacity(0.9))
                    Text(replyLabel(reply: reply, original: original))
                        .font(.caption).lineLimit(1).foregroundStyle(fg.opacity(0.75))
                }
                // MINIMUM quote width (reference behavior): a one-character quote never renders as a tiny
                // box, even in media/voice bubbles where there's no wide body to stretch to. Leading-aligned
                // so the accent line, name, and snippet stay put regardless of content length.
                .frame(minWidth: 150, alignment: .leading)
            }
            .frame(maxWidth: fillWidth ? .infinity : nil, alignment: .leading)
            // ONE HEIGHT, ALWAYS — only the width varies (explicit user request 2026-07-28, with a
            // screenshot of one quote rendering three times taller than its neighbour).
            //
            // The cause was that this box could be STRETCHED by its parent. The accent line is a
            // RoundedRectangle with only a width, and a Shape accepts any height it is offered, so the
            // whole HStack was vertically flexible. In the text bubble the quote sits in a VStack that is
            // laid out inside the bubble's measured template height, and a VStack hands leftover height to
            // whichever child will take it — this one. So the quote silently grew to absorb whatever slack
            // the body text left behind, which is why the tall example was the bubble with the long body.
            //
            // A definite height ends that: a fixed frame cannot be stretched, no matter what proposes to
            // it, and it also guarantees the invisible measurement template and the visible copy are the
            // same height by construction. 38 is the tallest thing the box ever holds (the status
            // thumbnail), so nothing clips.
            .frame(height: 38)
            .padding(.horizontal, 8).padding(.vertical, 5)
            // In the text bubble the Grid stretches this to the bubble's content width (fill); elsewhere it
            // hugs content with the minWidth floor above. Long snippets truncate at the bubble width.
            // Tint the quote box with the (contrasting) text color so it's always visible —
            // the old white tint vanished on the white "mine" bubble in dark mode.
            .background(fg.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
            .onTapGesture {
                if reply.isStatus { onTapStory(reply.id, reply.authorId, "reply-\(message.id)") }   // open the status (or "no longer available")
                else { onJumpTo(reply.id) }                                  // jump to the original message
            }
            // Publishes this box's window rect so the list's tap-to-dismiss refuses to begin here: the
            // (Step-6 removal: the KeyboardSafeTapArea rect-publishing is gone with the UIKit tap
            // system; the quote keeps the keyboard via the deferred-dismiss cancel in jumpTo instead.)
        }
    }

    // A small thumbnail of the replied-to media (photo / GIF / video / album), 34pt like the reference app.
    @ViewBuilder private func replyMediaThumb(_ o: Message) -> some View {
        let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
        Group {
            if o.isImage, let url = o.imageUrl {
                SecureImageView(imageUrl: url, enc: o.enc, cid: cid)
            } else if o.isAlbum, let first = o.album.first {
                SecureImageView(imageUrl: first.imageUrl, enc: first.enc, cid: cid)
            } else if o.isGif, let url = o.imageUrl {
                AnimatedGifView(url: url)
            } else if o.isVideo, let url = o.thumbUrl {
                SecureImageView(imageUrl: url, enc: o.thumbEnc, cid: cid)
                    .overlay { Image(systemName: "play.circle.fill").font(.system(size: 14)).foregroundStyle(.white).shadow(radius: 2) }
            } else {
                EmptyView()
            }
        }
        .frame(width: 34, height: 34)
        .clipShape(shape)
    }

    // The one-line label under the author: the original's caption if it has one, else a clean type
    // word ("Photo"/"GIF"/"Video"/"Photos") when we have the original, else the stored text snippet.
    private func replyLabel(reply: ReplyRef, original o: Message?) -> String {
        if reply.isStatus { return "Status" }
        // The quote is a SNAPSHOT baked into the replying message, so deleting the original left its
        // words still readable inside every reply to it. That defeats the delete. We cannot rewrite
        // someone else's message to fix it, but we can refuse to render the stale copy once we can
        // see the original is gone.
        if o?.deleted == true { return "This message was deleted" }
        if let o, o.isImage || o.isGif || o.isVideo || o.isAlbum {
            if !o.text.isEmpty { return quoteSafeLabel(o.text) }   // caption wins
            if o.isAlbum { return "Photos" }
            if o.isGif { return "GIF" }
            if o.isVideo { return "Video" }
            return "Photo"
        }
        return reply.text.isEmpty ? "Message" : quoteSafeLabel(reply.text)
    }
}

/// Marks a reply-quote thumbnail as the story flight's source.
///
/// It used to declare a `matchedTransitionSource` for Apple's zoom. The quote opens through
/// `StoryDoor` now, so what it has to publish is a rectangle and a corner radius — `cornerRadius` is
/// the one the caller actually draws the thumbnail with (14 on the big quote, 5 on the small one), so
/// the story lands on the shape that is there rather than on a number this modifier guessed.
///
/// `active` is what the optional namespace used to be: a bubble that was not given one is a bubble
/// whose thumbnail is not a door, and it must not register a rect any more than it should have
/// claimed a hero id. It is constant for the view's lifetime, so the branch never changes identity.
private struct ReplyStoryAnchor: ViewModifier {
    let active: Bool
    let id: String
    var cornerRadius: CGFloat = 14
    func body(content: Content) -> some View {
        if active {
            content.modifier(MediaRectReporter(id: id, scope: .storyRow, cornerRadius: cornerRadius))
        } else {
            content
        }
    }
}

// In-list typing indicator: a received-style bubble with three waving dots.
// "Recording a voice note" indicator: received-style bubble, accent mic + three sound bars rising
// and falling in turn. Our own design (owner's rule: study the references, then draw our own) —
// the bars say "sound", where the dots would have said "typing".
struct RecordingBubble: View {
    let dark: Bool
    @State private var animating = false

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "mic.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { i in
                    Capsule().fill(Color.accentColor)
                        .frame(width: 3, height: 14)
                        .scaleEffect(y: animating ? 1 : 0.35)
                        .animation(.easeInOut(duration: 0.5).repeatForever().delay(Double(i) * 0.15), value: animating)
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(Theme.received(dark))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onAppear { animating = true }
    }
}

struct TypingBubble: View {
    let dark: Bool
    @State private var animating = false

    var body: some View {
        HStack {
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { i in
                    Circle().fill(Color.secondary)
                        .frame(width: 7, height: 7)
                        .scaleEffect(animating ? 1 : 0.5)
                        .opacity(animating ? 1 : 0.4)
                        .animation(.easeInOut(duration: 0.6).repeatForever().delay(Double(i) * 0.2), value: animating)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(Theme.received(dark))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            Spacer(minLength: 0)
        }
        .onAppear { animating = true }
    }
}


// Message long-press confirmations (Delete + Report) extracted into their own modifier
// so ThreadView's already-large body stays under the SwiftUI type-checker's limit.
private struct MessageActionDialogs: ViewModifier {
    let cid: String
    let title: String
    let me: String
    @Binding var pendingDelete: Message?
    var onDeleteForMe: (Message) -> Void = { _ in }
    /// Show the bubble as deleted immediately. False = nothing to undo if the server then refuses.
    var onMarkDeleted: (Message) -> Bool = { _ in false }
    /// The server refused: take that back.
    var onRestoreDeleted: (Message) -> Void = { _ in }
    @State private var deleteFailed = false

    func body(content: Content) -> some View {
        content
            .alert("Couldn't delete for everyone", isPresented: $deleteFailed) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("The server refused the delete. The message is still there for both of you.")
            }
            // Native alert (the confirmationDialog rendered as an anchored popover on iOS 26). My own
            // message → "Delete for Everyone" (removes the doc) + "Delete for Me" (local hide);
            // someone else's → "Delete for Me" only.
            .alert("Delete this message?",
                   isPresented: Binding(get: { pendingDelete != nil },
                                        set: { if !$0 { pendingDelete = nil } })) {
                if let m = pendingDelete {
                    // NOT for an unsent message (audit): its id is a local clientId, so the server
                    // call hits a doc that does not exist, is refused, and the failure alert then
                    // claims "still there for both of you" about a message that was never delivered.
                    // Delete for Me cancels it properly (see ThreadView.deleteForMe).
                    // NOT for a tombstone either (owner order): it was already deleted for everyone;
                    // the only thing left to do is clear the marker from your own side.
                    // NOT for a call record either: `callRow` draws the bubble from the call fields
                    // and never looks at `deleted`, so a tombstone there would remove the row for
                    // the other person and leave mine looking untouched. A call goes from my own
                    // side only, which is what the phone's own call log does.
                    if m.authorId == me, m.sendState == nil, !m.deleted, !m.isCall {
                        Button("Delete for Everyone", role: .destructive) {
                            // The bubble becomes a tombstone NOW, and the server work runs behind it.
                            // deleteMessage reads the doc before writing (it needs the Storage urls),
                            // so waiting for it meant a whole network round trip with nothing moving
                            // on screen — the owner read that as the delete not working at all.
                            let undoable = onMarkDeleted(m)
                            Task {
                                // Say so when the server refuses, and put the message back. An
                                // optimistic tombstone left standing over a message that still exists
                                // for the other person is a worse lie than the old dead button.
                                if await !ChatService.deleteMessage(cid: cid, messageId: m.id) {
                                    if undoable { onRestoreDeleted(m) }
                                    deleteFailed = true
                                }
                            }
                            pendingDelete = nil
                        }
                    }
                    Button("Delete for Me", role: .destructive) {
                        onDeleteForMe(m); pendingDelete = nil
                    }
                }
                Button("Cancel", role: .cancel) { pendingDelete = nil }
            }
    }
}

// Recording timer + waveform isolated into their OWN views, so the AudioRecorder's 20Hz
// updates re-render only these tiny views — never ThreadView's body (which would re-render
// the whole message list on every tick: the cause of voice-recording stutter/frame drops).
// Audio-reactive recording halo, isolated so its 30 Hz metering re-render never touches the mic
// button (which owns the drag-to-lock offset). Breathes continuously and swells with the live level.
private struct RecordTimerText: View {
    var recorder: AudioRecorder
    var body: some View {
        Text(format(recorder.elapsed)).font(.subheadline.monospacedDigit())
    }
    private func format(_ t: TimeInterval) -> String {
        let s = Int(t); return String(format: "%d:%02d", s / 60, s % 60)
    }
}

private struct RecordWaveform: View {
    var recorder: AudioRecorder
    var color: Color
    var body: some View {
        // The SCROLLING live view — bars enter right, travel left, die at the edge (his report on
        // the whole-note compressed strip: it re-bucketed every tick, shimmered in place, "laggy",
        // and carried a playback knob that means nothing while recording). The 10Hz liveWindow
        // sets a pace the eye can follow, and display()'s physics makes silence enter as dots.
        // The full note is still shown where it belongs: the review strip, after pause.
        LiveWaveform(levels: recorder.liveWindow, color: color)
            .frame(maxWidth: .infinity, maxHeight: 22)
    }
}

// Identifiable wrapper so a decrypted file can drive a .sheet(item:).
struct PreviewFile: Identifiable { let id = UUID(); let url: URL }
struct PDFDocWrap: Identifiable { let id = UUID(); let url: URL; let title: String }

// Native document preview (QuickLook) for a received file.
// The document preview as a proper SHEET page: rounded top, visible grabber, and a glass close
// button (QuickLook's own Done bar doesn't render inside a plain sheet, and the scrolling content
// eats the swipe-down — the bare preview was unclosable).
struct FilePreviewSheet: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        FilePreview(url: url)
            .overlay(alignment: .topTrailing) {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .semibold)).foregroundStyle(.primary)
                        .frame(width: 40, height: 40)
                        .liquidGlass(Circle(), interactive: true)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .padding(.top, 10).padding(.trailing, 12)
            }
            .presentationDragIndicator(.visible)
    }
}

struct FilePreview: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> QLPreviewController {
        let c = QLPreviewController(); c.dataSource = context.coordinator; return c
    }
    func updateUIViewController(_ controller: QLPreviewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(url: url) }
    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}

// DISPLAY-TIME guard for reply-quote snippets (file scope — used by MessageBubble AND ThreadView):
// quotes persisted BEFORE the safeText fix carry the raw "fariin-…:" marker forever (encrypted
// snapshots) — map them to friendly labels when rendering, so old quotes clean up too.
/// The line a reply SEALS about the message it is quoting.
///
/// This was written out as the same nested ternary in three send paths (text, photo, voice), and
/// that is exactly how a call came to be quoted as the bare word "Message": the chain fell through
/// to `safeText`, and a call record's text field is empty by construction. One copy now, so the next
/// message type is described once instead of three times, or twice and forgotten.
func replyQuoteText(_ m: Message) -> String {
    if m.isCall { return m.callVideo ? "📹 Video call" : "📞 Voice call" }
    if m.isAlbum { return "📷 Photos" }
    if m.isImage { return m.viewOnce ? "View-once photo" : "📷 Photo" }
    if m.isVideo { return "🎥 Video" }
    if m.isAudio { return "🎤 Voice message" }
    if m.isFile { return "📄 \(m.fileName ?? "Document")" }
    if m.isGif { return "GIF" }
    return m.safeText
}

func quoteSafeLabel(_ t: String) -> String {
    if t.hasPrefix(Message.contactMarker) { return "Contact" }
    if t.hasPrefix(Message.locationMarker) { return "Location" }
    if t.hasPrefix(Message.pinMarker) { return "📌 Pinned a message" }
    if t.range(of: Message.featureMarkerPattern, options: .regularExpression) != nil { return "Message" }
    return t
}

// MARK: - Jumbomoji detection (the reference app's rules, read from the reference app-iOS source 2026-07-28)

// the reference app keeps a hand-maintained table of emoji scalar ranges and binary-searches it
// (`UnicodeScalar.isEmoji` in String+SSK.swift). Swift exposes the same information through Unicode
// properties, so this asks the Unicode tables directly instead of shipping a table that goes stale every
// time Unicode adds emoji. The one correction their table also makes: ASCII digits, '#' and '*' report
// `isEmoji == true` but are not emoji on their own — they only become one inside a keycap sequence.
private extension Unicode.Scalar {
    var isEmojiScalar: Bool {
        if properties.isEmojiPresentation { return true }
        if value == 0xFE0F { return true }                        // variation selector-16 (emoji presentation)
        if value == 0x20E3 { return true }                        // combining enclosing keycap
        if (0x1F3FB...0x1F3FF).contains(value) { return true }     // skin-tone modifiers
        if (0x1F1E6...0x1F1FF).contains(value) { return true }     // regional indicators (flags)
        if (0xE0020...0xE007F).contains(value) { return true }     // tag characters (subdivision flags)
        return properties.isEmoji && value > 0x238C
    }
    var isZeroWidthJoiner: Bool { value == 0x200D }
}

extension String {
    /// the reference app's `containsOnlyEmojiIgnoringWhitespace`:
    ///     return self.allSatisfy { $0.isEmoji || $0.isZeroWidthJoiner || $0.properties.isWhitespace }
    var containsOnlyEmojiIgnoringWhitespace: Bool {
        guard !unicodeScalars.isEmpty else { return false }
        return unicodeScalars.allSatisfy { $0.isEmojiScalar || $0.isZeroWidthJoiner || $0.properties.isWhitespace }
    }

    /// the reference app's `DisplayableText.jumbomojiCount(in:)`, including its two easily-missed details: whitespace
    /// is ignored for the emoji-only test AND stripped before counting (so "X Y" is two, not three), and
    /// SIX or more returns 0 — an ordinary message with a bubble, not a count capped at five.
    var jumbomojiCount: Int {
        guard containsOnlyEmojiIgnoringWhitespace else { return 0 }
        let count = filter { !$0.isWhitespace }.count   // grapheme clusters, so a ZWJ family is one
        guard count > 0, count <= 5 else { return 0 }   // the reference app: kMaxJumbomojiCount = 5
        return count
    }
}
