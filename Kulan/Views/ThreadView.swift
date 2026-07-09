import SwiftUI
import PhotosUI
import Photos
import CoreTransferable
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
    struct EditImageWrap: Identifiable { let id = UUID(); let image: UIImage }
    @State private var sendingPhoto = false
    @State private var typingSent = false
    @State private var viewerImage: Message?
    @State private var viewerVideo: Message?   // tapped video bubble → full-screen player
    @State private var storyToOpen: StoryGroup?      // tapped a status reply → open that status
    @State private var statusUnavailable = false     // tapped a status reply whose story expired
    @State private var sendError: String?
    @State private var showCamera = false
    @State private var showAttachPanel = false
    @State private var showPollSoon = false   // Poll tile → "coming soon" sheet
    @State private var showFileImporter = false
    @State private var showGifPicker = false
    @State private var filePreview: PreviewFile?
    @State private var showLibrary = false
    @State private var showVideoSoon = false
    @State private var showContactInfo = false   // tap avatar/name in header → profile (or Group Info for groups)
    @State private var showWallpaper = false      // "Change Wallpaper" from the profile menu opens the picker here
    // Hold-to-record voice gesture state (WhatsApp/Telegram-style).
    @State private var recordLocked = false        // recording continues after finger lifts
    @State private var holdHint = false             // "hold to record" flash after an accidental tap
    @State private var pinIndex = 0                  // which of the (≤5) pinned messages the bar shows
    @State private var recordDrag: CGSize = .zero   // live finger translation while holding
    @State private var recordCancelArmed = false    // dragged left past the cancel threshold
    @State private var holdStarted = false          // guards a single start per hold
    @State private var recorder = AudioRecorder()
    @State private var highlightId: String?
    @State private var isAtBottom = true
    @State private var visibleRows = VisibleRowsBox()   // ids currently on screen → remember where I left (WhatsApp)
    @State private var settled = false   // suppress animated auto-scroll until the open transition + first load finish
    @State private var revealed = false  // list hidden until the first chunk has laid out — the chunked build was visible mid-push (user video)
    @Namespace private var replyStoryNS                       // native zoom hero for reply-opened stories
    @State private var replyStoryAnchorId = ""                // the tapped quote's anchor (per-message unique)
    @State private var newWhileAway = 0
    @State private var unreadOnOpen = 0
    @State private var firstUnreadId: String?
    @State private var didAnchorUnread = false
    @State private var morePickerTarget: Message? // any-emoji picker
    @State private var reactorsTarget: Message?   // "who reacted" sheet
    @State private var pendingDelete: Message?
    @State private var editingMessage: Message?   // INLINE edit (Telegram-style) — no modal/sheet
    @State private var forwardTarget: Message?    // forward-to-chat picker
    @State private var reportTarget: Message?     // abuse-report confirm (App Store 1.2)
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
        // Cache hit → the conversation is already decrypted and seeded, so reveal on the FIRST frame
        // (no fade). didInitialLoad won't transition, so the onChange reveal handler won't fire — the
        // onAppear below does the open-scroll for this path. Cache miss → starts hidden, reveals on load.
        _revealed = State(initialValue: r.didInitialLoad)
    }

    private var threadScroll: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
            pinnedBar(proxy)
            ScrollView {
                messageList(proxy)
                    .contentShape(Rectangle())   // whole content tappable so the dismiss tap always lands
                    .simultaneousGesture(
                        // tap the chat to close the keyboard; force-resign so it always drops.
                        // simultaneous = bubble taps still open the viewer (not consumed).
                        TapGesture().onEnded {
                            inputFocused = false
                            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                                            to: nil, from: nil, for: nil)
                        }
                    )
            }
            .defaultScrollAnchor(.bottom)
            // Appear fully-formed (WhatsApp): the cache chunk lands DURING the push transition
            // and the pinned-bottom re-layout read as the whole chat jumping/wiggling.
            .opacity(revealed ? 1 : 0)
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
                // Cache-seeded chat: didInitialLoad was already true at init (rendered on frame 1), so
                // the reveal onChange never fires — place the open position + arm slide-in here instead.
                if repo.didInitialLoad {
                    DispatchQueue.main.async { let a = openAnchor; proxy.scrollTo(a.id, anchor: a.edge) }
                    enableSlideInAfterReveal()
                }
            }
            .scrollDismissesKeyboard(.interactively)   // drag the messages down -> keyboard follows
            .onChange(of: repo.items.count) { old, new in
                guard new > old else { return }
                let mine = repo.items.last?.authorId == me
                if !settled {
                    // INITIAL LOAD (WhatsApp-clean): pin to the OPEN ANCHOR (the saved in-session spot,
                    // else the newest) as cache→live chunks land. NON-animated + still under the reveal
                    // veil, so it's invisible — no wiggle. Applies even with unread messages: the unread
                    // divider is only a marker you scroll up to, it never steals the open position. (The
                    // old code relied on defaultScrollAnchor here, which drifted off the bottom as chunks
                    // landed — that was the "opens in the middle" bug.)
                    let a = openAnchor
                    proxy.scrollTo(a.id, anchor: a.edge)
                } else if mine || isAtBottom {
                    // My own send always jumps to the bottom; a received message only when I'm already
                    // there. Double-frame the pin (pinBottomStable) so the freshly-inserted bubble —
                    // whose height isn't final on the same runloop (text reflow, async image size) —
                    // can't shift the bottom out from under the scroll (the jump).
                    pinBottomStable(proxy)
                } else {
                    newWhileAway += 1
                }
                if !repo.iBlocked { Task { await ChatService.markRead(cid) } }   // don't leak reads to a blocked user
            }
            .onChange(of: repo.messages.count) { _, _ in anchorUnread(proxy) }
            // Always default the pinned bar to the LAST (most recent) pin; tapping then cycles.
            .onChange(of: repo.pinnedMessageIds) { _, ids in pinIndex = max(0, ids.count - 1) }
            .onChange(of: unreadOnOpen) { _, _ in anchorUnread(proxy) }
            .onChange(of: repo.otherTyping) { _, t in
                if t && isAtBottom { proxy.scrollTo("BOTTOM", anchor: .bottom) }
            }
            // Keyboard opening: if I was already at the bottom, keep the newest messages pinned right
            // above the keyboard (the system doesn't reliably do this, which left the chat looking
            // like it jumped up/away). If I'm reading history (not at bottom), leave my place alone.
            .onChange(of: inputFocused) { _, focused in
                guard focused, isAtBottom else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    proxy.scrollTo("BOTTOM", anchor: .bottom)
                }
            }
            // Floating jump-to-bottom button (our design) — appears when scrolled up,
            // with a count of messages that arrived while away.
            .overlay(alignment: .bottomTrailing) {
                if !isAtBottom && !recordingHeld && !recordLocked {   // hide the down-arrow while recording
                    Button {
                        withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("BOTTOM", anchor: .bottom) }
                    } label: {
                        Image(systemName: "chevron.down").font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.primary)
                            .frame(width: 40, height: 40)
                            .liquidGlass(Circle(), interactive: true)
                            .overlay(alignment: .top) {
                                if newWhileAway > 0 {
                                    Text("\(newWhileAway)").font(.system(size: 11, weight: .bold))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 5).padding(.vertical, 1)
                                        .background(Color.accentColor, in: Capsule())
                                        .offset(y: -9)
                                }
                            }
                    }
                    .padding(.trailing, 16).padding(.bottom, 10)
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.32, dampingFraction: 0.72), value: isAtBottom)   // scroll button in/out
            // Float the composer OVER the messages (iOS 26 native via safeAreaBar):
            // the glass dims/blurs the messages scrolling under it like iMessage;
            // the scroll content auto-insets so the last message never hides.
            // Skeleton placeholder bubbles until the first page is ready (cold load only;
            // a cached chat flips didInitialLoad instantly, so this never flashes).
            .overlay {
                if !repo.didInitialLoad {
                    ThreadSkeleton().allowsHitTesting(false)
                }
            }
            .floatingBottomBar {
                Group {
                    if notAMember {
                        removedBar.transition(.opacity.combined(with: .move(edge: .bottom)))
                    } else if cannotSendAnnouncement {
                        announcementBar.transition(.opacity.combined(with: .move(edge: .bottom)))
                    } else if repo.iBlocked {
                        blockedBar.transition(.opacity.combined(with: .move(edge: .bottom)))
                    } else {
                        composerArea.transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                }
                .animation(.easeInOut(duration: 0.25), value: repo.iBlocked)
            }
            }
            // Per-chat wallpaper (local, WhatsApp-style) behind the messages. `.none` renders the
            // plain app background, so chats without a wallpaper look exactly as before.
            .background { ChatWallpaperBackground(cid: cid).ignoresSafeArea() }
        }
    }

    // Split into several layers so each modifier chain stays under the type-checker limit.
    private var threadCovers: some View {
        threadScroll
        .toolbar(.hidden, for: .tabBar)
        // Native nav bar KEPT (real edge-swipe-back that follows your finger + reveals the list), but
        // its BACKGROUND is hidden — no solid bar / border, so the chat scrolls up under a transparent
        // floating header (the Signal "no border, see the background" look). Avatar/name/call buttons
        // stay as the toolbar's glass pills.
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { chatToolbar }
        .toolbarBackground(.hidden, for: .navigationBar)
        .navigationDestination(isPresented: $showContactInfo) {
            if isGroup {
                GroupInfoView(cid: cid)
            } else {
                ContactInfoView(cid: cid, name: title, photoUrl: photoUrl)
            }
        }
        .alert("Video calls", isPresented: $showVideoSoon) {
            Button("OK", role: .cancel) {}
        } message: { Text("Video calling is coming soon.") }
        .alert("Message not sent", isPresented: Binding(get: { sendError != nil },
                                                        set: { if !$0 { sendError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(sendError ?? "") }
    }

    private var threadPickers: some View {
        threadCovers
        .fullScreenCover(item: $storyToOpen) { g in
            // FULLY NATIVE (user's final call): the zoom hero anchors on the tapped reply-quote
            // thumbnail, so Apple's interactive scroll-down-to-close works here exactly like
            // the main story flow — the custom pan is gone from this cover.
            StoryViewer(group: g,
                        onClose: { storyToOpen = nil }, onProfile: { _ in storyToOpen = nil })
                .navigationTransition(.zoom(sourceID: replyStoryAnchorId, in: replyStoryNS))
        }
        .alert("Status no longer available", isPresented: $statusUnavailable) {
            Button("OK", role: .cancel) {}
        } message: { Text("This status has expired.") }
        .fullScreenCover(item: $viewerImage) { msg in
            ImageViewerView(message: msg, cid: cid)
        }
        .photosPicker(isPresented: $showLibrary, selection: $photoItems, maxSelectionCount: Limits.mediaPerMessage, matching: .any(of: [.images, .videos]))
        .fullScreenCover(item: $viewerVideo) { msg in
            VideoPlayerScreen(message: msg, cid: cid)
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { data in if let ui = UIImage(data: data) { editImage = EditImageWrap(image: ui) } }
                .ignoresSafeArea()
        }
        .fullScreenCover(item: $editImage) { wrap in
            ChatImageEditor(source: wrap.image) { data, caption, _ in
                Task {
                    await sendPhoto(data)
                    let c = caption.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !c.isEmpty {
                        try? await ChatService.sendText(cid: cid, text: c, group: isGroup ? groupMembers : nil)
                    }
                }
            }
        }
        .sheet(isPresented: $showAttachPanel) { attachPanel.presentationDetents([.fraction(0.7), .large]) }
        .sheet(isPresented: $showPollSoon) { pollSoonSheet.presentationDetents([.fraction(0.6)]) }
        .sheet(isPresented: $showGifPicker) {
            GifPickerView { gif in
                Task {
                    // Surface failures — the old try? made a failed send look like a dead tap.
                    do { try await ChatService.sendGif(cid: cid, url: gif.url, width: gif.width, height: gif.height, group: isGroup ? groupMembers : nil) }
                    catch { await MainActor.run { sendError = "Couldn't send the GIF. Check your connection and try again." } }
                }
            }
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.item], allowsMultipleSelection: false) { result in
            handlePickedFile(result)
        }
        .sheet(item: $filePreview) { FilePreview(url: $0.url).ignoresSafeArea() }
    }

    private var threadContent: some View {
        threadPickers
        .sheet(item: $morePickerTarget) { m in EmojiMorePicker { emoji in react(m, emoji) } }
        .sheet(item: $reactorsTarget) { m in
            ReactorsSheet(reactions: m.reactions, nameFor: { personName($0) })
        }
        .sheet(item: $forwardTarget) { m in
            ForwardPicker(message: m, sourceCid: cid)
        }
        .sheet(isPresented: $showGroupAdd) {
            AddMembersSheet(cid: cid, existing: Set(groupMembers))
        }
    }

    var body: some View {
        threadContent
        // Chat wallpaper picker. ContactInfoView's "Change Wallpaper" pops back to this chat and
        // posts this notification, so the picker opens here (over the live chat, previewing behind).
        .sheet(isPresented: $showWallpaper) { WallpaperPickerSheet(cid: cid) }
        .onReceive(NotificationCenter.default.publisher(for: .openChatWallpaper)) { note in
            guard (note.object as? String) == cid else { return }
            showWallpaper = true
        }
        .sheet(item: $tappedMember) { m in
            GroupMemberSheet(cid: cid, member: m,
                             iAmAdmin: conversation?.isAdmin(me) ?? false,
                             ownerUid: conversation?.createdBy ?? "")
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
                                       pendingDelete: $pendingDelete, reportTarget: $reportTarget,
                                       onDeleteForMe: { m in repo.hideForMe(m.id) }))
        .onChange(of: ConversationsRepository.shared.conversations) { _, list in
            let resolved = list.first { $0.id == cid }   // O(n) ONCE per change, not per render
            if resolved != cachedConv { cachedConv = resolved }
        }
        .onAppear {
            cachedConv = ConversationsRepository.shared.conversations.first { $0.id == cid }
            repo.start()
            recorder.prepare()                           // pre-warm so hold-to-record is instant
            recorder.onInterrupt = { resetRecordingState() }   // call/Siri/alarm mid-record → drop the UI cleanly
            // Restore an unsent draft (local-only). Never clobber text already being typed.
            if input.isEmpty { input = Drafts.shared.text(cid) }
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
            Task {
                // Only needed when this chat wasn't in the cached list (no sync count above).
                if cachedConv == nil {
                    let n = await ChatService.myUnread(cid)
                    await MainActor.run { unreadOnOpen = n }
                }
                await ChatService.resetUnread(cid)
                if !repo.iBlocked { await ChatService.markRead(cid) }
            }
        }
        .onDisappear {
            repo.stop()
            groupCallListener?.remove(); groupCallListener = nil
            AppRouter.shared.activeChatId = nil
            Task { await ChatService.setTyping(cid, false) }
            // Don't leave a half-finished recording running when you leave the chat.
            if recorder.isRecording { recorder.cancel() }
            recordLocked = false; recordDrag = .zero; holdStarted = false
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

    // Liquid-Glass pinned-message bar below the nav (tap to scroll to it; pin.slash to unpin).
    @ViewBuilder private func pinnedBar(_ proxy: ScrollViewProxy) -> some View {
        if !repo.pinnedMessageIds.isEmpty {
            let ids = repo.pinnedMessageIds
            let idx = min(pinIndex, ids.count - 1)
            let pid = ids[idx]
            let msg = repo.messages.first { $0.id == pid }
            let author = msg.map { personName($0.authorId) } ?? "Pinned Message"
            HStack(spacing: 10) {
                // Vertical count indicator (one bar per pin, current highlighted) — Telegram-style.
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
                }
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(author).font(.system(size: 15, weight: .semibold)).foregroundStyle(.primary).lineLimit(1)
                        if ids.count > 1 {
                            Text("\(idx + 1)/\(ids.count)").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Text(msg.map { $0.isImage ? "Photo" : ($0.isVideo ? "Video" : ($0.isAudio ? "Voice message" : $0.text)) } ?? "Tap to view")
                        .font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if !isGroup || (conversation?.isAdmin(me) ?? false) {
                    Button {
                        Task { await ChatService.removePinnedMessage(cid, pid) }
                        if pinIndex > 0 { pinIndex -= 1 }   // keep index valid after removal
                    } label: {
                        Image(systemName: "pin.slash.fill").font(.system(size: 16)).foregroundStyle(.secondary)
                            .frame(width: 32, height: 32).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.leading, 14).padding(.trailing, 8)
            .frame(height: 48)
            .liquidGlass(RoundedRectangle(cornerRadius: 24, style: .continuous), interactive: true)
            .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .onTapGesture {
                if let id = msg?.id { withAnimation { proxy.scrollTo(id, anchor: .center) } }
                if ids.count > 1 { pinIndex = (idx + 1) % ids.count }   // next tap shows the next pin
            }
            .padding(.horizontal, 16)
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
        if lastSeenPref {                                        // reciprocal: only if I share last-seen
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
    // WhatsApp/Telegram-style intro card at the top of a group: avatar, name, members,
    // "you created this group", and an Add Members CTA (admins).
    private var groupIntroCard: some View {
        VStack(spacing: 8) {
            AvatarView(name: conversation?.title ?? "Group", photoUrl: conversation?.avatarUrl, size: 72)
            Text(conversation?.title ?? "Group").font(.headline)
            Text(conversation?.memberCountLabel ?? "").font(.caption).foregroundStyle(.secondary)
            if conversation?.createdBy == me {
                Text("You created this group").font(.caption).foregroundStyle(.secondary)
            }
            if (conversation?.isAdmin(me) ?? false) || (conversation?.membersCanAdd ?? false) {
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

    private func messageList(_ proxy: ScrollViewProxy) -> some View {
        LazyVStack(spacing: 0) {
            // Scroll-to-top spinner: pages in older history, then restores the anchor.
            // Only after the first load — never as a blank-screen "loading" before it.
            if repo.canLoadOlder && repo.didInitialLoad {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .id("TOP")
                    .onAppear { loadOlderWithAnchor(proxy) }
            }
            // "You created this group" intro card at the very top (when no older history).
            if isGroup && !repo.canLoadOlder { groupIntroCard }
            ForEach(Array(repo.items.enumerated()), id: \.element.rowId) { index, msg in
                if shouldShowDate(at: index) {
                    Text(dayLabel(msg.createdAt))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                if msg.id == firstUnreadId { unreadDivider }
                if msg.isSystem {
                    systemRow(msg).id(msg.id)
                } else if msg.isCall {
                    callRow(msg).padding(.top, 8).id(msg.id)
                } else {
                    MessageBubble(
                        message: msg, isMe: msg.authorId == me, dark: dark, cid: cid,
                        nameFor: { personName($0) },
                        avatarFor: { conversation?.photos[$0] },
                        onReply: { m in withAnimation(.easeInOut(duration: 0.22)) { replyingTo = m } },
                        onDelete: { pendingDelete = $0 },   // confirm dialog, not instant
                        onTapImage: { viewerImage = $0 },
                        onTapVideo: { viewerVideo = $0 },
                        onReact: { emoji in Task { await ChatService.setReaction(cid: cid, messageId: msg.id, emoji: emoji, toAuthor: msg.authorId, group: isGroup ? groupMembers : nil) } },
                        onPin: { m in
                            if repo.pinnedMessageIds.contains(m.id) {
                                Task { await ChatService.removePinnedMessage(cid, m.id) }
                            } else if repo.pinnedMessageIds.count < Limits.pinnedMessagesPerChat {
                                Task { await ChatService.addPinnedMessage(cid, m.id) }
                            }   // already at the pin max → ignore
                        },
                        onForward: { forwardTarget = $0 },
                        onEdit: { m in
                            withAnimation(.easeInOut(duration: 0.2)) { editingMessage = m; replyingTo = nil }
                            input = m.text
                            inputFocused = true
                        },
                        onReport: { reportTarget = $0 },
                        onReactMore: { morePickerTarget = $0 },
                        isGroup: isGroup,
                        onTapReactions: { reactorsTarget = msg },
                        onTapSender: { uid in
                            tappedMember = GroupInfoView.MemberAction(
                                id: uid, name: personName(uid), isAdmin: conversation?.isAdmin(uid) ?? false)
                        },
                        onOpenFile: { m in openFile(m) },
                        onSaveImage: { m in Task { await saveImageToPhotos(m) } },
                        canPin: !isGroup || (conversation?.isAdmin(me) ?? false),
                        isPinned: repo.pinnedMessageIds.contains(msg.id),
                        onResend: { m in resend(m) },
                        onJumpTo: { id in jump(to: id, proxy) },
                        onTapStory: { id, author, anchor in openStory(id, author, anchorId: anchor) },
                        replyStoryNS: replyStoryNS,
                        isHighlighted: msg.id == highlightId,
                        isFirstInCluster: isFirstInCluster(at: index),
                        isLastInCluster: isLastInCluster(at: index),
                        // Read-tick only matters on MY messages; incoming bubbles get a constant 0 so a
                        // read-receipt update never re-renders them (H2). Combined with .equatable() below.
                        otherLastRead: (msg.authorId == me && !repo.iBlocked) ? repo.otherLastReadMillis : 0
                    )
                    .equatable()   // skip re-rendering bubbles whose value-inputs are unchanged (H2/H3/M1)
                    .padding(.top, topGap(at: index))   // tight when grouped, wider on sender change
                    .id(msg.id)
                    // Track which bubbles are on screen (into a non-invalidating box) and remember the
                    // spot on APPEAR only — never on disappear, so navigating away (mass row teardown)
                    // can't corrupt the saved position.
                    .onAppear { visibleRows.ids.insert(msg.id); persistScrollPosition() }
                    .onDisappear { visibleRows.ids.remove(msg.id) }
                    // Native: no custom slide-in. Rows appear like a plain list (iMessage-style),
                    // no spring/move transition on insert.
                    .transition(.identity)
                }
            }
            if repo.otherTyping && !repo.iBlocked && typingPref {
                TypingBubble(dark: dark).padding(.top, 6).id("TYPING")
            }
            // Bottom sentinel: drives "am I at the bottom?" for the scroll button.
            Color.clear.frame(height: 1).id("BOTTOM")
                .onAppear { isAtBottom = true; newWhileAway = 0; persistScrollPosition() }   // at bottom → remember .bottom
                .onDisappear { isAtBottom = false }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // Native toolbar header (real Liquid Glass + native back/swipe), same approach as the
    // Chats list. Avatar + name (+ presence) centered; voice + video as trailing glass items.
    // The native back button (leading) owns the real edge-swipe-back gesture.
    @ToolbarContentBuilder private var chatToolbar: some ToolbarContent {
        // Avatar + name (leading), tap opens the contact profile. iOS 26 auto-wraps EVERY
        // toolbar item in a Liquid-Glass pill — but the avatar/name must NOT have that pill
        // (only the back button + call/video buttons should). `.buttonStyle(.plain)` alone
        // does NOT remove it; `.sharedBackgroundVisibility(.hidden)` does.
        // .topBarLeading: place the avatar+name LEFT, right after the back button (in the
        // empty space) — not centered. `.sharedBackgroundVisibility(.hidden)` keeps it
        // glass-free. (Trade-off: a leading item doesn't slide with the page on swipe-back;
        // left position was the explicit ask.)
        if #available(iOS 26.0, *) {
            ToolbarItem(placement: .topBarLeading) {
                Button { showContactInfo = true } label: { headerLabel }.buttonStyle(.plain)
            }
            .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .topBarLeading) {
                Button { showContactInfo = true } label: { headerLabel }.buttonStyle(.plain)
            }
        }
        // 1:1 call buttons only — group calls need an SFU (not built yet). The cid check keeps
        // them from flashing on a group cold-open before the conversation doc has loaded.
        if !isGroup && cid.contains("_") {
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
                groupCallActive = (d?["active"] as? Bool) ?? false
                groupCallVideo = (d?["video"] as? Bool) ?? false
            }
    }

    // Custom attach panel (Telegram/WhatsApp-style) — slides up from the + button.
    // Top: one-tap recents strip (camera-roll photos + videos). Below: the pickers.
    private var attachPanel: some View {
        VStack(spacing: 0) {
            Capsule().fill(.secondary.opacity(0.4)).frame(width: 38, height: 5).padding(.top, 8)
            // Grid: X + "Recents ▾" album dropdown header, Camera tile, then recent photos/videos.
            AttachRecentsStrip(
                onCamera: {
                    showAttachPanel = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { showCamera = true }
                },
                onClose: { showAttachPanel = false },
                onPickPhoto: { ui in
                    showAttachPanel = false
                    // Let the sheet finish dismissing before the editor cover presents.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { editImage = EditImageWrap(image: ui) }
                },
                onPickVideo: { url in
                    showAttachPanel = false
                    Task { await sendVideo(from: url) }   // straight into the send pipeline
                })
                .padding(.top, 10)
            // Fixed bottom row of sources (Camera lives in the grid now).
            HStack(spacing: 22) {
                attachTile("photo.on.rectangle", "Photos") { showLibrary = true }
                attachTile("doc", "Files") { showFileImporter = true }
                attachTile("sparkles", "GIF") { showGifPicker = true }
                attachTile("chart.bar.xaxis", "Poll") { showPollSoon = true }
            }
            .padding(.vertical, 12)
        }
    }

    // Polls aren't built yet — a small "coming soon" sheet at a 60% detent (user request).
    private var pollSoonSheet: some View {
        VStack(spacing: 14) {
            Capsule().fill(.secondary.opacity(0.4)).frame(width: 38, height: 5).padding(.top, 8)
            Spacer()
            Image(systemName: "chart.bar.xaxis").font(.system(size: 52, weight: .regular)).foregroundStyle(.secondary)
            Text("Polls").font(.title2.weight(.bold))
            Text("Coming soon.").font(.body).foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    // Kulan's own tile look — the app's round monochrome buttons (composer +, mic,
    // call-back), not the colored-square grid every other messenger uses.
    private func attachTile(_ icon: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button {
            showAttachPanel = false
            // Let the sheet finish dismissing before presenting the next picker (avoids a clash).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { action() }
        } label: {
            VStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 22, weight: .medium)).foregroundStyle(.primary)
                    .frame(width: 58, height: 58)
                    .liquidGlass(Circle(), interactive: true)   // real Liquid Glass (user request)
                Text(label).font(.caption).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
    }

    // Download the encrypted file, decrypt it, write to a temp file, and preview it (QuickLook).
    private func openFile(_ message: Message) {
        guard let s = message.fileUrl, let url = URL(string: s), let meta = message.enc else { return }
        Task {
            guard let (cipher, _) = try? await URLSession.shared.data(from: url),
                  let data = await Crypto.shared.decryptBytes(cid, cipher: cipher, meta: meta) else {
                await MainActor.run { sendError = "Couldn't open the file." }; return
            }
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(message.fileName ?? "file")
            try? data.write(to: tmp)
            await MainActor.run { filePreview = PreviewFile(url: tmp) }
        }
    }

    private func handlePickedFile(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        Task { await sendDocument(url) }
    }
    private func sendDocument(_ url: URL) async {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return }
        guard data.count <= 25 * 1024 * 1024 else {
            await MainActor.run { sendError = "File too large (max 25 MB)." }; return
        }
        let name = url.lastPathComponent
        do { try await ChatService.sendFile(cid: cid, data: data, fileName: name, group: isGroup ? groupMembers : nil) }
        catch { await MainActor.run { sendError = "Couldn't send the file. Try again." } }
    }

    // Avatar + name + presence shown in the chat header (kept glass-free — see chatToolbar).
    private var headerLabel: some View {
        // Measurements matched to Signal-iOS's ConversationHeaderView (iOS 26 variant): 40pt avatar,
        // 12pt avatar→name spacing, 17pt-semibold title (.headline), a 16×16 title-row icon at 5pt.
        HStack(spacing: 12) {
            AvatarView(name: title, photoUrl: photoUrl, size: 40)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(title).font(.headline).foregroundStyle(.primary).lineLimit(1)
                    // Constant reminder that messages self-delete here (WhatsApp shows one too) —
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
                     text: $0.isImage ? "📷 Photo" : ($0.isVideo ? "🎥 Video" : ($0.isAudio ? "🎤 Voice message" : ($0.isFile ? "📄 \($0.fileName ?? "Document")" : ($0.isGif ? "GIF" : $0.text)))))
        }
        replyingTo = nil
        typingSent = false
        // Show the bubble INSTANTLY (optimistic), then reconcile when the server echoes it.
        // Native: the bubble just appears (no custom spring), like a plain list insert.
        let clientId = UUID().uuidString
        repo.addPending(Message(localText: text, authorId: me, clientId: clientId, replyTo: reply, sendState: .sending))
        Task {
            await ChatService.setTyping(cid, false)
            await deliver(text: text, reply: reply, clientId: clientId, mentions: mentions)
        }
    }

    // Re-try a failed message: flip its bubble back to .sending and send again.
    private func resend(_ m: Message) {
        let clientId = m.clientId ?? UUID().uuidString
        repo.removePending(clientId: clientId)
        if let data = m.localImageData {
            repo.addPending(Message(localImageData: data, width: m.width ?? 1, height: m.height ?? 1,
                                    authorId: me, clientId: clientId, sendState: .sending))
            Task {
                do { try await ChatService.sendImage(cid: cid, data: data, clientId: clientId, group: isGroup ? groupMembers : nil) }
                catch { await MainActor.run { repo.markFailed(clientId: clientId) } }
            }
        } else {
            repo.addPending(Message(localText: m.text, authorId: me, clientId: clientId,
                                    replyTo: m.replyTo, sendState: .sending))
            Task { await deliver(text: m.text, reply: m.replyTo, clientId: clientId) }
        }
    }

    // Send a photo with an instant optimistic bubble, then reconcile on the echo.
    private func sendPhoto(_ data: Data) async {
        let preview = ChatService.downscaledJPEG(data)
        let size = UIImage(data: preview)?.size ?? CGSize(width: 1, height: 1)
        let clientId = UUID().uuidString
        await MainActor.run {
            repo.addPending(Message(localImageData: preview, width: Double(size.width), height: Double(size.height),
                                    authorId: me, clientId: clientId, sendState: .sending))
        }
        do { try await ChatService.sendImage(cid: cid, data: data, clientId: clientId, group: isGroup ? groupMembers : nil) }
        catch { await MainActor.run { repo.markFailed(clientId: clientId) } }
    }

    // Save a chat photo to the camera roll (decrypts if needed) with a success haptic.
    @MainActor private func saveImageToPhotos(_ m: Message) async {
        var ui: UIImage?
        if let local = m.localImageData { ui = UIImage(data: local) }
        else if let s = m.imageUrl {
            if let cached = DiskImageCache.shared.memoryImage(s) { ui = cached }
            else if let cached = await DiskImageCache.shared.image(for: s) { ui = cached }
            else if let url = URL(string: s), let (cipher, _) = try? await URLSession.shared.data(from: url) {
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

    private func deliver(text: String, reply: ReplyRef?, clientId: String, mentions: [String] = []) async {
        do {
            try await ChatService.sendText(cid: cid, text: text, replyTo: reply, clientId: clientId,
                                           group: isGroup ? groupMembers : nil, mentions: mentions)
        } catch {
            // Keep the message as a failed bubble (tap to retry); flag the encryption case.
            await MainActor.run {
                repo.markFailed(clientId: clientId)
                if error is MissingRecipientKeyError {
                    sendError = isGroup
                        ? "No one in this group has set up encryption yet. Your message will send once a member opens Kulan."
                        : "\(title) hasn't opened Kulan yet, so encryption isn't set up. Your message will send once they do."
                }
            }
        }
    }

    // Call record as a WhatsApp-style message bubble. Outgoing = right-aligned accent
    // bubble; incoming & missed = left-aligned received bubble. Inside: a circular call
    // Centered gray system event ("X added Y", "Z left", "renamed to…") — group only.
    private func systemRow(_ m: Message) -> some View {
        Text(m.text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background(Theme.received(dark).opacity(0.7), in: Capsule())
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
    }

    // icon, bold status, a muted subtitle (duration or "Tap to call back"), and the
    // timestamp bottom-right. Tap anywhere to call back.
    private func callRow(_ m: Message) -> some View {
        let mine = m.callerUid == me
        let missed = m.callOutcome == "missed"
        let video = m.callVideo
        let statusText = video ? (missed ? "Missed video call" : "Video call")
                               : (missed ? "Missed voice call" : "Voice call")
        let time = m.createdAt.formatted(date: .omitted, time: .shortened)
        // Second line: status + time, kept short so the bubble stays compact.
        let detail: String = {
            if missed { return "Tap to call back · \(time)" }
            if let d = m.callDuration, d > 0 { return "\(callLogDuration(d)) · \(time)" }
            return "\(mine ? "Outgoing" : "Incoming") · \(time)"
        }()
        let iconName = video ? (missed ? "video.slash.fill" : "video.fill")
                             : (missed ? "phone.arrow.down.left" : (mine ? "phone.arrow.up.right" : "phone.arrow.down.left"))
        let iconColor: Color = missed ? .red : (mine ? Theme.onAccent(dark) : Theme.accent(dark))
        let circleBg: Color = mine ? Color.white.opacity(0.22)
            : (missed ? Color.red.opacity(0.14) : Theme.accent(dark).opacity(0.14))

        return HStack(spacing: 0) {
            if mine { Spacer(minLength: 60) }
            // No flexible Spacer inside -> the bubble hugs its content (compact, not a banner).
            HStack(alignment: .center, spacing: 10) {
                ZStack {
                    Circle().fill(circleBg).frame(width: 34, height: 34)
                    Image(systemName: iconName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(iconColor)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(statusText)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(mine ? Theme.onAccent(dark) : .primary)
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(mine ? Theme.onAccent(dark).opacity(0.75) : .secondary)
                }
            }
            .padding(.vertical, 8).padding(.horizontal, 12)
            .background(mine ? Theme.accent(dark) : Theme.received(dark))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            // Tap target is ONLY the bubble — NOT the full-width row. The old .contentShape/
            // .onTapGesture sat on the outer HStack (which includes the empty-side Spacer), so
            // tapping the blank space anywhere on the row placed a call (accidental-call bug).
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .onTapGesture { CallService.shared.startCall(to: otherUid, name: title, photo: photoUrl, video: video) }   // call back the same way it was placed
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
    private func revealAtOpenAnchor(_ proxy: ScrollViewProxy) {
        let a = openAnchor
        DispatchQueue.main.async {
            proxy.scrollTo(a.id, anchor: a.edge)              // pass 1 (approximate on a cold load)
            // Pass 2 after a short beat: on a COLD open the LazyVStack is still instantiating rows and
            // async images are still sizing, so one runloop isn't enough — the position was landing
            // approximately, then reflowing (the jump). Wait ~2 frames so heights settle, re-pin, then
            // a final same-runloop pin, and only THEN drop the veil — so the settle happens unseen.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.033) {
                proxy.scrollTo(a.id, anchor: a.edge)          // pass 2 after layout + image sizing
                DispatchQueue.main.async {
                    proxy.scrollTo(a.id, anchor: a.edge)      // pass 3 final → exact position
                    revealed = true
                }
            }
        }
        enableSlideInAfterReveal()
    }

    // Pin to the newest message across two frames: the first pin lands on the pre-insert layout, the
    // second (next runloop, after the new row is measured) corrects it — so a freshly-arrived bubble
    // can never leave a visible jump. Used for both my sends and received-while-at-bottom.
    private func pinBottomStable(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            proxy.scrollTo("BOTTOM", anchor: .bottom)
            DispatchQueue.main.async { proxy.scrollTo("BOTTOM", anchor: .bottom) }
        }
    }

    // Turn on the message-row slide-in transition a beat AFTER the chat has revealed, so the
    // opening batch appears with zero movement (WhatsApp) and only genuinely-new messages slide in.
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
        let idx = max(0, msgs.count - unreadOnOpen)
        guard idx < msgs.count else { return }
        // Just mark WHERE the unread divider goes — do NOT scroll to it. The chat always opens at
        // the BOTTOM (newest), like a standard messenger; the divider is a marker you scroll up to.
        // (Scrolling to the first unread dropped the user into old history / old missed calls.)
        firstUnreadId = msgs[idx].id
        didAnchorUnread = true
    }

    // Toggle my reaction (re-tapping the same emoji removes it) and remember it as recent.
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
        withAnimation(.easeInOut) { proxy.scrollTo(id, anchor: .center) }
        highlightId = id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            if highlightId == id { withAnimation { highlightId = nil } }
        }
    }

    // Tapped a "Status" reply quote → open that status if it's still live, else say it's gone.
    // The repo only holds unexpired stories, so "found" == still viewable.
    private func openStory(_ storyId: String, _ authorId: String, anchorId: String = "") {
        replyStoryAnchorId = anchorId
        let repo = StoriesRepository.shared
        let active = (repo.others + [repo.mine].compactMap { $0 })
            .first { $0.authorUid == authorId && $0.stories.contains { $0.id == storyId } }
        if let active { storyToOpen = active } else { statusUnavailable = true }
    }

    private func sendPicked(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        defer { photoItem = nil }
        if let data = try? await item.loadTransferable(type: Data.self) {
            await sendPhoto(data)
        }
    }

    // Multi-select: send each chosen photo/video in order (native PhotosUI multi-pick).
    private func sendPickedMulti(_ items: [PhotosPickerItem]) async {
        guard !items.isEmpty else { return }
        let picked = items
        await MainActor.run { photoItems = [] }
        // A single PHOTO opens the editor (crop/draw/adjust/caption); videos and
        // multi-picks send directly.
        if picked.count == 1, !isVideoItem(picked[0]),
           let data = try? await picked[0].loadTransferable(type: Data.self),
           let ui = UIImage(data: data) {
            await MainActor.run { editImage = EditImageWrap(image: ui) }
            return
        }
        for item in picked {
            if isVideoItem(item) {
                if let movie = try? await item.loadTransferable(type: PickedMovie.self) {
                    await sendVideo(from: movie.url)
                }
            } else if let data = try? await item.loadTransferable(type: Data.self) {
                await sendPhoto(data)
            }
        }
    }

    private func isVideoItem(_ item: PhotosPickerItem) -> Bool {
        item.supportedContentTypes.contains { $0.conforms(to: .movie) }
    }

    // Transcode → optimistic thumbnail bubble → E2EE upload (ChatService.sendVideo keeps
    // the sender's copy on-device; the recipient's player deletes the server object).
    private func sendVideo(from url: URL) async {
        guard let prepared = await VideoTranscoder.prepare(url) else {
            try? FileManager.default.removeItem(at: url)
            await MainActor.run { sendError = "Couldn't process this video." }
            return
        }
        try? FileManager.default.removeItem(at: url)
        guard prepared.data.count <= Limits.videoMessageBytes else {
            await MainActor.run { sendError = "This video is too long to send (max \(Limits.videoMessageBytes / 1_048_576) MB after compression)." }
            return
        }
        let clientId = UUID().uuidString
        await MainActor.run {
            repo.addPending(Message(localVideoThumb: prepared.thumbnail, duration: prepared.duration,
                                    width: prepared.width, height: prepared.height,
                                    authorId: me, clientId: clientId, sendState: .sending))
        }
        do {
            try await ChatService.sendVideo(cid: cid, video: prepared.data, thumbnail: prepared.thumbnail,
                                            duration: prepared.duration, width: prepared.width, height: prepared.height,
                                            clientId: clientId, group: isGroup ? groupMembers : nil)
        } catch { await MainActor.run { repo.markFailed(clientId: clientId) } }
    }

    // When I've blocked this contact, the composer is replaced by an unblock bar —
    // you genuinely can't send while blocked (real enforcement, not cosmetic).
    private var blockedBar: some View {
        VStack(spacing: 6) {
            Text("You blocked \(title)").font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
            Button("Unblock") { Task { await ChatService.setBlocked(cid, false) } }
                .font(.subheadline.weight(.semibold))
                .tint(.red)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(.bar)
    }

    // A group I'm no longer in (removed by an admin, or left on another device): the conv is
    // still cached but I'm not in `users`. Show a non-interactive bar instead of the composer.
    private var notAMember: Bool {
        guard !cid.contains("_") else { return false }       // 1:1 chats are never "removed"
        guard let conv = conversation else { return false }  // not loaded yet → don't assume
        return !conv.users.contains(AuthService.shared.uid ?? "")
    }

    private var removedBar: some View {
        Text("You're no longer a member of this group")
            .font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(.bar)
    }

    // Announcement mode: a non-admin member can't send (enforced server-side too).
    private var cannotSendAnnouncement: Bool {
        guard let conv = conversation, conv.isGroup else { return false }
        return !conv.canSend(AuthService.shared.uid ?? "")
    }

    private var announcementBar: some View {
        Label("Only admins can send messages", systemImage: "megaphone")
            .font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(.bar)
    }

    // The reply preview now nests INSIDE the input capsule (see inputRow).
    private var composerArea: some View { composer }

    // Active-reply preview row, shown inside the input capsule above the text field.
    private func replyPreviewRow(_ r: Message) -> some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 1.5).fill(Color.accentColor).frame(width: 3, height: 34)
            // Real image thumbnail when replying to a photo (Telegram/WhatsApp-style).
            if r.isImage, let url = r.imageUrl {
                SecureImageView(imageUrl: url, enc: r.enc, cid: cid)
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
    }

    // Inline edit preview (Telegram-style): pencil + "Edit Message" + snippet + cancel (X).
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
    }

    private func cancelEdit() {
        withAnimation(.easeInOut(duration: 0.2)) { editingMessage = nil }
        input = Drafts.shared.text(cid)   // bring back whatever was drafted before the edit began
        inputFocused = false
    }

    // Save the inline edit, then clear the edit state (replaces the old full-screen sheet).
    private func saveEdit() {
        guard let e = editingMessage else { return }
        let newText = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newText.isEmpty else { return }
        Task { try? await ChatService.editMessage(cid: cid, messageId: e.id, newText: newText, group: isGroup ? groupMembers : nil) }
        withAnimation(.easeInOut(duration: 0.2)) { editingMessage = nil }
        input = Drafts.shared.text(cid)   // the pre-edit draft (if any) was never sent — restore it
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
        } else if r.isImage {
            Text("Photo").font(.caption).foregroundStyle(.secondary)
        } else {
            Text(r.text).font(.caption).lineLimit(1).foregroundStyle(.secondary)
        }
    }
    private func replyVoiceDuration(_ r: Message) -> String {
        let d = Int(r.duration ?? 0); return String(format: "%d:%02d", d / 60, d % 60)
    }

    // Subtle neutral fill (no glass, no shadow) — the iMessage field tint.
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

    private var composer: some View {
        VStack(spacing: 6) {
            if !mentionCandidates.isEmpty { mentionPicker }
            Group {
                if recordLocked { lockedRecordingBar } else { inputRow }
            }
        }
        .padding(.horizontal, 16)   // spec: 16pt left/right margin
        .padding(.top, 6)
        .padding(.bottom, 8)
        .overlay(alignment: .top) {
            if holdHint {
                Text("Hold to record, release to send")
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.black.opacity(0.8), in: Capsule())
                    .offset(y: -8)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
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
        // Bypass the GlassEffectContainer WHILE RECORDING: as the mic offsets up to lock, the
        // container morphs a fluid glass "bridge" that tracks the drag (the blur trail the user
        // wants gone). No grouping during recording = no morph.
        composerGlassContainer(grouped: !recordingHeld) {
        HStack(alignment: .bottom, spacing: 8) {   // "+" outside-left, everything else in the field
            if !recordingHeld {
                Button { showAttachPanel = true } label: {
                    Image(systemName: sendingPhoto ? "ellipsis" : "plus")
                        .font(.system(size: 20, weight: .regular))
                        .foregroundStyle(.primary)
                        .contentTransition(.symbolEffect(.replace))   // smooth +/… swap
                        .frame(width: 40, height: 40)
                        .liquidGlass(Circle(), interactive: true)
                }
                .tint(.primary)
                .transition(.scale.combined(with: .opacity))
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
                HStack(alignment: .bottom, spacing: 4) {
                    if recordingHeld {
                        recordingHoldRow
                        micButton            // stays at the right edge to hold/slide/lock
                    } else {
                        messageField
                        if !hasText { inFieldGif; inFieldCamera; micButton }   // sticker · camera · mic, all IN the pill
                    }
                }
                .frame(minHeight: 40)   // input row stays 40px even in voice mode
            }
            // While RECORDING: a SOLID pill (no blur at all). Any material/glass here rendered a blur
            // (and a blurred ghost that read as a duplicate input bar) — user wants the recording bar
            // clean. Normal state keeps the interactive iMessage glass field.
            .background {
                if recordingHeld {
                    RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color(.secondarySystemBackground))
                }
            }
            .liquidGlass(RoundedRectangle(cornerRadius: 20, style: .continuous), interactive: true, enabled: !recordingHeld)

            // Mic (hold-to-record) OR Send — a standalone button OUTSIDE the field, like "+".
            rightButton
        }
        }
        .animation(.easeInOut(duration: 0.2), value: hasText)
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: recordingHeld)
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
        TextField("Message", text: $input, axis: .vertical)
            .font(.system(size: 17))
            .lineLimit(1...6)
            .focused($inputFocused)
            .padding(.leading, 14)
            .padding(.vertical, 9)   // single-line field height ~40 to match the + button
            .onChange(of: input) { _, v in
                // Don't broadcast "typing" while we're seeding the field for an inline EDIT.
                let now = editingMessage == nil && !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                if now != typingSent {
                    typingSent = now
                    Task { await ChatService.setTyping(cid, now) }
                }
            }
    }

    // Camera lives INSIDE the field (right), only when not typing/recording.
    private var inFieldCamera: some View {
        Button { showCamera = true } label: {
            Image("ic_camera").renderingMode(.template).resizable().scaledToFit()
                .frame(width: 24, height: 24).foregroundStyle(.secondary)
        }
        .padding(.trailing, 2).padding(.bottom, 7)
    }
    // One-tap GIFs from the field (big apps keep GIFs next to the camera, not buried in +).
    private var inFieldGif: some View {
        Button { showGifPicker = true } label: {
            Image("ic_gif").renderingMode(.template).resizable().scaledToFit()
                .frame(width: 24, height: 24).foregroundStyle(.secondary)
        }
        .padding(.trailing, 2).padding(.bottom, 7)
    }

    // Standalone SEND button OUTSIDE the field (like "+"), only while typing. When not typing the
    // mic lives INSIDE the pill (next to sticker/camera), so there's no outside button then.
    @ViewBuilder private var rightButton: some View {
        if hasText {
            Button { if editingMessage != nil { saveEdit() } else { send() } } label: {
                Image(systemName: editingMessage != nil ? "checkmark.circle.fill" : "arrow.up.circle.fill")
                    .font(.system(size: 38)).foregroundStyle(Theme.accent(dark))
                    .contentTransition(.symbolEffect(.replace))
            }
            .transition(.scale.combined(with: .opacity))
        }
    }

    // Live recording row inside the capsule: red dot + timer + "‹ slide to cancel".
    private var recordingHoldRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "mic.fill")
                .font(.system(size: 18)).foregroundStyle(.red)
                .symbolEffect(.pulse, options: .repeating)   // gentle live pulse, like Telegram
            RecordTimerText(recorder: recorder)
            Spacer(minLength: 8)
            HStack(spacing: 3) {
                Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold))
                Text("slide to cancel").font(.system(size: 14))
            }
            .foregroundStyle(recordCancelArmed ? Color.red : Color.secondary)
            .animation(.easeInOut(duration: 0.15), value: recordCancelArmed)
            // Fade the hint as the finger slides toward the cancel threshold.
            .opacity(1.0 - min(1.0, Double(-clampedDrag.width) / 90.0) * 0.6)
        }
        .padding(.horizontal, 14).frame(height: 40)   // strict 40px during recording — no vertical distortion
    }

    // Hold-to-record (Signal/WhatsApp-style, our own code on the AudioRecorder engine):
    //   • press & hold the mic  → recording starts instantly (session is pre-warmed)
    //   • slide LEFT past the threshold, release → cancel (discard)
    //   • slide UP into the lock target → hands-free lock (finger can lift; bar takes over)
    //   • release without cancel/lock → send
    // Rubber-banded drag + haptics at each threshold. A quick tap (too short) flashes the hint.
    private static let cancelThreshold: CGFloat = 80
    private static let lockThreshold: CGFloat = 88
    private var lockProgress: CGFloat { min(1, max(0, -clampedDrag.height / Self.lockThreshold)) }

    private var micButton: some View {
        Image("ic_mic")
            .renderingMode(.template).resizable().scaledToFit()
            .foregroundStyle(recordingHeld ? .white : .secondary)   // matches sticker/camera when idle
            .frame(width: recordingHeld ? 18 : 22, height: recordingHeld ? 22 : 24)
            .frame(width: recordingHeld ? 40 : 24, height: recordingHeld ? 40 : 24)   // grows to a puck when held
            .background {
                if recordingHeld {   // big RED mic circle (Telegram) — scaled up so it reads large
                    Circle().fill(Color.red).scaleEffect(1.5)
                        .shadow(color: .red.opacity(0.4), radius: 8)
                }
            }
            // .offset renders the mic shifted WITHOUT moving its layout frame, so the lock target
            // (overlaid after) stays pinned above the original slot while the mic slides up to meet it.
            .offset(x: recordingHeld ? clampedDrag.width : 0,
                    y: recordingHeld ? clampedDrag.height : 0)
            .overlay(alignment: .center) {
                if recordingHeld && !recordCancelArmed {
                    lockTarget.offset(y: -82).allowsHitTesting(false)
                }
            }
            .contentShape(Circle())
            .gesture(recordDragGesture)
            .padding(.trailing, recordingHeld ? 6 : 12).padding(.bottom, 7)   // sit inside the pill's right edge
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: recordingHeld)
            .animation(.easeInOut(duration: 0.12), value: recordCancelArmed)
    }

    // Lock target floating above the mic — fills toward accent as you slide up, then locks.
    private var lockTarget: some View {
        VStack(spacing: 5) {
            Image(systemName: lockProgress > 0.7 ? "lock.fill" : "lock.open.fill")
                .font(.system(size: 13, weight: .semibold))
            Image(systemName: "chevron.up")
                .font(.system(size: 11, weight: .bold))
                .opacity(1 - lockProgress)
        }
        .foregroundStyle(lockProgress > 0.6 ? .white : .primary)
        .frame(width: 40)
        .padding(.vertical, 12)
        // Fills toward red as you slide up (matches the red mic), on a soft glass pill.
        .background {
            ZStack {
                Capsule().fill(.ultraThinMaterial)
                Capsule().fill(Color.red.opacity(lockProgress * 0.9))
            }
        }
        .overlay(Capsule().stroke(.white.opacity(0.15), lineWidth: 0.5))
        .scaleEffect(0.9 + lockProgress * 0.12)
    }

    private var recordDragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                // First change = touch-down (minimumDistance 0): start recording once (multi-touch/
                // double-start guarded by holdStarted). Instant because the session is pre-warmed.
                if !holdStarted && !recordLocked {
                    holdStarted = true
                    recorder.requestAndStart()
                    impact(.medium)
                }
                guard holdStarted, !recordLocked else { return }
                recordDrag = v.translation
                let armed = clampedDrag.width < -Self.cancelThreshold
                if armed != recordCancelArmed {
                    recordCancelArmed = armed
                    impact(.soft)     // tick when crossing the cancel line
                }
                if clampedDrag.height < -Self.lockThreshold { lockRecording() }
            }
            .onEnded { _ in
                guard holdStarted, !recordLocked else { return }   // locked = keep going, bar owns it
                if recordCancelArmed {
                    cancelRecording()
                } else if recorder.elapsed < 0.5 {
                    cancelRecording(); flashHoldHint()   // accidental tap → discard + "hold to record"
                } else {
                    sendRecording()
                }
            }
    }

    // Locked (hands-free) recording bar — shown after you slide up to lock: delete · timer + waveform · send.
    private var lockedRecordingBar: some View {
        HStack(spacing: 12) {
            Button { cancelRecording() } label: {
                Image(systemName: "trash.fill").font(.system(size: 18)).foregroundStyle(.red)
                    .frame(width: 40, height: 40).liquidGlass(Circle(), interactive: true)
            }
            HStack(spacing: 8) {
                Image(systemName: "lock.fill").font(.system(size: 12)).foregroundStyle(.secondary)
                RecordTimerText(recorder: recorder)
                RecordWaveform(recorder: recorder, color: Theme.accent(dark))
            }
            .padding(.horizontal, 14).frame(minHeight: 40)
            .liquidGlass(Capsule(), interactive: true)
            Button { sendRecording() } label: {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 38))
                    .foregroundStyle(Theme.accent(dark))
            }
        }
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
        recorder.cancel()
        notify(.warning)
        resetRecordingState()
    }
    private func sendRecording() {
        Task { await stopAndSendAudio() }
        impact(.light)
        resetRecordingState()
    }
    private func resetRecordingState() {
        withAnimation { recordLocked = false; recordDrag = .zero; recordCancelArmed = false; holdStarted = false }
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

    private func stopAndSendAudio() async {
        guard let (data, dur, wf) = recorder.finish() else { return }
        // Optimistic: show the voice bubble INSTANTLY (springs in, playable from the local
        // recording), then reconcile when the upload echoes back — no dead lag on release.
        let clientId = UUID().uuidString
        // Bug 1: a voice note recorded while replying must carry the reply (works for photo/voice
        // targets too), and the reply bar must clear after sending.
        let reply = replyingTo.map {
            ReplyRef(id: $0.id, authorId: $0.authorId,
                     text: $0.isImage ? "📷 Photo" : ($0.isVideo ? "🎥 Video" : ($0.isAudio ? "🎤 Voice message" : ($0.isFile ? "📄 \($0.fileName ?? "Document")" : ($0.isGif ? "GIF" : $0.text)))))
        }
        await MainActor.run {
            repo.addPending(Message(localAudioData: data, duration: dur, waveform: wf,
                                    authorId: me, clientId: clientId, sendState: .sending))
            replyingTo = nil
        }
        do { try await ChatService.sendAudio(cid: cid, data: data, duration: dur, waveform: wf, replyTo: reply, clientId: clientId, group: isGroup ? groupMembers : nil) }
        catch { await MainActor.run { repo.markFailed(clientId: clientId) } }
    }

    private func sendCaptured(_ data: Data) async {
        await sendPhoto(data)
    }
}

