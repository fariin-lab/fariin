import SwiftUI
import PhotosUI
import Photos
import UIKit
import StoryUI

// Telegram/IG segmented story ring: one arc per story (3 stories = 3 arcs with gaps, 1 = full circle).
// Colorful gradient when unviewed, grey when viewed. Reused on story cards AND chat-list avatars.
struct StoryRingView: View {
    let seen: [Bool]                 // per segment, oldest→newest; true = viewed (grey), false = colorful
    var lineWidth: CGFloat = 2.5
    var body: some View {
        let n = max(1, seen.count)
        let gap: CGFloat = n > 1 ? 0.045 : 0          // gap between segments (fraction of the circle)
        let seg: CGFloat = 1.0 / CGFloat(n)
        // Unviewed: green→blue gradient (Telegram/WhatsApp style). Viewed: a real medium grey (the old
        // 0.62 read as white on the dark card).
        let gradient = AnyShapeStyle(LinearGradient(colors: [Color(hex: 0x34C759), Color(hex: 0x0A84FF)],
                                                    startPoint: .topLeading, endPoint: .bottomTrailing))
        let grey = AnyShapeStyle(Color(white: 0.46))
        ZStack {
            ForEach(0..<n, id: \.self) { i in
                let isSeen = i < seen.count ? seen[i] : false
                Circle()
                    .trim(from: CGFloat(i) * seg + gap / 2, to: CGFloat(i + 1) * seg - gap / 2)
                    .stroke(isSeen ? grey : gradient, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            }
        }
        .rotationEffect(.degrees(-90))                // first segment starts at the top
    }
}

// Cached story image: memory + persistent disk (DiskImageCache), so swiping
// back/forward, reopening, and app relaunches load instantly with no re-download.
struct StoryImage: View {
    let url: String
    // fitBlur = show the WHOLE image (aspect-fit) over a blurred fill of itself — the SAME look as the
    // story viewer, so a wide/tall photo isn't cropped/zoomed and keeps its blur bars. Used for the
    // swipe-up morph card + the viewers carousel; the small story-row covers stay plain fill (crop).
    var fitBlur = false
    @State private var image: UIImage?
    @State private var failed = false
    var body: some View {
        Group {
            if let image {
                if fitBlur {
                    ZStack {
                        Image(uiImage: image).resizable().scaledToFill().blur(radius: 26).clipped()
                        Image(uiImage: image).resizable().scaledToFit()
                    }
                    .transition(.opacity)
                } else {
                    Image(uiImage: image).resizable().scaledToFill()
                        .transition(.opacity)
                }
            } else if failed {
                ZStack { Color.black; Image(systemName: "photo").font(.largeTitle).foregroundStyle(.white.opacity(0.5)) }
            } else {
                SkeletonFill()
            }
        }
        .animation(.easeOut(duration: 0.25), value: image != nil)   // fade in when loaded
        .task(id: url) { await load() }
    }
    @MainActor private func load() async {
        failed = false
        if let cached = await DiskImageCache.shared.image(for: url) { image = cached; return }
        guard let u = URL(string: url) else { failed = true; return }
        guard let (data, _) = try? await URLSession.shared.data(from: u), let img = UIImage(data: data) else {
            failed = true; return
        }
        DiskImageCache.shared.store(img, data: data, for: url)
        image = img
    }
}

// Local per-author story prefs.
enum StoryPrefs {
    // In-memory cache so we don't re-parse the UserDefaults string on every call (seenFlags is called
    // per card per render — re-parsing each time made hide/unhide feel laggy).
    // LOCKED: hasUnseen (→ isStorySeen) now also runs inside StoriesRepository.rebuild() on
    // background cooperative threads — three listeners fire together at launch, and concurrent
    // cache-miss writes to this static dictionary corrupted it (SIGSEGV on every cold start, 177).
    private static var cache: [String: Set<String>] = [:]
    private static let lock = NSLock()
    private static func set(_ key: String) -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        if let c = cache[key] { return c }
        let s = Set((UserDefaults.standard.string(forKey: key) ?? "").split(separator: " ").map(String.init))
        cache[key] = s
        return s
    }
    private static func save(_ key: String, _ s: Set<String>) {
        lock.lock(); cache[key] = s; lock.unlock()   // update cache synchronously → instant reads
        UserDefaults.standard.set(s.joined(separator: " "), forKey: key)
    }
    static func isHidden(_ uid: String) -> Bool { set("hiddenStories").contains(uid) }
    static func toggleHidden(_ uid: String) {
        var s = set("hiddenStories"); if s.contains(uid) { s.remove(uid) } else { s.insert(uid) }; save("hiddenStories", s)
    }
    // Explicit set — the "…" → Hide Stories action must always HIDE (toggle would UN-hide when the
    // story was opened from the Archived screen, where the author is already hidden).
    static func setHidden(_ uid: String, _ hidden: Bool) {
        var s = set("hiddenStories"); if hidden { s.insert(uid) } else { s.remove(uid) }; save("hiddenStories", s)
    }
    static func isNotifying(_ uid: String) -> Bool { set("notifyStories").contains(uid) }
    static func toggleNotify(_ uid: String) {
        var s = set("notifyStories"); if s.contains(uid) { s.remove(uid) } else { s.insert(uid) }; save("notifyStories", s)
    }
    // Per-STORY-ITEM seen state (drives the segmented ring: each arc greys as you view that story).
    static func isStorySeen(_ id: String) -> Bool { set("seenStoryItems").contains(id) }
    static func markStorySeen(_ id: String) {
        guard !id.isEmpty else { return }
        var s = set("seenStoryItems"); s.insert(id); save("seenStoryItems", s)
    }
    // My own ❤️ on a story — persists so the heart is still red on reopen (Instagram).
    static func isStoryLiked(_ id: String) -> Bool { set("likedStories").contains(id) }
    static func setStoryLiked(_ id: String, _ liked: Bool) {
        guard !id.isEmpty else { return }
        var s = set("likedStories"); if liked { s.insert(id) } else { s.remove(id) }; save("likedStories", s)
    }
    // seen flags for a bucket's stories (oldest→newest), for StoryRingView. A story is seen if I
    // viewed that exact item on THIS device (local flag) OR it's covered by my synced server
    // watermark (`upTo` = the group's lastViewedAt) — so after a reinstall / on a second device the
    // arcs match the group's own seen/sort state instead of all showing colorful (split brain).
    static func seenFlags(_ stories: [Story], upTo watermark: Date? = nil) -> [Bool] {
        stories.map { isStorySeen($0.id) || $0.createdAt <= (watermark ?? .distantPast) }
    }
}

// Horizontal Stories row for the top of the Chats screen.
struct SeenByTarget: Identifiable { let id: String }

struct StoriesRow: View {
    @State private var repo = StoriesRepository.shared
    @State private var stories = StoriesService.shared   // observe the live upload state
    @State private var seenBy: SeenByTarget?             // "Seen by" sheet target
    var meName: String
    var mePhoto: String?
    var storyNS: Namespace.ID    // zoom transition: card ⇄ full-screen viewer
    var onCompose: () -> Void
    var onOpen: (StoryGroup) -> Void
    var onMessage: (StoryGroup) -> Void = { _ in }
    var onProfile: (StoryGroup) -> Void = { _ in }
    var onOpenAnon: (StoryGroup) -> Void = { _ in }
    var onOpenUploading: () -> Void = {}   // tap the still-uploading card → live upload viewer
    @State private var prefsTick = 0   // re-render after hide/notify toggles
    @State private var hideTarget: StoryGroup?   // "Hide Stories?" confirmation target

    private let storySpacing: CGFloat = 10
    private let storyHPad: CGFloat = 12
    private var cardW: CGFloat {
        (UIScreen.main.bounds.width - storyHPad * 2 - storySpacing * 3) / 4
    }
    private var cardH: CGFloat { cardW * 1.46 }