struct MessageBubble: View, Equatable {
    // Equatable so SwiftUI skips re-rendering a bubble whose VALUE inputs are unchanged, even when
    // the parent re-evaluates and passes fresh closures (the re-render storm from typing / read
    // receipts / chat-list churn). Closures + @State are intentionally NOT compared.
    static func == (l: MessageBubble, r: MessageBubble) -> Bool {
        l.message == r.message && l.isMe == r.isMe && l.dark == r.dark && l.cid == r.cid
            && l.isGroup == r.isGroup && l.canPin == r.canPin && l.isPinned == r.isPinned
            && l.isHighlighted == r.isHighlighted
            && l.isFirstInCluster == r.isFirstInCluster && l.isLastInCluster == r.isLastInCluster
            && l.otherLastRead == r.otherLastRead
    }

    let message: Message
    let isMe: Bool
    let dark: Bool
    let cid: String
    var nameFor: (String) -> String = { _ in "" }
    var avatarFor: (String) -> String? = { _ in nil }
    var onReply: (Message) -> Void = { _ in }
    var onDelete: (Message) -> Void = { _ in }
    var onTapImage: (Message) -> Void = { _ in }
    var onTapVideo: (Message) -> Void = { _ in }
    var onReact: (String?) -> Void = { _ in }
    var onPin: (Message) -> Void = { _ in }
    var onForward: (Message) -> Void = { _ in }
    var onEdit: (Message) -> Void = { _ in }
    var onReport: (Message) -> Void = { _ in }
    var onReactMore: (Message) -> Void = { _ in }
    var isGroup: Bool = false   // drives per-sender name labels above others' bubbles in groups
    var onTapReactions: () -> Void = {}
    var onTapSender: (String) -> Void = { _ in }
    var onOpenFile: (Message) -> Void = { _ in }
    var onSaveImage: (Message) -> Void = { _ in }
    var canPin: Bool = true
    var isPinned: Bool = false

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
    var onLongPress: (Message) -> Void = { _ in }
    var onResend: (Message) -> Void = { _ in }
    var onJumpTo: (String) -> Void = { _ in }
    var onTapStory: (_ storyId: String, _ authorId: String, _ anchorId: String) -> Void = { _, _, _ in }
    var replyStoryNS: Namespace.ID? = nil   // native zoom anchor for the story-quote thumbnail
    var isHighlighted: Bool = false
    var isFirstInCluster: Bool = true
    var isLastInCluster: Bool = true
    var otherLastRead: Double = 0