    // Ordering (WhatsApp): UNVIEWED first, then VIEWED — BOTH sorted by newest post first (never
    // by when I watched). Re-sorts live (no reload) the instant a person's last unseen story is
    // watched (markSeenLocally advances the watermark) and the cards animate.
    private var orderedOthers: [StoryGroup] {
        let _ = prefsTick   // re-evaluate after hide/seen toggles
        func newestFirst(_ a: StoryGroup, _ b: StoryGroup) -> Bool {
            (a.stories.last?.createdAt ?? .distantPast) > (b.stories.last?.createdAt ?? .distantPast)
        }
        let visible = repo.others.filter { !StoryPrefs.isHidden($0.authorUid) }
        let unviewed = visible.filter { $0.hasUnseen }.sorted(by: newestFirst)
        let viewed = visible.filter { !$0.hasUnseen }.sorted(by: newestFirst)
        return unviewed + viewed
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: storySpacing) {
                myCard
                    .id("my-story")   // STABLE identity so its "Add Story/Posted Stories" menu never binds
                                      // to a friend card when the row re-sorts (SwiftUI context-menu bug).
                ForEach(orderedOthers) { g in
                    // Each friend card is its OWN Equatable view so its long-press survives the row's
                    // re-renders (inline ForEach context menus only fired on the first card).
                    StoryFriendCard(cover: g.stories.last?.mediaUrl,
                                    name: g.name.isEmpty ? "User" : g.name,
                                    avatar: g.photoUrl,
                                    seen: StoryPrefs.seenFlags(g.stories, upTo: g.lastViewedAt),
                                    cardW: cardW,
                                    onOpen: { onOpen(g) },
                                    onMessage: { onMessage(g) },
                                    onProfile: { onProfile(g) },
                                    onHide: { hideTarget = g },
                                    onOpenAnon: { onOpenAnon(g) },
                                    storyNS: storyNS,
                                    groupID: g.id)
                        .equatable()
                        .id(g.authorUid)   // explicit stable identity → its menu stays bound to this person
                }
            }
            .padding(.horizontal, storyHPad)
            .padding(.vertical, 10)
            // Smoothly slide cards to their new spots when a story moves unviewed -> viewed-front (no reload).
            .animation(.spring(response: 0.42, dampingFraction: 0.82), value: orderedOthers.map(\.id))
        }
        .alert("Couldn't post story", isPresented: Binding(
            get: { stories.uploadError != nil },
            set: { if !$0 { stories.uploadError = nil } }
        )) { Button("OK", role: .cancel) {} } message: { Text(stories.uploadError ?? "") }
        // Native ALERT, not confirmationDialog: over the stories row the dialog rendered as an
        // anchored popover (arrow pointing at the row); an alert is the standard centered modal.
        .alert("Hide Stories?",
               isPresented: Binding(get: { hideTarget != nil }, set: { if !$0 { hideTarget = nil } }),
               presenting: hideTarget) { g in
            Button("Hide Stories", role: .destructive) { StoryPrefs.setHidden(g.authorUid, true); prefsTick += 1; hideTarget = nil }
            Button("Cancel", role: .cancel) { hideTarget = nil }
        } message: { g in
            Text("New story updates from \(g.name.isEmpty ? "this person" : g.name) won't appear at the top of the stories list anymore.")
        }
        .task { await repo.load() }
    }

    @ViewBuilder private var myCard: some View {
        // ZStack + crossfade so the "Uploading…" placeholder morphs straight into the final card in the
        // same frame (no jump). The reload happens before `uploading` flips, so there's no stale image.
        ZStack {
            if stories.uploading {
                uploadingCard.transition(.opacity)
                    .contentShape(Rectangle())
                    // Tapping the still-uploading card ALWAYS opens the live upload viewer (shows the
                    // story I just posted, with its progress, until it finishes). If I have older
                    // posted stories, that viewer offers a "‹" / swipe-right to step back into them
                    // while the upload keeps running in the background.
                    .onTapGesture { onOpenUploading() }
            } else {
                card(cover: repo.mine?.stories.last?.mediaUrl ?? mePhoto,
                     name: "My Story", avatar: mePhoto,
                     seen: StoryPrefs.seenFlags(repo.mine?.stories ?? [], upTo: repo.mine?.lastViewedAt), onBadge: onCompose) {
                    if let m = repo.mine { onOpen(m) } else { onCompose() }
                }
                // NATIVE context menu (build 181 look): My Story menu, lifting just the rounded card.
                .contextMenu {
                    Button { onCompose() } label: { Label("Add Story", systemImage: "plus") }
                    Button { if let m = repo.mine, !m.stories.isEmpty { onOpen(m) } }
                        label: { Label("Posted Stories", systemImage: "circle.dashed") }
                } preview: {
                    coverImage(repo.mine?.stories.last?.mediaUrl ?? mePhoto, name: "My Story", avatar: mePhoto)
                        .frame(width: cardW, height: cardH)
                        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                }
                .matchedTransitionSource(id: repo.mine?.id ?? "my-story", in: storyNS)   // hero grow source
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: stories.uploading)
    }

    // Shown in the first slot while a story is uploading: local image + spinner ring + "Uploading…".
    private var uploadingCard: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .bottomLeading) {
                Group {
                    if let ui = stories.uploadingImage {
                        Image(uiImage: ui).resizable().scaledToFill()
                    } else {
                        Color(.secondarySystemFill)
                    }
                }
                .frame(width: cardW, height: cardH)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(.black.opacity(0.25)))

                ZStack {
                    AvatarView(name: meName, photoUrl: mePhoto, size: 32)   // my profile avatar in the center
                    Spinner(size: 37, color: .white)                        // ring hugs the avatar like the story rings (37)
                }
                .padding(8)
            }
            Text("Uploading…").font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).frame(width: cardW)
        }
        .frame(width: cardW)
    }

    private func card(cover: String?, name: String, avatar: String?, seen: [Bool],
                      onBadge: (() -> Void)? = nil, tap: @escaping () -> Void) -> some View {
        // Button (not onTapGesture) so the caller's .contextMenu long-press fires reliably.
        Button(action: tap) {
        VStack(spacing: 6) {
            ZStack(alignment: .bottomLeading) {
                coverImage(cover, name: name, avatar: avatar)
                    .frame(width: cardW, height: cardH)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                if let onBadge {
                    // My Story: profile picture + ring (colorful before I view it, grey after) + small + badge.
                    AvatarView(name: name, photoUrl: avatar, size: 32)
                        .overlay { if !seen.isEmpty { StoryRingView(seen: seen).frame(width: 37, height: 37) } }
                        .overlay(alignment: .bottomTrailing) {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 16)).symbolRenderingMode(.palette)
                                .foregroundStyle(.white, Color(.systemGreen))
                                .offset(x: 4, y: 4)
                                // high-priority so tapping + adds a story without triggering the card's open tap
                                .highPriorityGesture(TapGesture().onEnded { onBadge() })
                        }
                        .animation(.easeInOut(duration: 0.3), value: seen)
                        .shadow(color: .black.opacity(0.28), radius: 2, y: 1)
                        .padding(8)
                } else {
                    AvatarView(name: name, photoUrl: avatar, size: 32)
                        .overlay { if !seen.isEmpty { StoryRingView(seen: seen).frame(width: 37, height: 37) } }
                        .animation(.easeInOut(duration: 0.3), value: seen)
                        .shadow(color: .black.opacity(0.28), radius: 2, y: 1)
                        .padding(8)
                }
            }
            Text(name).font(.system(size: 12)).lineLimit(1).frame(width: cardW)
        }
        .frame(width: cardW)
        .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private func coverImage(_ cover: String?, name: String, avatar: String?) -> some View {
        if let cover, !cover.isEmpty {
            StoryImage(url: cover)
        } else {
            ZStack {
                Color.secondary.opacity(0.2)
                AvatarView(name: name, photoUrl: avatar, size: cardW * 0.62)
            }
        }
    }

    func reload() { Task { await repo.load(force: true) } }
}

// One friend's story card in the row. Its own Equatable view so the long-press context menu stays
// armed across the row's re-renders (the inline-ForEach version only worked on the first card).
private struct StoryFriendCard: View, Equatable {
    let cover: String?
    let name: String
    let avatar: String?
    let seen: [Bool]
    let cardW: CGFloat
    let onOpen: () -> Void
    let onMessage: () -> Void
    let onProfile: () -> Void
    let onHide: () -> Void
    var onOpenAnon: () -> Void = {}   // "View Anonymously" — opens the story without a seen receipt
    let storyNS: Namespace.ID    // hero zoom: card ⇄ viewer
    let groupID: String          // matches the viewer's zoom sourceID

    static func == (l: StoryFriendCard, r: StoryFriendCard) -> Bool {
        l.cover == r.cover && l.name == r.name && l.avatar == r.avatar
            && l.seen == r.seen && l.cardW == r.cardW && l.groupID == r.groupID
    }

    private var cardH: CGFloat { cardW * 1.46 }

    var body: some View {
        Button(action: onOpen) {
            VStack(spacing: 6) {
                ZStack(alignment: .bottomLeading) {
                    coverView
                        .frame(width: cardW, height: cardH)
                        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    AvatarView(name: name, photoUrl: avatar, size: 32)
                        .overlay { if !seen.isEmpty { StoryRingView(seen: seen).frame(width: 37, height: 37) } }
                        .shadow(color: .black.opacity(0.28), radius: 2, y: 1)
                        .padding(8)
                }
                Text(name).font(.system(size: 12)).lineLimit(1).frame(width: cardW)
            }
            .frame(width: cardW)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // NATIVE iOS context menu (build 181 look). Each card owns its menu built from its OWN
        // props, and the explicit `preview:` lifts just the rounded photo. The row is OUTSIDE the
        // chat List now (which was what collapsed per-card menus into one), so per-card native menus
        // work; the stable `.id(authorUid)` at the call site keeps each menu bound to its person.
        .contextMenu {
            Button { onOpenAnon() } label: { Label("View Anonymously", systemImage: "eye.slash") }
            Button { onMessage() } label: { Label("Send Message", systemImage: "message") }
            Button { onProfile() } label: { Label("Open Profile", systemImage: "person.crop.circle") }
            Button(role: .destructive) { onHide() } label: { Label("Hide Stories", systemImage: "archivebox") }
        } preview: {
            coverView
                .frame(width: cardW, height: cardH)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
        .matchedTransitionSource(id: groupID, in: storyNS)   // hero grow source
    }

    @ViewBuilder private var coverView: some View {
        if let cover, !cover.isEmpty {
            StoryImage(url: cover)
        } else {
            ZStack { Color.secondary.opacity(0.2); AvatarView(name: name, photoUrl: avatar, size: cardW * 0.62) }
        }
    }
}


// MARK: - Story Viewer (Instagram-style)

// Full-screen story viewer: thin progress bars at top, Instagram-style header and
// bottom reply bar, tap-right = next / tap-left = back, hold = pause, swipe-down = close.
// Full-screen story viewer — now powered by the StoryUI library (MIT) for its native swipe,
// progress bars, tap-to-advance, hold-to-pause and reply/emoji bar. We map our StoryGroups into
// StoryUI's models and route replies/emoji/like back to the author as a DM (our existing behavior).
// NOTE: report-story / delete-my-story from inside the viewer are not exposed by StoryUI (do those
// from the story row's long-press instead). `StoryUI.Story` is qualified to avoid colliding with
// our own `Story` type.
struct StoryViewer: View {
    let groups: [StoryGroup]
    var startIndex: Int = 0
    var anonymous: Bool
    var onClose: () -> Void
    var onProfile: (StoryGroup) -> Void = { _ in }   // tap the story header → that user's profile
    var onDeletedRemaining: (StoryGroup) -> Void = { _ in }   // deleted an item but more of mine remain → re-feed
    @State private var isPresented = true
    @State private var sentToast = false   // "Sent" confirmation after a reply (WhatsApp-style)
    // Owner controls (my own story): Views/reactions/delete bar instead of the reply bar.
    @State private var currentBucketUid = ""
    @State private var currentStoryId = ""
    @State private var barViewers: [StoryViewerInfo] = []
    @State private var showViewers = false
    @State private var viewersProgress: CGFloat = 0   // 0 sheet closed … 1 open; drives BOTH layers
    @State private var openDragging = false           // kept: read by the storyLayer opacity/hit-test
    @State private var confirmDelete = false
    @State private var shareImg: StoryImagePayload?     // … → Share (system sheet)
    @State private var forwardImg: StoryImagePayload?   // … → Forward (chat picker)
    @State private var profileSheet: StoryGroup?        // tap the header → profile sheet OVER the story (paused)
    @State private var toastText = "Sent"               // reused for "Sent" (reply) and "Saved"
    @State private var dragDown: CGFloat = 0            // swipe-down amount → fade my overlays with the card
    private var me: String { AuthService.shared.uid ?? "" }
    private var currentIsMine: Bool { groups.first { $0.authorUid == currentBucketUid }?.isMine ?? false }
    private var myStories: [Story] { groups.first { $0.isMine }?.stories ?? [] }
    // My-story viewers are always fed my bucket ALONE, so this is stable for the whole session
    // (no mid-swipe layout jumps) — it drives the card+footer layout below.
    private var mineOnly: Bool { groups.count == 1 && (groups.first?.isMine ?? false) }
    @State private var sheetStoryId = ""   // which of MY stories the carousel + viewers list target
    @State private var uploadSvc = StoriesService.shared   // observed → the "Uploading…" bar tracks the upload
    // The current item is the still-uploading synthetic placeholder → show the "Uploading…" bar (both
    // buttons cancel the upload), suppress the Views footer + delete (there's no real story doc yet).
    private var isUploadingItem: Bool { currentStoryId == StoriesService.uploadingStoryId && uploadSvc.uploading }
    // Home-indicator inset (the story ignoresSafeArea, so overlays must add it back themselves).
    private var bottomInset: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow?.safeAreaInsets.bottom }.max() ?? 0
    }
    private var currentStory: Story? { groups.flatMap(\.stories).first { $0.id == currentStoryId } }
    // Which of my stories the viewers sheet should target. Usually the item on screen; but for the
    // first ~50ms after opening, `currentStoryId` is still "" (the library's first timer tick hasn't
    // fired) — fall back to the item the viewer OPENED on (first unseen, else the first), matching
    // firstUnseenIndex, NOT the newest, so a fast swipe-up doesn't grab the wrong story.
    private var targetStoryId: String {
        if !currentStoryId.isEmpty { return currentStoryId }
        return myStories.first(where: { !StoryPrefs.isStorySeen($0.id) })?.id ?? myStories.first?.id ?? ""
    }
    // Any sheet shown over the story → pause it (share, forward, "…" menu, delete confirm). The
    // VIEWERS sheet is handled separately via `viewersProgress` (below) so the story is frozen the
    // instant the sheet starts to rise, even mid-drag — otherwise it kept playing and, on reaching
    // the last item, auto-dismissed the whole viewer (taking the sheet with it).
    private var sheetUp: Bool { shareImg != nil || forwardImg != nil || confirmDelete || profileSheet != nil }

    init(group: StoryGroup, anonymous: Bool = false, onClose: @escaping () -> Void,
         onProfile: @escaping (StoryGroup) -> Void = { _ in },
         onDeletedRemaining: @escaping (StoryGroup) -> Void = { _ in }) {
        self.init(groups: [group], startIndex: 0, anonymous: anonymous, onClose: onClose, onProfile: onProfile,
                  onDeletedRemaining: onDeletedRemaining)
    }
    init(groups: [StoryGroup], startIndex: Int = 0, anonymous: Bool = false, onClose: @escaping () -> Void,
         onProfile: @escaping (StoryGroup) -> Void = { _ in },
         onDeletedRemaining: @escaping (StoryGroup) -> Void = { _ in }) {
        self.groups = groups
        self.startIndex = startIndex
        self.anonymous = anonymous
        self.onClose = onClose
        self.onProfile = onProfile
        self.onDeletedRemaining = onDeletedRemaining
    }

    private var models: [StoryUIModel] {
        groups.map { g in
            StoryUIModel(
                id: g.authorUid,
                user: StoryUIUser(id: g.authorUid, name: g.name, image: g.photoUrl ?? ""),
                isMine: g.isMine,   // drives the "…" menu: my story shows Delete, others show Hide Stories
                stories: g.stories.map { s in
                    StoryUI.Story(
                        id: s.id,
                        mediaURL: s.mediaUrl,
                        date: timeAgo(s.createdAt),
                        isLiked: StoryPrefs.isStoryLiked(s.id),   // heart stays red on reopen
                        // Where the viewer opens (firstUnseenIndex = first item with isSeen == false,
                        //  else 0):
                        //  • MY OWN story: purely the real per-item seen flag (own items ARE marked seen
                        //    as I watch them — onItemSeen is non-anonymous for my own). So: any unread
                        //    item -> opens on the FIRST unread (e.g. a just-posted D); everything read ->
                        //    firstUnseenIndex falls back to 0 -> opens from A again (NOT the last one I
                        //    watched). No watermark here so it tracks exactly what I actually viewed.
                        //  • A FRIEND's story: first genuinely unseen item, honoring the synced watermark
                        //    too (so after a reinstall it doesn't replay from item 0 — split brain).
                        isSeen: g.isMine
                            ? StoryPrefs.isStorySeen(s.id)
                            : (StoryPrefs.isStorySeen(s.id) || s.createdAt <= (g.lastViewedAt ?? .distantPast)),
                        // My own story in the MINE-ONLY viewer: WE draw the caption pinned above the
                        // footer (below), so suppress the library's here. In a mixed feed (no footer,
                        // no custom caption) keep the library's caption or it would show nowhere.
                        caption: (g.isMine && mineOnly) ? "" : s.caption,
                        config: StoryConfiguration(
                            // My own story shows NO reply bar (owner bar is overlaid instead).
                            storyType: g.isMine
                                ? .plain()
                                : (s.allowsReplies
                                    ? .message(config: StoryInteractionConfig(showLikeButton: true),
                                               emojis: [["❤️", "😂", "😮"], ["😢", "👏", "🔥"]],
                                               placeholder: "Send message…")
                                    : .plain()),
                            mediaType: .image
                        )
                    )
                }
            )
        }
    }