    @State private var dragX: CGFloat = 0
    @State private var pendingLink: URL?          // web link tapped -> "Open link?" confirm
    @State private var notFoundUser = false       // @username tapped but no such user
    @AppStorage("readReceipts") private var readReceiptsPref = true

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

    private var bodyText: Text {
        let full = message.text
        var str = AttributedString(full)
        str.font = .system(size: 17)
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
            str[lo..<hi].foregroundColor = .blue
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
                    notFoundUser = true
                }
            }
            return .handled
        }
        pendingLink = url
        return .handled
    }

    // Aggregate uid->emoji into (emoji, count, mine), most-popular first (Signal's logic,
    // our own pill design). Ties broken by emoji for a stable order.
    private var reactionCounts: [(emoji: String, count: Int, mine: Bool)] {
        Dictionary(grouping: message.reactions.values, by: { $0 })
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
    // red "!" if it failed, single check when sent, filled check once the other read it.
    @ViewBuilder private var metaRow: some View {
        HStack(spacing: 3) {
            if message.edited { Text("edited").font(.system(size: 10)).italic() }
            Text(timeString).font(.system(size: 10))
            if isMe {
                switch message.sendState {
                case .sending:
                    Image(systemName: "clock").font(.system(size: 9, weight: .semibold))
                case .failed:
                    Image(systemName: "exclamationmark.circle.fill").font(.system(size: 10)).foregroundStyle(.red)
                case nil:
                    Image(systemName: (isRead && readReceiptsPref) ? "checkmark.circle.fill" : "checkmark")
                        .font(.system(size: 9, weight: .semibold))
                        .contentTransition(.symbolEffect(.replace))   // tick "turns read" with a morph
                }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: isRead)
        .foregroundStyle(isMe ? Theme.onAccent(dark).opacity(0.7) : Color.secondary)
    }

    // Bubbles cap at 72% of screen width and wrap; the right (sent) / left (received)
    // edge stays a clean, uniform line regardless of length.
    private var maxBubbleWidth: CGFloat { UIScreen.main.bounds.width * 0.72 }

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
    @ViewBuilder private var reactionBadges: some View {
        let all = reactionCounts
        if !all.isEmpty {
            let shown = Array(all.prefix(3))
            let extra = all.count - shown.count
            HStack(spacing: 4) {
                ForEach(shown, id: \.emoji) { r in
                    HStack(spacing: 3) {
                        Text(r.emoji).font(.system(size: 12))
                        if r.count > 1 {
                            Text("\(r.count)").font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(r.mine ? Color.accentColor : .secondary)
                        }
                    }
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(r.mine ? Color.accentColor.opacity(0.18) : Theme.received(dark), in: Capsule())
                    .overlay(Capsule().stroke(Color.accentColor.opacity(r.mine ? 0.9 : 0), lineWidth: 1))
                }
                if extra > 0 {
                    Text("+\(extra)").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
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
                    Text(nameFor(message.authorId))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(senderColor)
                        .padding(.leading, 12)
                        .onTapGesture { onTapSender(message.authorId) }
                }
                content
                    // Tappable links/usernames inside the bubble route through here.
                    .environment(\.openURL, OpenURLAction { url in routeTappedURL(url) })
                    .confirmationDialog("Open link?",
                                        isPresented: Binding(get: { pendingLink != nil },
                                                             set: { if !$0 { pendingLink = nil } }),
                                        titleVisibility: .visible, presenting: pendingLink) { url in
                        Button("Open") { UIApplication.shared.open(url) }
                        Button("Cancel", role: .cancel) {}
                    } message: { url in Text(url.absoluteString) }
                    .alert("Sorry, this user doesn't seem to exist.", isPresented: $notFoundUser) {
                        Button("OK", role: .cancel) {}
                    }
                    // REAL native context menu (same as the chat list) — iOS handles the
                    // lift + blur + spring. No custom overlay.
                    .contextMenu {
                        Button { onReply(message) } label: { Label("Reply", systemImage: "arrowshape.turn.up.left") }
                        if !message.text.isEmpty {
                            Button { UIPasteboard.general.string = message.text } label: { Label("Copy", systemImage: "doc.on.doc") }
                        }
                        if message.isImage {
                            Button { onSaveImage(message) } label: { Label("Save Image", systemImage: "square.and.arrow.down") }
                        }
                        if isMe && !message.isImage && !message.isAudio && !message.isCall && message.sendState == nil {
                            Button { onEdit(message) } label: { Label("Edit", systemImage: "pencil") }
                        }
                        if canPin {
                            Button { onPin(message) } label: {
                                Label(isPinned ? "Unpin" : "Pin", systemImage: isPinned ? "pin.slash" : "pin")
                            }
                        }
                        if !message.isCall {
                            Button { onForward(message) } label: { Label("Forward", systemImage: "arrowshape.turn.up.right") }
                        }
                        if message.sendState == nil {   // can't react until the message is on the server
                            Button { onReactMore(message) } label: { Label("React…", systemImage: "face.smiling") }
                        }
                        Divider()
                        if isMe {
                            Button(role: .destructive) { onDelete(message) } label: { Label("Delete", systemImage: "trash") }
                        } else {
                            Button(role: .destructive) { onReport(message) } label: { Label("Report", systemImage: "flag") }
                        }
                    }
                    // Double-tap to quick-react with a heart (iMessage/WhatsApp-style).
                    .highPriorityGesture(TapGesture(count: 2).onEnded {
                        guard message.sendState == nil else { return }   // not until it's on the server
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        onReact(myReaction == "❤️" ? nil : "❤️")
                    })
                reactionBadges
                    .animation(.spring(response: 0.35, dampingFraction: 0.6), value: message.reactions)   // pop in/out
                if isMe && message.sendState == .failed {
                    Button { onResend(message) } label: {
                        Label("Not delivered. Tap to retry", systemImage: "arrow.clockwise")
                            .font(.system(size: 11, weight: .medium)).foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 1)
                }
            }
            .frame(maxWidth: maxBubbleWidth, alignment: isMe ? .trailing : .leading)
            if !isMe { Spacer(minLength: 0) }
        }
        // Brief accent flash when jumped-to via a reply tap.
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.accentColor.opacity(isHighlighted ? 0.12 : 0))
                .padding(.horizontal, -6)
        )
        .animation(.easeInOut(duration: 0.25), value: isHighlighted)
        // Telegram-style swipe-to-reply: drag the bubble left past a threshold.
        .overlay(alignment: .trailing) {
            Image(systemName: "arrowshape.turn.up.left.fill")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .opacity(Double(min(abs(min(dragX, 0)) / 50, 1)))
                .padding(.trailing, 6)
        }
        .offset(x: dragX)
        .simultaneousGesture(
            DragGesture(minimumDistance: 18)
                .onChanged { v in if v.translation.width < 0 { dragX = max(v.translation.width, -70) } }
                .onEnded { _ in
                    if dragX < -50 {
                        onReply(message)
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    }
                    // Smooth, gentle glide back (not a fast snap).
                    withAnimation(.spring(response: 0.5, dampingFraction: 0.86)) { dragX = 0 }
                }
        )
    }

    @ViewBuilder private var content: some View {
        if message.isAudio {
            VStack(alignment: .leading, spacing: 4) {
                replyQuote
                VoiceMessageView(message: message, cid: cid, isMe: isMe, dark: dark)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 9)
            .background(isMe ? Theme.accent(dark) : Theme.received(dark))
            .clipShape(UnevenRoundedRectangle(cornerRadii: bubbleCorners, style: .continuous))
        } else if message.isFile {
            VStack(alignment: .leading, spacing: 4) {
                replyQuote
                Button { onOpenFile(message) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "doc.fill").font(.system(size: 26))
                            .foregroundStyle(isMe ? Theme.onAccent(dark) : Color.accentColor)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(message.fileName ?? "Document")
                                .font(.system(size: 15, weight: .medium)).lineLimit(1)
                            Text(fileSizeLabel).font(.caption)
                                .foregroundStyle(isMe ? Theme.onAccent(dark).opacity(0.8) : .secondary)
                        }
                    }
                }
                .foregroundStyle(isMe ? Theme.onAccent(dark) : (dark ? .white : .black))
            }
            .padding(.horizontal, 13).padding(.vertical, 10)
            .background(isMe ? Theme.accent(dark) : Theme.received(dark))
            .clipShape(UnevenRoundedRectangle(cornerRadii: bubbleCorners, style: .continuous))
        } else if message.isGif {
            VStack(alignment: .leading, spacing: 4) {
                replyQuote
                if let url = message.imageUrl {
                    AnimatedGifView(url: url)
                        .frame(width: imageDisplaySize.width, height: imageDisplaySize.height)
                        .clipShape(UnevenRoundedRectangle(cornerRadii: bubbleCorners, style: .continuous))
                }
            }
        } else if message.isVideo {
            VStack(alignment: .leading, spacing: 4) {
                replyQuote
                Group {
                    if let data = message.localImageData, let ui = UIImage(data: data) {
                        Image(uiImage: ui).resizable().scaledToFill()          // optimistic local thumbnail
                    } else if let url = message.thumbUrl {
                        SecureImageView(imageUrl: url, enc: message.thumbEnc, cid: cid)
                    } else {
                        Rectangle().fill(Color.gray.opacity(0.18))
                    }
                }
                .frame(width: imageDisplaySize.width, height: imageDisplaySize.height)
                .clipShape(UnevenRoundedRectangle(cornerRadii: bubbleCorners, style: .continuous))
                .overlay {   // upload ring while sending, play disc once delivered
                    if message.sendState == .sending {
                        ZStack {
                            Color.black.opacity(0.18)
                            ProgressView().progressViewStyle(.circular).tint(.white)
                                .padding(15)
                                .background(.ultraThinMaterial, in: Circle())
                                .environment(\.colorScheme, .dark)
                                .overlay(Circle().stroke(.white.opacity(0.15), lineWidth: 1))
                        }
                        .clipShape(UnevenRoundedRectangle(cornerRadii: bubbleCorners, style: .continuous))
                    } else {
                        Image(systemName: "play.fill")
                            .font(.system(size: 22)).foregroundStyle(.white)
                            .padding(16)
                            .background(.black.opacity(0.45), in: Circle())
                    }
                }
                .overlay(alignment: .topLeading) {   // length chip, WhatsApp-style corner
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
                    metaRow
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(.black.opacity(0.35), in: Capsule())
                        .foregroundStyle(.white)
                        .padding(7)
                }
                .onTapGesture {
                    if message.sendState == .failed { onResend(message) }
                    else if message.sendState == nil { onTapVideo(message) }   // only delivered videos play
                }
            }
        } else if message.isImage {
            VStack(alignment: .leading, spacing: 4) {
                replyQuote
                Group {
                    if let data = message.localImageData, let ui = UIImage(data: data) {
                        Image(uiImage: ui).resizable().scaledToFill()          // optimistic local photo
                    } else if let url = message.imageUrl {
                        SecureImageView(imageUrl: url, enc: message.enc, cid: cid)
                    } else {
                        Rectangle().fill(Color.gray.opacity(0.18))
                    }
                }
                .frame(width: imageDisplaySize.width, height: imageDisplaySize.height)
                .clipShape(UnevenRoundedRectangle(cornerRadii: bubbleCorners, style: .continuous))
                .overlay {   // clean WhatsApp/Telegram-style upload indicator (ring in a frosted disc)
                    if message.sendState == .sending {
                        ZStack {
                            Color.black.opacity(0.18)
                            ProgressView().progressViewStyle(.circular).tint(.white)
                                .padding(15)
                                .background(.ultraThinMaterial, in: Circle())
                                .environment(\.colorScheme, .dark)
                                .overlay(Circle().stroke(.white.opacity(0.15), lineWidth: 1))
                        }
                        .clipShape(UnevenRoundedRectangle(cornerRadii: bubbleCorners, style: .continuous))
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    metaRow
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(.black.opacity(0.35), in: Capsule())
                        .foregroundStyle(.white)
                        .padding(7)
                }
                .onTapGesture {
                    if message.sendState == .failed { onResend(message) }
                    else if message.localImageData == nil { onTapImage(message) }   // only open uploaded photos
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                replyQuote
                // Text + time laid out in a real HStack so the time can never
                // overlap the words. Short msgs => same line; long msgs => the
                // text wraps and the time stays at the bottom-right corner.
                HStack(alignment: .bottom, spacing: 6) {
                    bodyText
                        .foregroundColor(isMe ? Theme.onAccent(dark) : (dark ? .white : .black))
                    if isLastInCluster { metaRow.padding(.bottom, 1) }   // time once per cluster
                }
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 10)
            .background(isMe ? Theme.accent(dark) : Theme.received(dark))
            .clipShape(UnevenRoundedRectangle(cornerRadii: bubbleCorners, style: .continuous))
        }
    }

    @ViewBuilder private var replyQuote: some View {
        if let reply = message.replyTo {
            let fg = isMe ? Theme.onAccent(dark) : (dark ? Color.white : .black)
            HStack(spacing: 7) {
                // Left accent line signalling a quoted reply.
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(fg.opacity(0.7))
                    .frame(width: 3)
                // Status reply → show the status thumbnail (WhatsApp-style).
                if reply.isStatus, let thumb = reply.storyThumbUrl, !thumb.isEmpty {
                    StoryImage(url: thumb)
                        .frame(width: 30, height: 38)
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                        // Unique per MESSAGE (two replies can quote the same story — duplicate
                        // hero ids glitch the transition).
                        .modifier(ReplyStoryAnchor(ns: replyStoryNS, id: "reply-\(message.id)"))
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(reply.authorId == AuthService.shared.uid ? "You" : nameFor(reply.authorId))
                        .font(.caption.weight(.semibold)).foregroundStyle(fg.opacity(0.9))
                    Text(reply.isStatus ? "Status" : (reply.text.isEmpty ? "Message" : reply.text))
                        .font(.caption).lineLimit(1).foregroundStyle(fg.opacity(0.75))
                }
                // No greedy Spacer here: it made the quote grab the full bubble width,
                // so a tiny "hhhh" reply still drew a full-width card. Letting the HStack
                // hug its content means the card grows only as big as it needs to.
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            // Tint the quote box with the (contrasting) text color so it's always visible —
            // the old white tint vanished on the white "mine" bubble in dark mode.
            .background(fg.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
            .onTapGesture {
                if reply.isStatus { onTapStory(reply.id, reply.authorId, "reply-\(message.id)") }   // open the status (or "no longer available")
                else { onJumpTo(reply.id) }                                  // jump to the original message
            }
        }
    }
}

// Marks a reply-quote thumbnail as the story cover's zoom hero source (optional ns so
// bubbles without the namespace are untouched).
private struct ReplyStoryAnchor: ViewModifier {
    let ns: Namespace.ID?
    let id: String
    func body(content: Content) -> some View {
        if let ns {
            content.matchedTransitionSource(id: id, in: ns)
        } else {
            content
        }
    }
}

// In-list typing indicator: a received-style bubble with three waving dots.
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
    @Binding var reportTarget: Message?
    var onDeleteForMe: (Message) -> Void = { _ in }

    func body(content: Content) -> some View {
        content
            // Native alert (the confirmationDialog rendered as an anchored popover on iOS 26). My own
            // message → "Delete for Everyone" (removes the doc) + "Delete for Me" (local hide);
            // someone else's → "Delete for Me" only.
            .alert("Delete this message?",
                   isPresented: Binding(get: { pendingDelete != nil },
                                        set: { if !$0 { pendingDelete = nil } })) {
                if let m = pendingDelete {
                    if m.authorId == me {
                        Button("Delete for Everyone", role: .destructive) {
                            Task { await ChatService.deleteMessage(cid: cid, messageId: m.id) }
                            pendingDelete = nil
                        }
                    }
                    Button("Delete for Me", role: .destructive) {
                        onDeleteForMe(m); pendingDelete = nil
                    }
                }
                Button("Cancel", role: .cancel) { pendingDelete = nil }
            }
            .confirmationDialog("Report this message?",
                                isPresented: Binding(get: { reportTarget != nil },
                                                     set: { if !$0 { reportTarget = nil } }),
                                titleVisibility: .visible) {
                Button("Report", role: .destructive) {
                    if let m = reportTarget {
                        Task { await ChatService.report(reportedUid: m.authorId, cid: cid,
                                                         messageId: m.id, messageText: m.text, reason: "message") }
                    }
                    reportTarget = nil
                }
                Button("Report and Block", role: .destructive) {
                    if let m = reportTarget {
                        Task {
                            await ChatService.report(reportedUid: m.authorId, cid: cid,
                                                     messageId: m.id, messageText: m.text, reason: "message")
                            await ChatService.setBlocked(cid, true)
                        }
                    }
                    reportTarget = nil
                }
                Button("Cancel", role: .cancel) { reportTarget = nil }
            } message: {
                Text("Our team will review this message within 24 hours. \(title) won't be told.")
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
        LiveWaveform(levels: recorder.levels, color: color)
            .frame(maxWidth: .infinity, maxHeight: 22)
    }
}

// Identifiable wrapper so a decrypted file can drive a .sheet(item:).
struct PreviewFile: Identifiable { let id = UUID(); let url: URL }

// Native document preview (QuickLook) for a received file.
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