    var body: some View {
        ZStack {
            // Solid black canvas behind the story while the viewers sheet is up (so the see-through
            // cover never shows the light chat list through the shrinking card = the "white" bug).
            // Fully OFF only at rest, so the swipe-down dismiss keeps its see-through look.
            Color.black.ignoresSafeArea()
                .opacity(showViewers ? 1 : 0)
            storyLayer
            // The viewers sheet is a SIBLING layer, NOT a system .sheet: a system sheet lives in
            // its own presentation layer and cannot drive a continuous transform on the story
            // behind it — that limitation is what pushed the old design to render story cards
            // INSIDE the sheet. Both layers share `viewersProgress`, so the drag and the release
            // spring stay perfectly in sync.
            if showViewers {
                viewersBackdrop   // flat 2D morph card during the drag → my-stories carousel when open
                StoryViewersBottomSheet(activeStoryId: sheetStoryId,
                                        progress: $viewersProgress,
                                        onClose: closeViewers)
            }
        }
        .sheet(item: $shareImg) { p in ActivityView(items: [p.image]) }
        .sheet(item: $forwardImg) { p in StoryForwardSheet(image: p.image, onSent: { flashSentToast() }) }
        .sheet(item: $profileSheet) { g in
            NavigationStack {
                ContactInfoView(cid: [me, g.authorUid].sorted().joined(separator: "_"),
                                name: g.name, photoUrl: g.photoUrl, isSelf: g.authorUid == me)
            }
            .presentationDetents([.medium, .large])   // small profile sheet over the paused story
            .presentationDragIndicator(.visible)
        }
        // REAL native delete confirmation (user request: no custom sheet). An alert, not a
        // confirmationDialog: over these full-screen covers dialogs render as centered popovers
        // that HIDE role-cancel buttons (the Discard bug). Alerts are liquid-glass native and
        // always show both buttons.
        .alert("Delete this story?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                // Seamless delete: the viewer slides to the adjacent item itself; we just remove from the db.
                NotificationCenter.default.post(name: .init("deleteCurrentStoryItem"), object: nil)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It will also be deleted for everyone who received it.")
        }
        // The viewer dropped the item in-place + advanced; here we delete it from the database. If that was
        // my last story, close the viewer (Case 3). Otherwise leave the (captured) viewer untouched — no re-feed.
        .onReceive(NotificationCenter.default.publisher(for: .init("storyItemDeleted"))) { note in
            guard let id = note.object as? String, !id.isEmpty else { return }
            Task {
                await StoriesService.shared.deleteStory(id)
                await StoriesRepository.shared.load(force: true)
                if StoriesRepository.shared.mine?.stories.isEmpty ?? true { onClose() }
            }
        }
        // "…" dropdown menu actions (posted from the library header Menu) — run on LIVE state here.
        .onReceive(NotificationCenter.default.publisher(for: .init("storyActionSave"))) { _ in
            saveCurrentImage(currentStory?.mediaUrl)
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("storyActionForward"))) { _ in
            let u = currentStory?.mediaUrl
            Task { if let img = await loadCurrentImage(u) { forwardImg = StoryImagePayload(image: img) } }
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("storyActionShare"))) { _ in
            let u = currentStory?.mediaUrl
            Task { if let img = await loadCurrentImage(u) { shareImg = StoryImagePayload(image: img) } }
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("storyActionHide"))) { _ in
            if !currentIsMine { StoryPrefs.setHidden(currentBucketUid, true); isPresented = false }
        }
        // "…" → Delete Story (only shown on my own story) → same confirm + seamless delete as the trash button.
        .onReceive(NotificationCenter.default.publisher(for: .init("storyActionDelete"))) { _ in
            if currentIsMine && !isUploadingItem { confirmDelete = true }   // no delete on the uploading item
        }
        .overlay(alignment: .bottom) {
            if sentToast {
                Text(toastText)
                    .font(.subheadline.weight(.medium)).foregroundStyle(.white)
                    .padding(.horizontal, 18).padding(.vertical, 10)
                    .background(.black.opacity(0.75), in: Capsule())
                    .padding(.bottom, 120)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .onChange(of: isPresented) { _, shown in if !shown { onClose() } }
        // Safety net: never leave a story paused after the viewer goes away (the swipe-down dismiss posts
        // pauseStory and does not resume on commit; a sheet up at teardown can also skip the resume).
        .onDisappear { NotificationCenter.default.post(name: .init("resumeStory"), object: nil) }
        // Freeze the running story + progress while any sheet is shown over it; resume on dismiss.
        .onChange(of: sheetUp) { _, up in
            NotificationCenter.default.post(name: up ? .init("pauseStory") : .init("resumeStory"), object: nil)
        }
        // Viewers sheet: pause the moment it starts opening (progress > 0), resume only once fully
        // closed. This keeps the story frozen the entire time the sheet is up (fixes the auto-close).
        .onChange(of: viewersProgress > 0.01) { _, open in
            NotificationCenter.default.post(name: open ? .init("pauseStory") : .init("resumeStory"), object: nil)
        }
        // A swipe-DOWN dismiss drag (friend OR own story) must freeze the story so the progress bar can't
        // keep advancing under the finger. The library pauses on the pan's .began, but on a multi-item
        // feed the cube pager's require(toFail:) can delay .began — so reassert the pause from the host on
        // the first reported drag. Resume (spring-back) / stop (commit) stays the library's job on release.
        .onChange(of: dragDown > 0.5) { _, dragging in
            if dragging { NotificationCenter.default.post(name: .init("pauseStory"), object: nil) }
        }
        // Carousel centred a different one of my stories while the sheet is up → advance the frozen
        // story underneath to match, so collapsing lands on that story with no photo-swap flash.
        .onChange(of: sheetStoryId) { _, id in
            guard showViewers, currentIsMine, !id.isEmpty else { return }
            NotificationCenter.default.post(name: .init("jumpToStoryItem"), object: id)
        }
        // The COVER'S OWN BACKING (not just an inner canvas) must be opaque black while the viewers
        // sheet is up — otherwise the .zoom transition composites the clear backing over the inner
        // black canvas and the light Chats list bleeds through as the "white" bug. Clear only at rest,
        // so the swipe-DOWN dismiss still reveals the Chats list sliding behind the story.
        .presentationBackground { Color.black.opacity(showViewers ? 1 : 0) }
    }

    // The Active Story layer: media + header + progress bars + owner bar/footer.
    // My own story renders as a CARD: bottom corners clipped (24 continuous) with a solid black
    // footer bar (Views + trash) BELOW it — the old gradient bar bled over the story to the
    // screen edge. Friends' stories stay full-bleed with the library's reply bar.
    private var storyLayer: some View {
        let p = viewersProgress
        return VStack(spacing: 0) {
            if mineOnly {
                // My own story: a CARD (rounded bottom corners) + solid black footer below. The clip
                // is ONLY applied here — clipping a FRIEND's full-bleed story broke the library's
                // swipe-down-to-dismiss (the pan translates the card, but the clip pinned it to its
                // frame so it couldn't visibly move → "scroll down to close doesn't work").
                storyContent
                    .overlay(alignment: .bottom) {
                        if let c = currentStory?.caption, !c.isEmpty {
                            Text(c)
                                .font(.body).foregroundStyle(.white)
                                .lineLimit(4)   // don't let a long caption climb over the whole photo (IG/WA cap)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 16).padding(.top, 26).padding(.bottom, 14)
                                .background(LinearGradient(colors: [.clear, .black.opacity(0.45)],
                                                           startPoint: .top, endPoint: .bottom))
                                .opacity(dragDown > 6 ? 0 : 1)
                                .animation(.easeOut(duration: 0.15), value: dragDown > 6)
                                .allowsHitTesting(false)
                        }
                    }
                    // NO app-level CLIP (the clip pinned the card and broke the native dismiss) — the
                    // card's corners are rounded in UIKit inside the library now. But KEEP a solid black
                    // background: the cover is see-through (.clear) for the swipe-down, so without this
                    // the light chat list shows through as a WHITE story. A background (unlike a clip)
                    // doesn't pin the card, so the library dismiss stays smooth.
                    .background(Color.black)
                ownerFooter
                    .opacity(dragDown > 6 ? 0 : 1).animation(.easeOut(duration: 0.15), value: dragDown > 6)
            } else {
                // Friend's story: full-bleed, NO clip → the library's swipe-down dismiss works.
                storyContent
            }
        }
        // NO app-level drag gesture on the story anymore. BOTH directions are the library's native
        // UIKit pans: swipe-DOWN → dismiss (smooth, same as friends), swipe-UP → onSwipeUp → openViewers.
        // An app gesture here fought the library's swipe-down pan and broke the dismiss.
        // NEVER transformed (the library has an internal 3D cube for user-to-user swipes; scaling
        // it warped the card). While the sheet is up, the flat 2D morph card + carousel in
        // `viewersBackdrop` replace it visually. Keep a hair of opacity + hit-testing DURING an open
        // drag so the gesture keeps tracking the finger even after the story has visually faded.
        // Crossfade timing: the story (WITH its chrome) stays fully visible while the opaque morph
        // card fades in over it (0→0.08 dissolves the chrome), then is gone by the time the card
        // starts to shrink — so the photo stays bright throughout and only the chrome dissolves.
        // Reversed on close (the chrome fades back in as the morph card grows away).
        .opacity(max(openDragging ? 0.02 : 0, 1 - Double(min(p / 0.08, 1))))
        // NO app-level swipe-down transform anymore. The card is dismissed by the library's native UIKit
        // pan (moves the view directly = friend-smooth), so the app never offsets/scales the pager.
        .allowsHitTesting(viewersProgress == 0 || openDragging)
        // NO app-level swipe-UP gesture here. It's a SwiftUI DragGesture and, once past its minimumDistance,
        // it claims EVERY drag (up AND down) — even though it ignored downward ones, it starved the library's
        // native swipe-DOWN dismiss pan (the "close became hard to trigger" regression). Swipe-up is now the
        // library's own direction-locked UP pan again (swipeUpEnabled: true), which coexists with the DOWN
        // dismiss pan via require(toFail:). Both directions are library UIKit pans → no gesture fight.
        .ignoresSafeArea()
    }

    private var storyContent: some View {
        StoryView(
            stories: models,
            selectedIndex: startIndex,
            isPresented: $isPresented,
            userClosure: { story, message, emoji, isLiked in
                handle(storyId: story.id, message: message, emoji: emoji, isLiked: isLiked)
            },
            onProfile: { user in
                // Open the profile OVER the story (paused) — do NOT close the viewer.
                if let g = groups.first(where: { $0.authorUid == user.id }) { profileSheet = g }
            },
            // Landing on a person no longer greys their whole ring — seen state advances per ITEM
            // below (WhatsApp rule: the ring stays colored until every story is watched).
            onUserChanged: { uid in currentBucketUid = uid; loadBarViewers() },
            // Anonymous viewing leaves NO trace (Telegram-incognito): no local flags either.
            onItemSeen: { id in
                currentStoryId = id
                // The synthetic still-uploading item has no real doc — don't persist it as "seen"
                // (junk entry) or fetch its (non-existent) viewers.
                guard id != StoriesService.uploadingStoryId else { return }
                if !anonymous { StoryPrefs.markStorySeen(id) }
                markSeenItem(id); loadBarViewers()
            },
            onDrag: { d in dragDown = d },   // fade my overlays out as the card is pulled down
            showMore: true, // "…" is a native dropdown menu in the header; its buttons post notifications
            onSwipeUp: { },   // superseded by the continuous callbacks below
            // Real-time swipe-UP: the library's direction-locked up pan reports the drag live, so the
            // sheet follows the finger 1:1 (native feel) and snaps on release — WITHOUT an app gesture
            // that would fight the library's down dismiss pan. Swipe-DOWN dismiss is the library pan too.
            onSwipeUpChanged: { up in
                // `mineOnly` (groups-based) is reliable from the first frame; `currentIsMine` depends on
                // currentBucketUid, which is only set AFTER the library's onUserChanged fires — so on a
                // fresh open it can still be empty and silently block the whole swipe-up. Accept either.
                guard currentIsMine || mineOnly else { return }
                let sheetH = UIScreen.main.bounds.height * StoryViewersBottomSheet.heightFraction
                if !showViewers {
                    sheetStoryId = targetStoryId; showViewers = true
                    // Freeze the story the INSTANT the sheet starts to open — don't wait for the
                    // viewersProgress>0.01 onChange — so it can never run to the end and auto-close the sheet.
                    NotificationCenter.default.post(name: .init("pauseStory"), object: nil)
                }
                openDragging = true   // keep the storyLayer visible/hit-testable through the drag
                viewersProgress = max(0, min(1, up / sheetH))
            },
            onSwipeUpEnded: { _, velocity in
                guard currentIsMine || mineOnly else { openDragging = false; return }
                openDragging = false
                let sheetH = UIScreen.main.bounds.height * StoryViewersBottomSheet.heightFraction
                let projected = viewersProgress + (velocity / sheetH) * 0.25   // fling contribution
                if projected > 0.5 || velocity > 600 {
                    withAnimation(.interactiveSpring(response: 0.34, dampingFraction: 0.84)) { viewersProgress = 1 }
                } else {
                    closeViewers()
                }
            },
            dismissEnabled: true,
            swipeUpEnabled: true   // library's own UP pan drives the callbacks above; coexists with the DOWN dismiss pan (require(toFail:)), so the close is never starved
        )
        // Exotic safety net: my story inside a MIXED feed (not the normal flow) still gets the
        // old gradient overlay bar, since the footer layout is only applied to mine-only feeds.
        .overlay(alignment: .bottom) {
            if currentIsMine && !mineOnly {
                ownerBar
                    .opacity(dragDown > 6 ? 0 : 1).animation(.easeOut(duration: 0.15), value: dragDown > 6)
                    .contentShape(Rectangle())
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 12).onEnded { v in
                            if v.translation.height < -20 { openViewers() }
                        }
                    )
            }
        }
    }

    private var topInset: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow?.safeAreaInsets.top }.max() ?? 0
    }

    // The layer behind the viewers sheet. Strictly 2D (no rotations anywhere):
    // - while DRAGGING (0 < p < 1): ONE flat card of the current photo interpolates
    //   full-screen ⇄ the carousel's centre slot (uniform scale + radius + translate).
    // - once OPEN (p ≈ 1): crossfades into the swipeable carousel of ALL my stories.
    @ViewBuilder private var viewersBackdrop: some View {
        let p = viewersProgress
        let scr = UIScreen.main.bounds
        let sheetH = scr.height * StoryViewersBottomSheet.heightFraction
        let avail = scr.height - sheetH - topInset          // free area above the open sheet
        // Card block = the centred card + the big count row (~40) below it, centred vertically in
        // the free space with the status bar cleared. Smaller than before (was avail*0.72, which
        // made the cards touch the top and the side cards overflow the screen edge). The narrower
        // slot also makes the neighbours sit clearly off-centre so their scale-down actually reads.
        let countArea: CGFloat = 40
        let slotH = (avail - countArea) * 0.94             // fill most of the free area (cards were too small)
        let slotW = slotH * 0.62                           // a touch wider; side cards still peek + shrink
        let blockTop = topInset + (avail - countArea - slotH) / 2
        // SMOOTH, NO-JUMP handoff (Telegram), staged so opening morphs "story → only image" and
        // closing morphs "only image → story", as one continuous motion:
        //  • morphVis: the clean morph card fades IN OPAQUE over 0→0.05 (over the still-full story, so
        //    the progress bars / header / footer DISSOLVE while the photo stays bright), holds, then
        //    fades out 0.9→1.0 into the live carousel centre card.
        //  • sizeP: the card scales down starting the instant the chrome has gone (0.08), tracking the
        //    finger continuously all the way to the slot at 0.9 — no dead "hold" before it responds.
        //  • carIn: neighbours + counts fade in gradually 0.5→0.9 (behind the opaque morph centre).
        let sizeP = max(0, min(1, (p - 0.08) / (0.9 - 0.08)))
        // The live carousel only appears in the last sliver near rest (0.9→1). Below that, the OPAQUE
        // morph card fully covers it. This makes CLOSING mirror OPENING: on open the morph card already
        // hid the carousel during the size-morph (smooth); on close the carousel used to stay exposed and
        // JITTER behind a half-faded morph card (the "shaking"). Now the morph card covers it the whole
        // drag in BOTH directions, so the live (re-rendering) carousel is never visible mid-drag.
        let carIn = max(0, min(1, (p - 0.9) / 0.1))
        let morphVis = min(p / 0.05, 1) * (1 - max(0, min(1, (p - 0.95) / 0.05)))
        // Feed the carousel from the LIVE repo (not the viewer's immutable snapshot), so a story
        // deleted while viewing doesn't linger as a ghost card. Fall back to the snapshot.
        let liveMyStories = StoriesRepository.shared.mine?.stories ?? myStories
        // SINGLE SOURCE OF TRUTH: the background card always shows the CURRENT story (currentStoryId),
        // never the carousel's transient centre id — so it can NEVER flash to the wrong story while the
        // sheet is opening. Scrolling the carousel drives currentStoryId (via jumpToStoryItem), so the
        // background still follows the selection, and closing collapses onto the very same story.
        let morphURL = (currentStory ?? liveMyStories.first { $0.id == sheetStoryId }).map { $0.mediaUrl }
        ZStack(alignment: .top) {
            MyStoriesCarousel(stories: liveMyStories, activeId: $sheetStoryId,
                              slotW: slotW, slotH: slotH,
                              onActiveTap: { closeViewers() })
                .padding(.top, blockTop)
                .opacity(Double(carIn))
                .allowsHitTesting(carIn > 0.5)
            if morphVis > 0.001, let url = morphURL {
                // Start height matches the story CARD (which ends above the black owner footer),
                // so the morph begins exactly where the card visually is.
                let startH = scr.height - (mineOnly ? Self.ownerFooterHeight + max(10, bottomInset) : 0)
                StoryImage(url: url, fitBlur: true)   // whole image + blur (no zoom/crop), matching the story
                    .frame(width: lerp(scr.width, slotW, sizeP), height: lerp(startH, slotH, sizeP))
                    // Rounded the WHOLE time (was 24*sizeP → square at the start of the open). Constant 24
                    // matches the story card's corners, so the image is never square mid-transition.
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .padding(.top, blockTop * sizeP)
                    .frame(maxWidth: .infinity)
                    .opacity(Double(morphVis))
                    .allowsHitTesting(false)   // mid-drag frames take no touches
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .contentShape(Rectangle())
        .onTapGesture { closeViewers() }   // tap the dark area around the cards → back to full screen
        // Dragging DOWN on the carousel/story area COLLAPSES the sheet (the active story grows back to
        // full screen) — it must NOT dismiss the whole viewer to the chat list. Horizontal drags belong
        // to the carousel (guarded out here), so this coexists with the cover-flow swipe.
        .simultaneousGesture(
            DragGesture(minimumDistance: 12)
                .onChanged { v in
                    guard abs(v.translation.height) > abs(v.translation.width), v.translation.height > 0 else { return }
                    let h = UIScreen.main.bounds.height * StoryViewersBottomSheet.heightFraction
                    viewersProgress = max(0, min(1, 1 - v.translation.height / h))
                }
                .onEnded { v in
                    let h = UIScreen.main.bounds.height * StoryViewersBottomSheet.heightFraction
                    let projected = viewersProgress - v.predictedEndTranslation.height / h
                    if projected < 0.6 { closeViewers() }   // collapse → story reopens full screen
                    else { withAnimation(.interactiveSpring(response: 0.34, dampingFraction: 0.84)) { viewersProgress = 1 } }
                }
        )
        .ignoresSafeArea()
    }
    private func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }

    private func openViewers() {
        // Re-open allowed even while the previous close is still unmounting: setting progress back
        // to 1 mid-close both cancels the unmount (guard below) and re-raises the sheet — no more
        // "swipe up does nothing for 0.42s after closing".
        guard currentIsMine else { return }
        NotificationCenter.default.post(name: .init("pauseStory"), object: nil)   // freeze the story immediately
        if !showViewers {
            sheetStoryId = targetStoryId
            showViewers = true   // mount at progress 0 (offscreen) …
        }
        DispatchQueue.main.async {   // … then raise it on the next tick so the insertion animates
            withAnimation(.interactiveSpring(response: 0.4, dampingFraction: 0.84, blendDuration: 0.2)) {
                viewersProgress = 1
            }
        }
    }
    private func closeViewers() {
        withAnimation(.interactiveSpring(response: 0.36, dampingFraction: 0.86, blendDuration: 0.2)) {
            viewersProgress = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.42) {
            if viewersProgress == 0 { showViewers = false }   // a re-open set it back to 1 → stay mounted
        }
    }

    private func flashSentToast(_ text: String = "Sent") {
        toastText = text
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { sentToast = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation(.easeOut(duration: 0.25)) { sentToast = false }
        }
    }


    private func loadCurrentImage(_ captured: String? = nil) async -> UIImage? {
        guard let url = captured ?? currentStory?.mediaUrl, !url.isEmpty else { return nil }
        if let m = DiskImageCache.shared.memoryImage(url) { return m }
        return await DiskImageCache.shared.image(for: url)
    }

    private func saveCurrentImage(_ captured: String? = nil) {
        Task {
            guard let img = await loadCurrentImage(captured) else { return }
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else { return }
            try? await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAsset(from: img)
            }
            await MainActor.run {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                flashSentToast("Saved")
            }
        }
    }

    // Reply text / tapped emoji / like → DM the story's author (mirrors the old sendToAuthor).
    private func handle(storyId: String, message: String?, emoji: String?, isLiked: Bool) {
        let typed = (message?.trimmingCharacters(in: .whitespaces)).flatMap { $0.isEmpty ? nil : $0 }
        guard let s = groups.flatMap(\.stories).first(where: { $0.id == storyId }),
              let me = AuthService.shared.uid, me != s.authorUid else { return }

        // Pure like-button toggle (no text, no picker emoji): remember it locally so the heart
        // is still red when the story is reopened (Instagram). Un-like removes my reaction from
        // the author's "Seen by" and sends nothing.
        if typed == nil && emoji == nil {
            StoryPrefs.setStoryLiked(storyId, isLiked)
            if !isLiked {
                Task { await StoriesService.shared.clearStoryReaction(s) }
                return
            }
        }

        let text = typed ?? emoji ?? (isLiked ? "❤️" : "")
        guard !text.isEmpty else { return }
        let cid = [me, s.authorUid].sorted().joined(separator: "_")
        // Attach the status reference so the reply shows as a "Status" quote (thumbnail) in chat.
        let ref = ReplyRef(id: s.id, authorId: s.authorUid, text: "", isStatus: true, storyThumbUrl: s.mediaUrl)
        let isReaction = typed == nil && (emoji != nil || isLiked)
        Task {
            try? await ChatService.sendText(cid: cid, text: text, replyTo: ref)
            if isReaction { await StoriesService.shared.setStoryReaction(s, emoji: text) }   // shows in "Seen by"
        }
        flashSentToast()   // optimistic "Sent" confirmation (WhatsApp-style)
    }

    // Receipt ONLY the photo actually shown (drives accurate view counts + "Seen by"), and
    // advance the local watermark so the ring/row update instantly (H8 race fix).
    private func markSeenItem(_ storyId: String) {
        guard !anonymous, let s = groups.flatMap(\.stories).first(where: { $0.id == storyId }) else { return }
        StoriesRepository.shared.markSeenLocally(s.authorUid, upTo: s.createdAt)
        Task { await StoriesService.shared.markViewed(s) }
    }

    private func timeAgo(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .abbreviated
        return f.localizedString(for: d, relativeTo: Date())
    }

    // Telegram owner bar: overlapping viewer avatars + "N Views" + ❤️ reactions (tap → sheet) + delete.
    // Views/reactions/delete controls, shared by the gradient overlay bar and the solid footer.
    private var ownerControls: some View {
        let reactions = barViewers.filter { !($0.reaction ?? "").isEmpty }.count
        return HStack(spacing: 12) {
            Button { openViewers() } label: {
                HStack(spacing: 8) {
                    if !barViewers.isEmpty {
                        HStack(spacing: -8) {
                            ForEach(barViewers.prefix(3)) { v in
                                AvatarView(name: v.name, photoUrl: v.photoUrl, size: 26)
                                    .overlay(Circle().stroke(.black, lineWidth: 1.5))
                            }
                        }
                    } else {
                        Image(systemName: "eye").font(.subheadline).foregroundStyle(.white)
                    }
                    Text("\(barViewers.count) View\(barViewers.count == 1 ? "" : "s")")
                        .font(.subheadline.weight(.medium)).foregroundStyle(.white)
                    if reactions > 0 {
                        Image(systemName: "heart.fill").font(.subheadline).foregroundStyle(.red)
                        Text("\(reactions)").font(.subheadline).foregroundStyle(.white)
                    }
                }
            }
            .buttonStyle(.plain)
            Spacer()
            Button { confirmDelete = true } label: {
                Image(systemName: "trash").font(.title3).foregroundStyle(.white)
            }
            .buttonStyle(.plain)
        }
    }

    // Shown in place of the Views/trash controls while THIS item is the uploading placeholder.
    // Per the user's choice, BOTH the X and the trash cancel the in-progress upload and close.
    private var uploadingControls: some View {
        HStack(spacing: 14) {
            Button { uploadSvc.cancelUpload(); onClose() } label: {
                Image(systemName: "xmark").font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
            }.buttonStyle(.plain)
            Spinner(size: 20, color: .white)
            Text("Uploading…").font(.subheadline).foregroundStyle(.white)
            Spacer()
            Button { uploadSvc.cancelUpload(); onClose() } label: {
                Image(systemName: "trash").font(.title3).foregroundStyle(.white)
            }.buttonStyle(.plain)
        }
    }

    private var ownerBar: some View {
        ownerControls
        // Smooth, gradual shadow: a tall gradient that eases clear -> black so it blends softly into the photo
        // (no hard edge), with the controls on the solid part at the bottom.
        .padding(.horizontal, 18).padding(.top, 64).padding(.bottom, max(22, bottomInset + 10))
        .background(LinearGradient(stops: [
            .init(color: .clear,                 location: 0.0),
            .init(color: .black.opacity(0.35),   location: 0.45),
            .init(color: .black.opacity(0.85),   location: 0.78),
            .init(color: .black,                 location: 1.0)
        ], startPoint: .top, endPoint: .bottom))
    }

    // Solid black footer BELOW the rounded story card (target design): the story canvas is a card
    // with clipped bottom corners, and the Views + trash controls live on their own black bar —
    // no more gradient bleeding over the story to the screen edge.
    static let ownerFooterHeight: CGFloat = 52
    private var ownerFooter: some View {
        Group { if isUploadingItem { uploadingControls } else { ownerControls } }
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity)
            .frame(height: Self.ownerFooterHeight)
            .padding(.bottom, max(10, bottomInset))
            .background(Color.black)
            // NO own swipe gesture here: the footer sits inside storyLayer, whose single drag already
            // owns swipe-up-to-open. A second gesture here double-fired (open + close) on footer flicks.
    }

    private func loadBarViewers() {
        guard currentIsMine, !currentStoryId.isEmpty else { return }
        let id = currentStoryId
        Task {
            let v = await StoriesService.shared.fetchViewers(storyId: id)
            if id == currentStoryId { barViewers = v }
        }
    }

}

// Live viewer for a story that's STILL uploading: renders the local image full-screen with an "Uploading…"
// status bar (X · spinner · label · trash). Listens to the upload state; when it finishes successfully it
// hands off to the real story viewer automatically.
struct UploadingStoryViewer: View {
    var meName: String
    var mePhoto: String?
    var hasOlder: Bool = false          // I already have posted stories behind this uploading one
    var onClose: () -> Void
    var onSeeOlder: () -> Void = {}     // tap/swipe LEFT → browse my already-posted (older) stories
    var onFinished: () -> Void          // upload succeeded → open the real story viewer
    @State private var stories = StoriesService.shared

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let img = stories.uploadingImage {
                Image(uiImage: img).resizable().scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(   // top scrim so the header stays readable on bright photos
                        LinearGradient(colors: [.black.opacity(0.5), .clear], startPoint: .top, endPoint: .bottom)
                            .frame(height: 130).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                            .allowsHitTesting(false),
                        alignment: .top)
            }
            // Left affordance: while this newest story uploads, tap the "‹" (or swipe right) to step
            // back into my already-posted older stories — the upload keeps running in the background.
            if hasOlder {
                HStack {
                    Button(action: onSeeOlder) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(.white.opacity(0.9))
                            .frame(width: 54)
                            .frame(maxHeight: .infinity)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
                .padding(.vertical, 96)   // clear the top header + the bottom upload status bar
            }
            VStack {
                HStack(spacing: 10) {
                    AvatarView(name: meName, photoUrl: mePhoto, size: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Your story").font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                        Text("just now").font(.caption).foregroundStyle(.white.opacity(0.7))
                    }
                    Spacer()
                    Button { onClose() } label: {
                        Image(systemName: "xmark").font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
                            .frame(width: 40, height: 40).contentShape(Rectangle())
                    }
                }
                .padding(.horizontal, 16).padding(.top, 8)
                Spacer()
                // Bottom upload status bar: X (close) · spinner · "Uploading…" · trash (cancel).
                HStack(spacing: 14) {
                    Button { onClose() } label: {
                        Image(systemName: "xmark").font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
                    }
                    Spinner(size: 20, color: .white)
                    Text("Uploading…").font(.subheadline).foregroundStyle(.white)
                    Spacer()
                    Button { stories.cancelUpload(); onClose() } label: {
                        Image(systemName: "trash").font(.system(size: 18)).foregroundStyle(.white)
                    }
                }
                .padding(.horizontal, 20).padding(.vertical, 16)
                .background(Color.black)
            }
        }
        // Swipe RIGHT anywhere → same as tapping the "‹": go back to my older posted stories.
        .simultaneousGesture(
            DragGesture(minimumDistance: 24).onEnded { v in
                guard hasOlder,
                      v.translation.width > 60,
                      abs(v.translation.width) > abs(v.translation.height) else { return }
                onSeeOlder()
            }
        )
        .onChange(of: stories.uploading) { _, up in
            guard !up else { return }   // upload finished
            if stories.uploadError == nil { onFinished() } else { onClose() }
        }
        .onAppear { if !stories.uploading { onFinished() } }   // finished before we even opened
    }
}

// ONE full-screen cover across the whole upload. The uploading photo is shown as the NEWEST item
// INSIDE the real story viewer (real progress bars, header, swipe to my older posted stories), with
// an "Uploading…" bar on it. When the upload finishes, the viewer re-feeds to my real stories (the
// just-posted image is already URLCache-warm, so no reload flash) and lands on the finished story.
struct UploadingStoryHandoff: View {
    var meName: String
    var mePhoto: String?
    var onClose: () -> Void                       // dismiss the cover (both phases)
    var onProfile: (StoryGroup) -> Void = { _ in }
    @State private var repo = StoriesRepository.shared
    @State private var svc = StoriesService.shared

    // My stories + the synthetic uploading item (newest). Once `uploadingStory` goes nil (upload done),
    // this is just my real stories, which now include the just-posted one.
    private var group: StoryGroup? {
        guard let s = svc.uploadingStory else { return repo.mine }
        if var g = repo.mine { g.stories.append(s); return g }
        return StoryGroup(authorUid: s.authorUid, name: meName, photoUrl: mePhoto,
                          stories: [s], lastViewedAt: nil, isMine: true)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()   // constant backdrop so the re-feed never blinks
            if let g = group {
                StoryViewer(group: g, onClose: onClose, onProfile: onProfile)
                    // Re-feed identity when the upload flips done → open on the real just-posted story
                    // (image already URLCache-warm from postStory, so the swap is seamless).
                    .id(svc.uploading)
            } else {
                // Nothing to show (no stories and no upload) → just close.
                Color.clear.onAppear { onClose() }
            }
        }
    }
}

// "Seen by" sheet — who viewed my status (premium, like WhatsApp/IG).
struct SeenBySheet: View {
    let storyId: String
    @Environment(\.dismiss) private var dismiss
    @State private var viewers: [StoryViewerInfo] = []
    @State private var loading = true

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if viewers.isEmpty {
                    ContentUnavailableView("No views yet", systemImage: "eye",
                        description: Text("When people view your status, they'll appear here."))
                } else {
                    List(viewers) { v in
                        HStack(spacing: 12) {
                            AvatarView(name: v.name, photoUrl: v.photoUrl, size: 42)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(v.name).font(.body)
                                Text(v.viewedAt, format: .relative(presentation: .named))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let r = v.reaction, !r.isEmpty { Text(r).font(.title3) }
                        }
                        .listRowSeparator(.hidden)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle(viewers.isEmpty ? "Seen by" : "Seen by \(viewers.count)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
        .task {
            viewers = await StoriesService.shared.fetchViewers(storyId: storyId)
            loading = false
        }
    }
}


// Carousel of ALL my posted stories, shown above the open viewers sheet (Telegram / user mockup):
// ONLY the rounded photos — no captions, no avatars, no progress bars. Side cards carry a small
// eye+heart count inside their bottom edge; the CENTRED card shows its count BIG underneath.
// Swiping (or tapping a side card) re-centres a story and re-targets the viewers list below.
struct MyStoriesCarousel: View {
    let stories: [Story]
    @Binding var activeId: String
    let slotW: CGFloat
    let slotH: CGFloat
    var onActiveTap: () -> Void = {}    // tap the centred card → collapse back to full screen

    @State private var byStory: [String: [StoryViewerInfo]] = [:]   // per-story viewers (counts)
    // Native paged scroll position: the id of the card snapped to centre. Seeded to the opened-on story
    // so the row opens centred on it; SwiftUI's .viewAligned physics follow the finger 1:1 and snap to
    // the nearest card on release (swipe past ~50% → next). It only updates when the scroll SETTLES, so
    // the parent no longer re-renders every frame mid-swipe (that was the jank / "hard to swipe").
    // Custom finger-tracking pager (replaces a .viewAligned ScrollView, which needed a ~50% drag or a
    // hard flick to advance and snapped back otherwise — the "hard to swipe"). `index` is the centred
    // card; the row is a plain offset HStack so the drag follows the finger 1:1 and commits to the next
    // card at just 30%. Seeding `index` in init also kills the old .scrollPosition centring race.
    @State private var index = 0
    @State private var dragX: CGFloat = 0     // live horizontal finger translation
    @State private var dragging = false

    init(stories: [Story], activeId: Binding<String>, slotW: CGFloat, slotH: CGFloat,
         onActiveTap: @escaping () -> Void = {}) {
        self.stories = stories
        self._activeId = activeId
        self.slotW = slotW
        self.slotH = slotH
        self.onActiveTap = onActiveTap
        self._index = State(initialValue: stories.firstIndex(where: { $0.id == activeId.wrappedValue }) ?? 0)
    }

    var body: some View {
        let focusedID = stories.indices.contains(index) ? stories[index].id : activeId
        let active = byStory[focusedID] ?? []
        let activeReacts = active.filter { !($0.reaction ?? "").isEmpty }.count
        let gap: CGFloat = 12
        let step = slotW + gap
        let n = stories.count
        let totalW = CGFloat(n) * slotW + CGFloat(max(0, n - 1)) * gap
        let offsetX = totalW / 2 - (CGFloat(index) * step + slotW / 2) + dragX
        VStack(spacing: 12) {
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: slotH)   // centre card fills the slot; neighbours peek + scale DOWN (not clipped)
                .overlay {
                    HStack(spacing: gap) {
                        ForEach(stories, id: \.id) { s in card(s) }
                    }
                    .offset(x: offsetX)   // follows the finger via dragX; centres `index` otherwise
                }
                .contentShape(Rectangle())
                // Horizontal drag pages the cards, tracking the finger 1:1. A vertical drag is left to the
                // backdrop's collapse gesture (each guards its own axis) so the two never fight.
                .simultaneousGesture(
                    DragGesture(minimumDistance: 8)
                        .onChanged { v in
                            // Engage ONLY on a decisive horizontal move, and lock to it. A vertical (close)
                            // drag must never page or wobble the cards — that wobble was the close "shake";
                            // the backdrop owns the downward close.
                            if !dragging {
                                guard abs(v.translation.width) > 12,
                                      abs(v.translation.width) > abs(v.translation.height) * 1.4 else { return }
                                dragging = true
                            }
                            dragX = v.translation.width
                        }
                        .onEnded { v in
                            let wasDragging = dragging
                            dragging = false
                            guard wasDragging else { dragX = 0; return }
                            // Commit to the neighbour at just 30% of a card step (or a flick), so the next
                            // card is EASY to reach; otherwise settle back. predictedEndTranslation carries
                            // the fling so a quick short flick still advances.
                            let commit = step * 0.30
                            let predicted = v.predictedEndTranslation.width
                            var ni = index
                            if v.translation.width <= -commit || predicted <= -step * 0.5 {
                                ni = min(index + 1, max(0, n - 1))
                            } else if v.translation.width >= commit || predicted >= step * 0.5 {
                                ni = max(index - 1, 0)
                            }
                            withAnimation(.interactiveSpring(response: 0.34, dampingFraction: 0.86)) {
                                index = ni
                                dragX = 0
                            }
                            if stories.indices.contains(ni) { activeId = stories[ni].id }
                        }
                )
            // The centred card's count, big + centred under the carousel (mockup).
            countRow(views: active.count, likes: activeReacts, big: true)
        }
        // The CENTRED card is the single source of truth: keep sheetStoryId (activeId) in lockstep with
        // it, so the story behind + the close ALWAYS land on exactly the card you see. Without this the
        // seeded `index` and `activeId` could drift (open on A, close showed B).
        .onChange(of: index) { _, i in
            guard stories.indices.contains(i), stories[i].id != activeId else { return }
            activeId = stories[i].id
        }
        // External retarget (rare) → recentre, but never while the finger is dragging.
        .onChange(of: activeId) { _, v in
            guard !dragging, let ni = stories.firstIndex(where: { $0.id == v }), ni != index else { return }
            withAnimation(.interactiveSpring(response: 0.34, dampingFraction: 0.86)) { index = ni }
        }
        // Re-seed from the opened-on story in case `stories` was still loading at init.
        .onAppear {
            if let ni = stories.firstIndex(where: { $0.id == activeId }), ni != index { index = ni }
        }
        .task { await loadAll() }
    }

    private func card(_ s: Story) -> some View {
        let vs = byStory[s.id] ?? []
        let reacts = vs.filter { !($0.reaction ?? "").isEmpty }.count
        return StoryImage(url: s.mediaUrl, fitBlur: true)   // whole image + blur, same as the story/morph
            .frame(width: slotW, height: slotH)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(alignment: .bottom) {
                // Side cards show a small count inside; the CENTRED card hides it (big count below).
                countRow(views: vs.count, likes: reacts, big: false)
                    .padding(.bottom, 10)
                    .visualEffect { content, proxy in
                        content.opacity(Self.centreDistance(proxy) < 0.35 ? 0 : 1)
                    }
            }
            // GEOMETRY-based scale (scrollTransition's phase barely moved for the visible neighbours,
            // so all cards looked the same size). Each card measures its own distance from the SCREEN
            // centre: t=0 centred → scale 1.0 (large), t=1 one slot away → scale 0.72 (clearly smaller),
            // matching the mockup's focus hierarchy. Recomputes live as the row scrolls.
            .visualEffect { content, proxy in
                let t = Self.centreDistance(proxy)
                return content
                    .scaleEffect(1.0 - 0.28 * t)
                    .opacity(1.0 - 0.3 * t)
                    .saturation(1.0 - 0.45 * t)
            }
            .id(s.id)
            .onTapGesture {
                if s.id == activeId { onActiveTap() }
                else if let ni = stories.firstIndex(where: { $0.id == s.id }) {
                    withAnimation(.interactiveSpring(response: 0.4, dampingFraction: 0.84)) { index = ni }
                    activeId = s.id
                }
            }
    }

    // 0 when the card is centred on screen, → 1 one slot-width away (clamped). Drives the cover-flow scale.
    private static func centreDistance(_ proxy: GeometryProxy) -> CGFloat {
        let screenMid = UIScreen.main.bounds.width / 2
        let mid = proxy.frame(in: .global).midX
        return min(abs(mid - screenMid) / (UIScreen.main.bounds.width * 0.42), 1)
    }

    // Eye + views + heart + likes, white over a soft shadow. `big` = the centred card's row below.
    private func countRow(views: Int, likes: Int, big: Bool) -> some View {
        HStack(spacing: big ? 7 : 5) {
            Image(systemName: "eye.fill")
            Text(compactCount(views))
            if likes > 0 {
                Image(systemName: "heart.fill").foregroundStyle(.red).padding(.leading, 4)
                Text(compactCount(likes))
            }
        }
        .font(big ? .subheadline.weight(.bold) : .caption2.weight(.semibold))
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.5), radius: 3)
    }

    private func compactCount(_ n: Int) -> String {
        if n >= 1000 { return String(format: "%.1fK", Double(n) / 1000).replacingOccurrences(of: ".0K", with: "K") }
        return "\(n)"
    }

    private func loadAll() async {
        await withTaskGroup(of: (String, [StoryViewerInfo]).self) { group in
            for s in stories { group.addTask { (s.id, await StoriesService.shared.fetchViewers(storyId: s.id)) } }
            for await (id, v) in group { byStory[id] = v }
        }
    }
}

// Telegram-architecture viewers sheet: a SEPARATE bottom layer holding ONLY the drag handle, search,
// and the scrollable viewer list — NO story media (the carousel above it is its own layer). It drives
// `progress` (0 closed … 1 open); the StoryViewer's backdrop reads the same value → always in sync.
struct StoryViewersBottomSheet: View {
    // Sheet height as a fraction of the screen. The story viewer derives the carousel slot from this
    // same value, so the two layers always agree on the layout. Telegram makes the LIST the dominant
    // element (~70%) with the story shrunk to a small preview card on top — so the sheet is tall.
    static let heightFraction: CGFloat = 0.64   // shorter sheet → more room so the story cards read BIG (was 0.70)

    let activeStoryId: String
    @Binding var progress: CGFloat
    let onClose: () -> Void

    @State private var viewers: [StoryViewerInfo] = []
    @State private var search = ""
    @State private var loading = true
    @State private var tab = 0   // 0 = All Viewers, 1 = Contacts (Telegram tabs)
    @State private var dragStart: CGFloat? = nil
    @State private var listOffset: CGFloat = 0   // the viewer list's scroll offset (0 = top)

    // Uids of my 1:1 contacts — for the "Contacts" tab filter.
    private var contactUids: Set<String> {
        let me = AuthService.shared.uid ?? ""
        return Set(ConversationsRepository.shared.conversations
            .filter { !$0.isGroup }.map { $0.otherUid(me) }.filter { !$0.isEmpty })
    }

    private var filtered: [StoryViewerInfo] {
        var v = viewers
        if tab == 1 { let c = contactUids; v = v.filter { c.contains($0.id) } }   // Contacts tab
        let q = search.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty { v = v.filter { $0.name.localizedCaseInsensitiveContains(q) } }
        // Telegram order (sortMode .reactionsFirst): people who REACTED come first, then most-recent.
        return v.sorted { a, b in
            let ar = !(a.reaction ?? "").isEmpty
            let br = !(b.reaction ?? "").isEmpty
            if ar != br { return ar }            // reactions first
            return a.viewedAt > b.viewedAt       // then newest view
        }
    }

    var body: some View {
        GeometryReader { geo in
            let sheetH = geo.size.height * Self.heightFraction
            VStack(spacing: 0) {
                stickyHeader(sheetH: sheetH)        // drag handle + search
                viewerList(sheetH: sheetH)          // list scrolls; drag its top to collapse the sheet
            }
            .frame(height: sheetH)
            .background(
                UnevenRoundedRectangle(topLeadingRadius: 24, topTrailingRadius: 24, style: .continuous)
                    .fill(Color(white: 0.10))
            )
            .frame(maxHeight: .infinity, alignment: .bottom)   // park at the bottom of the screen
            // Rubber-band past fully-open (progress can exceed 1 while dragging up): resist so the
            // sheet eases to a soft stop instead of a hard wall, Telegram-style.
            .offset(y: (1 - min(progress, 1)) * sheetH - overshoot(progress) )
        }
        .ignoresSafeArea()
        .task(id: activeStoryId) {
            // Debounce: .task(id:) cancels+restarts on every carousel-centre change, so a short sleep
            // here means a fast scrub across many stories only fires ONE fetch when it settles.
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            await load()
        }
    }

    // Extra pixels the sheet rises above fully-open, with diminishing return (rubber band).
    private func overshoot(_ p: CGFloat) -> CGFloat {
        guard p > 1 else { return 0 }
        return 22 * (1 - 1 / (1 + (p - 1) * 3))   // asymptotes to ~22pt
    }

    // ONE unified drag (Telegram): dragging the handle/search OR the list (when the list is at its
    // top and you pull down) drives the sheet up/down. `fromList` gates the list case so mid-list
    // scrolling isn't hijacked. The list is scroll-disabled while the sheet isn't fully open, so once
    // a collapse starts the list locks and the drag owns the motion.
    private func sheetDrag(sheetH: CGFloat, fromList: Bool) -> some Gesture {
        DragGesture(minimumDistance: fromList ? 8 : 4)
            .onChanged { v in
                if fromList {
                    let atTop = listOffset <= 0.5
                    // Take over only when already collapsing, or at the top pulling DOWN.
                    guard progress < 1 || (atTop && v.translation.height > 0) else { return }
                }
                if dragStart == nil { dragStart = progress }
                // Track the finger 1:1; allow a little past 1.0 so overshoot() rubber-bands; clamp bottom at 0.
                progress = max(0, min(1.14, (dragStart ?? 1) - v.translation.height / sheetH))
            }
            .onEnded { v in
                guard dragStart != nil else { return }   // fromList drag that never engaged
                dragStart = nil
                // Where the sheet would COME TO REST given the fling: predictedEndTranslation is the
                // ADDITIONAL travel from here, so subtract only that.
                let extra = (v.predictedEndTranslation.height - v.translation.height) / sheetH
                let projected = progress - extra
                let close = projected < 0.6 || v.predictedEndTranslation.height > 240
                if close { onClose() }
                else {
                    withAnimation(.interactiveSpring(response: 0.34, dampingFraction: 0.78, blendDuration: 0.2)) {
                        progress = 1
                    }
                }
            }
    }

    // Sticky header (handle + tabs + search). Dragging here drives the sheet.
    private func stickyHeader(sheetH: CGFloat) -> some View {
        VStack(spacing: 12) {
            Capsule().fill(.white.opacity(0.28)).frame(width: 38, height: 5).padding(.top, 8)
            tabSelector
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.white.opacity(0.6))
                TextField("", text: $search, prompt: Text("Search").foregroundColor(.white.opacity(0.5)))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(.white.opacity(0.12), in: Capsule())
            .padding(.horizontal, 16)
        }
        .padding(.bottom, 10)
        .contentShape(Rectangle())
        // simultaneousGesture (not .gesture) so dragging down on the handle/tabs/search still drives the
        // sheet even though the tabs + search field have their own tap/edit gestures. This is what made
        // drag-down-to-close feel dead — the tab buttons were swallowing the drag.
        .simultaneousGesture(sheetDrag(sheetH: sheetH, fromList: false))
    }

    // "All Viewers | Contacts" tabs (Telegram StoryItemSetViewListComponent): active tab is white
    // with an underline, inactive is dimmed. Tapping switches the list filter (no sheet drag).
    private var tabSelector: some View {
        HStack(spacing: 24) {
            ForEach(0..<2, id: \.self) { i in
                Button { withAnimation(.easeInOut(duration: 0.18)) { tab = i } } label: {
                    VStack(spacing: 6) {
                        Text(i == 0 ? "All Viewers" : "Contacts")
                            .font(.subheadline.weight(tab == i ? .semibold : .regular))
                            .foregroundStyle(tab == i ? .white : .white.opacity(0.5))
                        Capsule().fill(tab == i ? Color.white : Color.clear).frame(height: 2)
                    }
                    .fixedSize()
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 18)
    }

    private func viewerList(sheetH: CGFloat) -> some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if loading {
                    ProgressView().tint(.white).padding(.top, 44).frame(maxWidth: .infinity)
                } else if filtered.isEmpty {
                    ContentUnavailableView("No views yet", systemImage: "eye",
                        description: Text("When people view this story, they'll show up here."))
                        .padding(.top, 40)
                } else {
                    ForEach(filtered) { v in
                        viewerRow(v)
                        Divider().overlay(Color.white.opacity(0.08)).padding(.leading, 74)
                    }
                }
            }
            .padding(.bottom, 30)
        }
        .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.y }) { _, y in listOffset = y }
        // No rubber-band bounce at the top: the bounce fought the collapse-drag below (the list sprang
        // while the sheet also moved = the "shaking" when pulling DOWN to close). Without it the drag
        // owns the downward motion cleanly, matching the smooth upward open.
        .scrollBounceBehavior(.basedOnSize)
        // Lock the list while the sheet isn't fully open OR while a collapse-drag is active (dragStart
        // set), so the list's own scroll/rubber-band can NEVER fight the drag at the top (that fight was
        // the down-drag "shaking"). The drag owns the motion cleanly, matching the smooth upward open.
        .scrollDisabled(progress < 1 || dragStart != nil)
        // Pulling the list down at its top collapses the sheet (Telegram hand-off).
        .simultaneousGesture(sheetDrag(sheetH: sheetH, fromList: true))
    }

    private var doubleCheck: some View {
        ZStack(alignment: .leading) {
            Image(systemName: "checkmark"); Image(systemName: "checkmark").offset(x: 4)
        }
        .font(.system(size: 9, weight: .bold))
    }

    private func viewerRow(_ v: StoryViewerInfo) -> some View {
        HStack(spacing: 12) {
            AvatarView(name: v.name, photoUrl: v.photoUrl, size: 46)
                .overlay(alignment: .bottomTrailing) {
                    if let r = v.reaction, !r.isEmpty {
                        Text(r).font(.system(size: 11))
                            .frame(width: 19, height: 19)
                            .background(Circle().fill(Color(.systemRed)))
                            .overlay(Circle().stroke(Color(white: 0.10), lineWidth: 2))
                            .offset(x: 3, y: 3)
                    }
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(v.name).font(.body.weight(.semibold)).foregroundStyle(.white)
                HStack(spacing: 5) { doubleCheck; Text(dateFmt(v.viewedAt)) }
                    .font(.caption).foregroundStyle(.white.opacity(0.5))
            }
            Spacer()
            Menu {
                Button { } label: { Label("Send message", systemImage: "message") }
                Button { } label: { Label("View profile", systemImage: "person.crop.circle") }
            } label: {
                Image(systemName: "ellipsis").font(.body).foregroundStyle(.white.opacity(0.55))
                    .frame(width: 38, height: 38).contentShape(Rectangle())
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
    }

    private func dateFmt(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "dd/MM/yy 'at' h:mm a"; return f.string(from: d)
    }

    private func load() async {
        let id = activeStoryId
        guard !id.isEmpty else { loading = false; return }
        if viewers.isEmpty { loading = true }
        let v = await StoriesService.shared.fetchViewers(storyId: id)
        if id == activeStoryId { viewers = v; loading = false }
    }
}

// Wrapper so a UIImage can drive a .sheet(item:).
struct StoryImagePayload: Identifiable {
    let id = UUID()
    let image: UIImage
}

// Forward a story image to one or more chats. sendImage re-encrypts per chat (and auto-fetches
// group members), so this works for 1:1 and groups. Real send pipeline — no fakes.
struct StoryForwardSheet: View {
    let image: UIImage
    var onSent: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var repo = ConversationsRepository.shared
    @State private var query = ""
    @State private var selected = Set<String>()
    @State private var sending = false
    private var me: String { AuthService.shared.uid ?? "" }

    private var people: [Conversation] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let list = repo.conversations.filter { ($0.isGroup || !$0.otherUid(me).isEmpty) && !$0.isCleared(me) }
        return (q.isEmpty ? list : list.filter { $0.displayName(me).lowercased().contains(q) })
            .sorted { $0.displayUpdatedAt(me) > $1.displayUpdatedAt(me) }
    }

    var body: some View {
        NavigationStack {
            List(people) { c in
                Button {
                    if selected.contains(c.id) { selected.remove(c.id) } else { selected.insert(c.id) }
                } label: {
                    HStack(spacing: 12) {
                        AvatarView(name: c.displayName(me), photoUrl: c.displayPhoto(me), size: 44)
                        Text(c.displayName(me)).font(.body)
                        Spacer()
                        Image(systemName: selected.contains(c.id) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selected.contains(c.id) ? Color.accentColor : .secondary)
                    }
                }
                .buttonStyle(.plain)
                .listRowSeparator(.hidden)
            }
            .listStyle(.plain)
            .searchable(text: $query, prompt: "Search")
            .navigationTitle("Forward to…")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(sending ? "Sending…" : "Send") { send() }
                        .disabled(selected.isEmpty || sending).fontWeight(.semibold)
                }
            }
        }
    }

    private func send() {
        guard let data = image.jpegData(compressionQuality: 0.9), !selected.isEmpty else { return }
        sending = true
        let ids = Array(selected)
        Task {
            for cid in ids { try? await ChatService.sendImage(cid: cid, data: data) }
            await MainActor.run { dismiss(); onSent() }
        }
    }
}
