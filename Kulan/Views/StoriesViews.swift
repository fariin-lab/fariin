import SwiftUI
import PhotosUI
import Photos
import UIKit
import CoreImage
import StoryUI

// Segmented story ring: one arc per story (3 stories = 3 arcs with gaps, 1 = full circle).
// Colorful gradient when unviewed, grey when viewed. Reused on story cards AND chat-list avatars.
struct StoryRingView: View {
    let seen: [Bool]                 // per segment, oldest→newest; true = viewed (grey), false = colorful
    var lineWidth: CGFloat = 2.0     // the active line width (unseen); seen is drawn thinner
    @Environment(\.colorScheme) private var scheme

    /// A watched ring, in the owner's own two hex values (2026-08-03): #505052 in dark, #CACACA in
    /// light. It has to be two colours rather than one: "already seen" is said by being QUIETER than
    /// the page, and quieter means darker on white and lighter on black. A single grey that reads as
    /// spent on one background reads as a deliberate mark on the other.
    private var seenColor: Color {
        scheme == .dark ? Color(hex: 0x505052) : Color(hex: 0xCACACA)
    }

    var body: some View {
        // Ring spec:
        //  • UNSEEN gradient storyUnseenColors = 0x34C76F (green) → 0x3DA1FD (blue), both themes
        //  • SEEN solid, per theme — see `seenColor`
        //  • the SEEN ring is thinner than the unseen ring (inactiveLineWidth < activeLineWidth)
        //  • segment gap = activeLineWidth * 2  (points along the circumference)
        GeometryReader { geo in
            let d = min(geo.size.width, geo.size.height)
            let n = max(1, seen.count)
            let activeW = lineWidth
            let seenW = max(1, lineWidth * 0.66)                       // inactiveLineWidth
            let gradient = AnyShapeStyle(LinearGradient(colors: [Color(hex: 0x34C76F), Color(hex: 0x3DA1FD)],
                                                        startPoint: .top, endPoint: .bottom))
            let grey = AnyShapeStyle(seenColor)
            let gapPts: CGFloat = n > 1 ? activeW * 2.0 : 0           // spacing = activeLineWidth·2
            let gap = d > 0 ? gapPts / (CGFloat.pi * d) : 0
            let seg = 1.0 / CGFloat(n)
            ZStack {
                ForEach(0..<n, id: \.self) { i in
                    let isSeen = i < seen.count ? seen[i] : false
                    Circle()
                        .inset(by: activeW / 2)                       // keep the stroke inside the frame
                        .trim(from: CGFloat(i) * seg + gap / 2, to: CGFloat(i + 1) * seg - gap / 2)
                        .stroke(isSeen ? grey : gradient,
                                style: StrokeStyle(lineWidth: isSeen ? seenW : activeW, lineCap: .round))
                }
            }
            .rotationEffect(.degrees(-90))                            // first segment starts at the top
        }
    }
}

// Cached story image: memory + persistent disk (DiskImageCache), so swiping
// back/forward, reopening, and app relaunches load instantly with no re-download.
// The exact dark blur the story viewer uses over its fill backdrop (ImageLoader's
// UIVisualEffectView(.systemThickMaterialDark)) — so bars look identical in-story and in-sheet.
// Clips the shrinking story to its CONTENT rect (photo area, not the layer's full height,
// which extends into the faded footer region) — so all four rounded corners land exactly
// on the visible card's edges. radius 0 = plain content rect.
struct StoryCardClip: Shape {
    var radius: CGFloat
    var topCut: CGFloat = 0        // centre-crop: the window starts this far down (unscaled)
    var contentHeight: CGFloat     // ...and ends at this absolute bottom edge
    func path(in rect: CGRect) -> Path {
        let bottom = min(contentHeight, rect.height)
        let r = CGRect(x: 0, y: topCut, width: rect.width, height: max(0, bottom - topCut))
        return Path(roundedRect: r, cornerRadius: radius, style: .continuous)
    }
}

struct StoryDarkBlur: UIViewRepresentable {
    func makeUIView(context: Context) -> UIVisualEffectView {
        UIVisualEffectView(effect: UIBlurEffect(style: .systemThickMaterialDark))
    }
    func updateUIView(_ uiView: UIVisualEffectView, context: Context) {}
}

// Pre-baked imitation of systemThickMaterialDark for views that must CROSSFADE:
// a real UIVisualEffectView drops its blur entirely whenever it's composited at
// fractional opacity (the bright flash while the viewers sheet opened/closed).
// Used ONLY by the mid-transition morph card — the story's own bars and the
// carousel keep the real material, so the at-rest look is untouched (build 216).
enum StoryBlurBake {
    private static let cache = NSCache<NSString, UIImage>()
    static func cached(_ url: String) -> UIImage? { cache.object(forKey: url as NSString) }
    static func bake(_ img: UIImage, url: String) -> UIImage {
        if let hit = cached(url) { return hit }
        // Pseudo-gaussian with ZERO CoreImage: collapse the photo to a tiny thumbnail, then
        // stretch it back up — the interpolation produces the same smooth low-frequency wash
        // as a heavy blur. The previous CIGaussianBlur pipeline silently produced BLACK on
        // both the simulator and real devices (measured RGB 0,0,0 in the user's screenshot),
        // and 50% black over black = the "blur is gone" bug. Pure UIKit drawing cannot fail.
        let fmt = UIGraphicsImageRendererFormat.default()
        fmt.scale = 1
        // 4×4, not 16×16: the real systemThickMaterialDark shows essentially NO image
        // structure — at 16px the stretched thumbnail still ghosted recognizable shapes,
        // which read as "a different blur" next to the at-rest bars (user screenshot).
        let tiny = CGSize(width: 4, height: 4)
        let thumb = UIGraphicsImageRenderer(size: tiny, format: fmt).image { ctx in
            ctx.cgContext.interpolationQuality = .medium
            img.draw(in: CGRect(origin: .zero, size: tiny))
        }
        let outSize = CGSize(width: 240, height: 240)
        let out = UIGraphicsImageRenderer(size: outSize, format: fmt).image { ctx in
            ctx.cgContext.interpolationQuality = .high   // smooth stretch = the blur
            thumb.draw(in: CGRect(origin: .zero, size: outSize))
            // Calibrated against the REAL systemThickMaterialDark: measured from device
            // screenshots, the material renders the bars at ~22% of the photo's brightness
            // (photo luma ~171 → bar luma ~38), so the veil is 0.78 — the earlier 0.5 was
            // tuned for a different pipeline and would read too bright here.
            // 0.88 (was 0.78): the real systemThickMaterialDark reads DARKER than the old linear
            // calibration on bright photos, so the baked morph looked visibly lighter than the live
            // bars at both ends of the pull-up (user: "blur is going to be weak"). A heavier veil
            // keeps the mid-drag morph close to the live material the story + carousel now use.
            UIColor.black.withAlphaComponent(0.88).setFill()
            ctx.fill(CGRect(origin: .zero, size: outSize))
        }
        cache.setObject(out, forKey: url as NSString)
        return out
    }
}

struct StoryImage: View {
    let url: String
    // fitBlur = show the WHOLE image (aspect-fit) over a blurred fill of itself — the SAME look as the
    // story viewer, so a wide/tall photo isn't cropped/zoomed and keeps its blur bars. Used for the
    // swipe-up morph card + the viewers carousel; the small story-row covers stay plain fill (crop).
    var fitBlur = false
    // bakedBars = the fit-case backdrop is a PRE-BAKED blur image instead of the live material.
    // Only the morph card (which crossfades) uses it — materials break at fractional opacity.
    var bakedBars = false
    // cardFillThreshold = the fill-vs-blur decision uses THIS aspect (image height/width) instead of
    // the screen's. The shorter viewer cards pass slotH/slotW so any image as tall as the card fills
    // (no side bars) and only wider images get blur bars; nil = decide against the full screen.
    var cardFillThreshold: CGFloat? = nil
    @State private var image: UIImage?
    @State private var blurredBG: UIImage?   // baked dark backdrop, from StoryBlurBake

    /// FIRST-FRAME SEED FROM MEMORY, and this is the story-card flash (owner 2026-08-03: "when i
    /// scroll up and scroll down is flashing", with a shot of the card as a plain grey rectangle —
    /// that rectangle is `SkeletonFill`).
    ///
    /// `image` is per-instance @State and `load()` begins with an `await`, so EVERY newly created
    /// StoryImage draws the skeleton for at least one frame even when the bytes are already in
    /// memory. Pulling the viewers sheet hands the card over between two different views — the morph
    /// card that flies down and the carousel card that receives it — so a fresh instance appears
    /// mid-drag, and one skeleton frame under a moving finger is exactly the flash he sees.
    ///
    /// Memory only, never the disk: this runs during a gesture and `AvatarView`'s synchronous disk
    /// read is licensed by avatars being a few KB. A story is a full-screen photo. A miss simply
    /// falls through to `load()` as before.
    init(url: String, fitBlur: Bool = false, bakedBars: Bool = false, cardFillThreshold: CGFloat? = nil) {
        self.url = url
        self.fitBlur = fitBlur
        self.bakedBars = bakedBars
        self.cardFillThreshold = cardFillThreshold
        if let warm = DiskImageCache.shared.memoryImage(url) { _image = State(initialValue: warm) }
    }

    var body: some View {
        Group {
            if let image {
                if fitBlur {
                    // Match the story viewer's ImageLoader EXACTLY, both rules:
                    //  • an image at least as TALL as the screen (9:16 photos, text statuses) fills
                    //    edge-to-edge with NO blur bars — don't add bars the story never had;
                    //  • shorter images aspect-FIT over the SAME dark backdrop the story uses
                    //    (fill + systemThickMaterialDark), not a bright gaussian blur.
                    // Every fill lives INSIDE an overlay of Color.clear so it can never report an
                    // oversized layout (a bare scaledToFill blew a wide panorama into a huge zoomed
                    // crop the moment the viewers sheet appeared — the ZStack adopted its size).
                    if fillsScreen(image) {
                        Color.clear
                            .overlay(Image(uiImage: image).resizable().scaledToFill())
                            .clipped()
                            .transition(.opacity)
                    } else {
                        // ORIGINAL nesting (build 216): fill INSIDE the first overlay, the blur layer as a
                        // SECOND overlay on Color.clear — so the blur is sized to the CARD, never to the
                        // (possibly enormous) overflowing fill image. Nesting the blur on the fill image
                        // itself gave it the fill's oversized frame and the material rendered BLACK on the
                        // sheet cards (the "blur is gone" regression). Only the TOP layer varies:
                        // the real material normally, the baked crossfade-safe copy for the morph card.
                        ZStack {
                            Color.clear
                                .overlay(Image(uiImage: image).resizable().scaledToFill())
                                .overlay {
                                    if bakedBars, let bg = blurredBG {
                                        Image(uiImage: bg).resizable().scaledToFill()
                                    } else {
                                        StoryDarkBlur()
                                    }
                                }
                                .clipped()
                            Image(uiImage: image).resizable().scaledToFit()
                        }
                        .transition(.opacity)
                    }
                } else {
                    Image(uiImage: image).resizable().scaledToFill()
                        .transition(.opacity)
                }
            } else {
                // No black placeholder ever (user report): whether still loading OR a fetch failed,
                // show the shimmer skeleton. load() retries with backoff so a transient failure —
                // a brief network blip, or a cold disk cache right after an app update — recovers on
                // its own instead of freezing the card on a dead black "photo" icon.
                SkeletonFill()
            }
        }
        .animation(.easeOut(duration: 0.25), value: image != nil)   // fade in when loaded
        .task(id: url) { await load() }
    }
    // Fill vs fit. Against cardFillThreshold when a caller passes the aspect of the box it is
    // drawing into, so an image as tall as that box fills it with no side bars; against the screen
    // aspect otherwise.
    //
    // ⚠️ THE SCREEN FALLBACK IS NO LONGER WHAT THE STORY ITSELF DOES. `ImageLoader.decideContentMode`
    // measures the CARD now (it was measuring the screen, which letterboxed every 9:16-ish photo —
    // his left/right blur bands). The callers that still fall through to the screen here are small
    // thumbnails and row covers, where the box is nothing like a story card and the old rule is
    // harmless. Anything drawing a story-shaped surface must pass its own aspect, as the viewers
    // carousel does.
    private func fillsScreen(_ img: UIImage) -> Bool {
        guard img.size.width > 0 else { return false }
        let ratio = img.size.height / img.size.width
        if let t = cardFillThreshold { return ratio >= t - 0.02 }
        let screen = UIScreen.main.bounds
        return ratio >= screen.height / screen.width - 0.02
    }

    @MainActor private func load() async {
        if let cached = await DiskImageCache.shared.image(for: url) { await apply(cached); return }
        guard let u = URL(string: url), !url.isEmpty else { return }
        // Retry with backoff so a card never gets stuck on a black placeholder. The two reported
        // failures — "sometimes a black image" and "after updating the app I can't see my story" —
        // are both a single failed fetch (a network blip, or a cold disk cache after a fresh
        // install) that used to be permanent. Now we re-attempt a few times, keeping the shimmer
        // skeleton up between tries, and recover the instant the fetch succeeds.
        let delays: [UInt64] = [0, 600_000_000, 1_500_000_000, 3_000_000_000, 6_000_000_000]
        for delay in delays {
            if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
            if Task.isCancelled { return }
            if let (data, _) = try? await MediaSession.shared.data(from: u), let img = UIImage(data: data) {
                DiskImageCache.shared.store(img, data: data, for: url)
                await apply(img)
                return
            }
        }
        // Still failing after all attempts (rare for a live story URL) — leave the skeleton up
        // rather than the old black card; a repo reload with a fresh URL retriggers this task.
    }

    @MainActor private func apply(_ img: UIImage) async {
        image = img
        // Bake the crossfade-safe backdrop off-main (morph card only; cached per URL).
        guard bakedBars, fitBlur, !fillsScreen(img), blurredBG == nil else { return }
        if let hit = StoryBlurBake.cached(url) { blurredBG = hit; return }
        let u = url
        blurredBG = await Task.detached(priority: .userInitiated) { StoryBlurBake.bake(img, url: u) }.value
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
    /// Sign-out: SessionWipe clears the stored keys, but this in-memory mirror would keep serving
    /// the previous account's hidden authors / seen items / likes until the app restarts (audit).
    static func dropCaches() {
        lock.lock(); cache.removeAll(); lock.unlock()
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
    // MARK: - One-time stories, and the private name of a custom one

    /// A ONE-TIME STORY I HAVE OPENED. Local, and only ever a HEAD START on the server.
    ///
    /// The real enforcement is that the server takes me out of the story's `recipientUids`, which no
    /// client can undo (the update rule pins that field). But that happens on a trigger a beat after
    /// my receipt lands, and "immediately" is his word — so the story leaves my tray on the tap and
    /// this remembers that decision across a relaunch in the seconds before the server agrees.
    ///
    /// Deliberately NOT the thing that makes one-time work. If this file were deleted the story would
    /// still be gone, because it is gone on the server.
    static func isOneTimeUsed(_ storyId: String) -> Bool { set("oneTimeUsed").contains(storyId) }
    static func markOneTimeUsed(_ storyId: String) {
        var s = set("oneTimeUsed"); s.insert(storyId); save("oneTimeUsed", s)
    }

    /// THE NAME OF A CUSTOM STORY I POSTED, kept here and nowhere else.
    ///
    /// The header shows the list's name to ME and the plain word "Custom" to everybody else, which is
    /// his rule twice over ("only you can see the name of this story", and "they should not see any
    /// private details beyond the audience type"). A recipient can read the whole story document, so
    /// the only way that rule can be true is for the name never to be in it.
    ///
    /// A plain dictionary rather than the space-joined sets above, because a story name can contain
    /// spaces and those sets split on them.
    private static let audienceNamesKey = "storyAudienceNames"
    static func rememberAudienceName(storyId: String, tag: StoryAudienceTag) {
        guard tag.label == "custom", !tag.name.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        var d = UserDefaults.standard.dictionary(forKey: audienceNamesKey) as? [String: String] ?? [:]
        // Same append-only shape as the seen/liked stores, and the same answer to it: a story is
        // gone in 24 hours but its name would sit here forever.
        if d.count > 300 { d.removeAll() }
        d[storyId] = tag.name
        UserDefaults.standard.set(d, forKey: audienceNamesKey)
    }
    static func audienceName(storyId: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return (UserDefaults.standard.dictionary(forKey: audienceNamesKey) as? [String: String])?[storyId]
    }

    static func isNotifying(_ uid: String) -> Bool { set("notifyStories").contains(uid) }
    static func toggleNotify(_ uid: String) {
        var s = set("notifyStories"); if s.contains(uid) { s.remove(uid) } else { s.insert(uid) }; save("notifyStories", s)
    }
    // seen/liked stores were APPEND-ONLY and grew forever (every story id ever). Keep them as
    // ORDERED arrays on disk (append at the end) so "oldest" is well-defined, and drop the oldest
    // half once past 1000 ids — same cap pattern as VoicePlayed's 600 in Models.swift.
    private static func mutateOrdered(_ key: String, _ change: (inout [String]) -> Void) {
        lock.lock()
        var arr = (UserDefaults.standard.string(forKey: key) ?? "").split(separator: " ").map(String.init)
        change(&arr)
        if arr.count > 1000 { arr.removeFirst(arr.count - 500) }
        cache[key] = Set(arr)   // update cache synchronously → instant reads
        lock.unlock()
        UserDefaults.standard.set(arr.joined(separator: " "), forKey: key)
    }
    // Per-STORY-ITEM seen state (drives the segmented ring: each arc greys as you view that story).
    static func isStorySeen(_ id: String) -> Bool { set("seenStoryItems").contains(id) }
    static func markStorySeen(_ id: String) {
        guard !id.isEmpty, !isStorySeen(id) else { return }
        mutateOrdered("seenStoryItems") { $0.append(id) }
    }
    // My own ❤️ on a story — persists so the heart is still red on reopen.
    static func isStoryLiked(_ id: String) -> Bool { set("likedStories").contains(id) }
    static func setStoryLiked(_ id: String, _ liked: Bool) {
        guard !id.isEmpty else { return }
        mutateOrdered("likedStories") { arr in
            arr.removeAll { $0 == id }
            if liked { arr.append(id) }
        }
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
    /// A story viewer is open — hold the row's order still until it closes. Declared HERE, with the
    /// other inputs, because the memberwise initializer takes its arguments in declaration order and
    /// the call site reads better with the row's inputs together. See `displayedOthers`.
    var freezeOrder: Bool = false
    var onCompose: () -> Void
    var onOpen: (StoryGroup) -> Void
    var onMessage: (StoryGroup) -> Void = { _ in }
    var onProfile: (StoryGroup) -> Void = { _ in }
    var onOpenUploading: () -> Void = {}   // tap the still-uploading card → live upload viewer
    @State private var prefsTick = 0   // re-render after hide/notify toggles
    @State private var hideTarget: StoryGroup?   // "Hide Stories?" confirmation target
    /// The order the row had when the viewer opened, by group id. Latched on the way in, dropped on
    /// the way out, so nothing here survives to stale a later row.
    @State private var frozenOrder: [String] = []

    private let storySpacing: CGFloat = 10
    private let storyHPad: CGFloat = 12
    private var cardW: CGFloat {
        (UIScreen.main.bounds.width - storyHPad * 2 - storySpacing * 3) / 4
    }
    private var cardH: CGFloat { cardW * 1.46 }

    // Ordering: UNVIEWED first, then VIEWED — BOTH sorted by newest post first (never
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

    /// THE ROW HOLDS STILL WHILE A STORY IS OPEN, and that is not cosmetic.
    ///
    /// The order above re-sorts LIVE: the moment the last unseen story of the person you are
    /// watching is marked seen, their card leaves the unviewed group and slides right — while you
    /// are still inside their story. The close then flies home to the card's NEW place, which with
    /// a few people in the row is somewhere near the edge and can be off the screen entirely. That
    /// is his screenshot of a story leaving sideways: the animation was correct and the target had
    /// moved under it.
    ///
    /// Frozen by IDENTITY, not by value: the cards themselves stay live, so rings grey out and
    /// covers update as they always did. Only the ORDER is held, and only while a viewer is up.
    /// Anyone who posts while you are watching joins the end rather than being dropped. The re-sort
    /// then plays after the story is gone, which is when the big apps do it anyway.
    private var displayedOthers: [StoryGroup] {
        let live = orderedOthers
        guard freezeOrder, !frozenOrder.isEmpty else { return live }
        var byId: [String: StoryGroup] = [:]
        for g in live { byId[g.id] = g }
        let kept = frozenOrder.compactMap { byId[$0] }
        let keptIds = Set(kept.map(\.id))
        return kept + live.filter { !keptIds.contains($0.id) }
    }

    /// The one story each person will actually open on — their first UNSEEN item, which is where the
    /// viewer starts — falling back to their first if everything is watched. Warming the last item
    /// instead (the one the card's cover comes from) would warm the wrong end of the ring.
    private func prefetchFirstOfEachRing() {
        let items: [StoryPrefetcher.Item] = orderedOthers.compactMap { g in
            let s = g.stories.first(where: { !StoryPrefs.isStorySeen($0.id) }) ?? g.stories.first
            guard let s, !s.mediaUrl.isEmpty else { return nil }
            return StoryPrefetcher.Item(media: s.mediaUrl, poster: s.previewUrl, isVideo: s.isVideo)
        }
        StoryPrefetcher.prefetchFirsts(items)
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: storySpacing) {
                myCard
                    .id("my-story")   // STABLE identity so its "Add Story/Posted Stories" menu never binds
                                      // to a friend card when the row re-sorts (SwiftUI context-menu bug).
                ForEach(displayedOthers) { g in
                    // Each friend card is its OWN Equatable view so its long-press survives the row's
                    // re-renders (inline ForEach context menus only fired on the first card).
                    StoryFriendCard(cover: g.stories.last?.previewUrl,
                                    name: g.name.isEmpty ? "User" : g.name,
                                    avatar: g.photoUrl,
                                    seen: StoryPrefs.seenFlags(g.stories, upTo: g.lastViewedAt),
                                    cardW: cardW,
                                    onOpen: { onOpen(g) },
                                    onMessage: { onMessage(g) },
                                    onProfile: { onProfile(g) },
                                    onHide: { hideTarget = g },
                                    storyNS: storyNS,
                                    groupID: g.id)
                        .equatable()
                        .id(g.authorUid)   // explicit stable identity → its menu stays bound to this person
                }
            }
            .padding(.horizontal, storyHPad)
            .padding(.vertical, 10)
            // Smoothly slide cards to their new spots when a story moves unviewed -> viewed-front (no reload).
            // Keyed on what is DRAWN, not on the live sort: while a viewer holds the order still there is
            // nothing to animate, and the re-sort plays once — after the story has gone.
            .animation(.spring(response: 0.42, dampingFraction: 0.82), value: displayedOthers.map(\.id))
        }
        // Latch the order the moment a viewer opens, drop it the moment it closes. Nothing is kept
        // beyond that, so a later row can never inherit a stale one. See `displayedOthers`.
        .onChange(of: freezeOrder) { _, frozen in
            frozenOrder = frozen ? orderedOthers.map(\.id) : []
        }
        // WARM THE FRONT OF EACH RING WHILE THE ROW IS ON SCREEN.
        //
        // `StoryPrefetcher.prefetch(from:in:)` lives inside the viewer, so it can only warm what
        // comes after something already open — the FIRST tap was cold every time, and that is the
        // tap somebody decides whether this app is fast on. Instagram and WhatsApp both fill the
        // front of each ring off the list.
        //
        // Keyed on the ordered ids rather than a bare onAppear: the row re-sorts live as stories are
        // watched and as new ones land, and the ring that just moved to the front is exactly the one
        // worth having ready.
        .task(id: orderedOthers.map(\.id).joined()) { prefetchFirstOfEachRing() }
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
                    .matchedTransitionSource(id: "my-story", in: storyNS)   // hero source for the native zoom close
            } else {
                // Cover = last story, else the profile photo fills the card (user rollback
                // 2026-07-22: they prefer the full-photo look). No photo at all → centered circle.
                card(cover: repo.mine?.stories.last?.previewUrl ?? mePhoto,
                     name: "My Story", avatarName: meName, avatar: mePhoto,
                     seen: StoryPrefs.seenFlags(repo.mine?.stories ?? [], upTo: repo.mine?.lastViewedAt),
                     heroKey: repo.mine?.id, onBadge: onCompose) {
                    if let m = repo.mine { onOpen(m) } else { onCompose() }
                }
                // NATIVE context menu (build 181 look): My Story menu, lifting just the rounded card.
                .contextMenu {
                    Button { onCompose() } label: {
                        Label { Text("Add Story") } icon: { MenuIcon("ic_stories") }
                    }
                    Button { if let m = repo.mine, !m.stories.isEmpty { onOpen(m) } }
                        label: { Label("Posted Stories", systemImage: "circle.dashed") }
                } preview: {
                    coverImage(repo.mine?.stories.last?.previewUrl ?? mePhoto, name: "My Story",
                               avatarName: meName, avatar: mePhoto)
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

                // THE RING RUNS FOR THE WHOLE POST, both halves of it.
                //
                // ⚠️ DO NOT PUT THIS BACK ON `uploadPhase` (owner, 2026-08-06). It used to be drawn
                // only while `.preparing`, on WhatsApp's reasoning: once the bytes are ready this
                // person's own copy is finished and playable, and the upload that follows is for
                // everybody else. He has overruled that in as many words — "there should be no
                // moment where the loading indicator is hidden while the operation is still in
                // progress" — and he is right about what it looked like: the ring vanishing at the
                // hand-off reads as finished, and then the card sits there saying Adding… with
                // nothing moving, which reads as stuck.
                //
                // The two halves are still named differently in the label below. That was the part
                // worth keeping: one word for the wait that is holding you up, another for the one
                // that is not.
                UploadingAvatarRing(name: meName, photoUrl: mePhoto)   // my avatar + clean spinning ring
                    // The same shadow `card()` puts under every other circle in the row. Without it
                    // this one sat flat on the photo while its neighbours lifted off theirs, which is
                    // the last way the uploading circle differed from the one it turns into.
                    .shadow(color: .black.opacity(0.28), radius: 2, y: 1)
                    .padding(8)
            }
            // "Preparing…" is the honest word for the half that is actually holding them up, and it
            // is the one the big apps use. "Adding…" says the rest is happening without them.
            // "Uploading…", his word (2026-08-06). It said "Adding…", borrowed from WhatsApp's
            // "Adding status…", and he does not want it.
            Text(stories.uploadPhase == .preparing ? "Preparing…" : "Uploading…")
                .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).frame(width: cardW)
        }
        .frame(width: cardW)
        .animation(.easeInOut(duration: 0.2), value: stories.uploadPhase)
    }

    // avatarName: what the LETTER CIRCLE falls back to when there's no photo. The my-card's
    // label is "My Story" but its circle must use the user's real name — label-as-avatar-name
    // drew a purple "M" while Edit Profile drew the correct initial (user's device report).
    private func card(cover: String?, name: String, avatarName: String? = nil, avatar: String?, seen: [Bool],
                      heroKey: String? = nil,
                      onBadge: (() -> Void)? = nil, tap: @escaping () -> Void) -> some View {
        // Button (not onTapGesture) so the caller's .contextMenu long-press fires reliably.
        // Same dip as the friend cards; the compose fallback (nothing posted) gets it too, which
        // just reads as the tap answering.
        Button(action: { afterStoryDip(tap) }) {
        VStack(spacing: 6) {
            ZStack(alignment: .bottomLeading) {
                coverImage(cover, name: name, avatarName: avatarName, avatar: avatar,
                           addBadge: (onBadge != nil && seen.isEmpty) ? onBadge : nil)
                    .frame(width: cardW, height: cardH)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                if let onBadge, cover?.isEmpty == false {
                    // My Story with a filled cover (story preview OR profile photo): small avatar +
                    // ring + green + badge. With no stories the story ring is absent, so a clean white
                    // border makes the circle stand out against the (identical) photo behind it.
                    //
                    // THE WHITE-RING STATE ONLY (owner 2026-08-03, asked outright whether the change
                    // touched anything else: "are you sure to change only white circle"). A white ring
                    // around a face is the shape a POSTED story wears, so at story-ring size it read
                    // as one on a card with nothing posted. Shrunk, it reads as the add button it is.
                    //
                    // The moment there IS something posted, this card is showing a real story ring and
                    // must match everyone else's in the row — 32 with a 37 ring, same as the branch
                    // below. Sizing both states together was my first pass and it would have made his
                    // own posted ring smaller than his friends' for no reason.
                    // THE CIRCLE AND THE PLUS ARE THE SIZE THEY ALWAYS WERE, and the avatar is 32 in
                    // BOTH states so it matches every other story circle in the row exactly — his
                    // requirement, stated twice. Shrinking the avatar was my reading of "make it
                    // small" and it was wrong; what he was pointing at is the WHITE, not the picture.
                    //
                    // So only the two white circles are lighter: the ring around the avatar is a
                    // 1pt hairline instead of a 2pt band, and the white rim behind the plus hugs the
                    // glyph instead of standing 2pt off it. Together those were the heavy blob in
                    // the corner of the card.
                    AvatarView(name: avatarName ?? name, photoUrl: avatar, size: 32)
                        .overlay {
                            if seen.isEmpty {
                                Circle().strokeBorder(.white, lineWidth: 1)
                            } else {
                                StoryRingView(seen: seen).frame(width: 37, height: 37)
                            }
                        }
                        .overlay(alignment: .bottomTrailing) {
                            // DRAWN, NOT A SYMBOL, and only so the white rim can be 1pt like the ring
                            // above it (owner: "why is the badge white big, make it same like the
                            // avatar circle, don't change the + size").
                            //
                            // `plus.circle.fill` carries its own air inside its box, so a background
                            // disc padded 0.5 past that BOX showed two or three points of white past
                            // the black circle you can actually see. Box is not ink — the same thing
                            // that made the menu icons wrong. A circle we fill ourselves fills its
                            // frame exactly, so -1 is one point of white, measured from the edge you
                            // are looking at.
                            //
                            // Still 16pt, still black-on-white flipping in dark mode, still overhanging
                            // by 4. Only the white changed.
                            ZStack {
                                Circle().fill(Color.primary)
                                Image(systemName: "plus")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(Color(.systemBackground))
                            }
                            .frame(width: 16, height: 16)
                            .background(Circle().fill(Color(.systemBackground)).padding(-1))
                            .offset(x: 4, y: 4)
                                // high-priority so tapping + adds a story without triggering the card's open tap
                                .highPriorityGesture(TapGesture().onEnded { onBadge() })
                        }
                        .animation(.easeInOut(duration: 0.3), value: seen)
                        .shadow(color: .black.opacity(0.28), radius: 2, y: 1)
                        .padding(8)
                } else if onBadge == nil {
                    AvatarView(name: avatarName ?? name, photoUrl: avatar, size: 32)
                        .overlay { if !seen.isEmpty { StoryRingView(seen: seen).frame(width: 37, height: 37) } }
                        .animation(.easeInOut(duration: 0.3), value: seen)
                        .shadow(color: .black.opacity(0.28), radius: 2, y: 1)
                        .padding(8)
                }
            }
            // The hero flies to and from THIS rectangle — the card with its circle on it, the same
            // rule as a friend's card (see the note there). Absent for a card with nothing posted
            // (there is no story to open, so tapping it composes instead).
            .modifier(MediaRectReporter(id: heroKey ?? "", scope: .storyRow, cornerRadius: 24))
            Text(name).font(.system(size: 12)).lineLimit(1).frame(width: cardW)
        }
        .frame(width: cardW)
        .contentShape(Rectangle())
        }
        .buttonStyle(StoryCardDipStyle())
    }

    // addBadge (my card, NO stories yet): the reference app add-status look — a centered circle avatar (profile
    // photo or letter fallback) with the green + attached to its corner. Never a duplicated small
    // avatar (the "two Ms" bug), never the profile photo blown up as the card cover.
    @ViewBuilder private func coverImage(_ cover: String?, name: String, avatarName: String? = nil,
                                         avatar: String?, addBadge: (() -> Void)? = nil) -> some View {
        if let cover, !cover.isEmpty {
            StoryImage(url: cover)
        } else {
            ZStack {
                Color.secondary.opacity(0.2)
                // Roomy proportions (user polish 2026-07-22): the circle stays well clear of the card
                // edges — a near-edge circle + big badge read cramped, not pro.
                AvatarView(name: avatarName ?? name, photoUrl: avatar, size: cardW * 0.48)
                    .overlay(alignment: .bottomTrailing) {
                        if let addBadge { plusBadge(addBadge, size: 19).offset(x: 3, y: 3) }
                    }
            }
        }
    }

    private func plusBadge(_ action: @escaping () -> Void, size: CGFloat) -> some View {
        Image(systemName: "plus.circle.fill")
            .font(.system(size: size)).symbolRenderingMode(.palette)
            .foregroundStyle(Color(.systemBackground), Color.primary)   // black + badge (settings-icon color); flips white in dark
            // White rim (reference look): the badge is CUT cleanly into whatever it sits on,
            // instead of the raw black circle blending into the avatar ring where they meet.
            .background(Circle().fill(Color(.systemBackground)).padding(-2.5))
            .shadow(color: .black.opacity(0.25), radius: 1.5, y: 1)
            // high-priority so tapping + adds a story without triggering the card's open tap
            .highPriorityGesture(TapGesture().onEnded { action() })
    }

    func reload() { Task { await repo.load(force: true) } }
}

/// THE TAP DIPS THE CARD, AND THE STORY FLIES OUT OF THE DIP (owner 2026-08-07, Snapchat named:
/// "first do a small zoom-out animation, then smoothly zoom in again to directly open"). The dip
/// is the Button's own pressed state, so a held finger keeps the card pressed and the release
/// lets it spring back — nothing here is a canned sequence fighting the finger. The open is then
/// delayed one beat (`afterStoryDip`) so the dip reads even on the fastest tap. The flight seats
/// itself on the card's LIVE rectangle, wherever its spring-back has reached, and the open
/// crossfade fades in over the springing card, so the dip and the lift read as one motion.
private struct StoryCardDipStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.spring(response: 0.28, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// The beat between the tap and the open: long enough for the dip to be seen, short enough to
/// read as response rather than lag.
///
/// 0.1 → 0.06 on his "when i click story opening add slightly speed" (2026-08-07). This beat is
/// dead time — nothing moves except the 0.92 press, which the ButtonStyle is already animating on
/// its own spring and goes on animating underneath the open. Four hundredths is the cheapest speed
/// in the whole gesture, because it costs no motion at all, only waiting.
private func afterStoryDip(_ open: @escaping () -> Void) {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: open)
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
    let storyNS: Namespace.ID    // hero zoom: card ⇄ viewer
    let groupID: String          // matches the viewer's zoom sourceID

    static func == (l: StoryFriendCard, r: StoryFriendCard) -> Bool {
        l.cover == r.cover && l.name == r.name && l.avatar == r.avatar
            && l.seen == r.seen && l.cardW == r.cardW && l.groupID == r.groupID
    }

    private var cardH: CGFloat { cardW * 1.46 }

    var body: some View {
        Button(action: { afterStoryDip(onOpen) }) {
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
                // THE RECTANGLE THE STORY FLIES OUT OF AND LANDS BACK ON. On the card, not on the
                // enclosing VStack, or the landing would aim at a rectangle that includes the name
                // underneath and the story would seat itself low and too tall — the ZStack is
                // exactly the cover's frame, because the circle sits inside it.
                //
                // ON THE WHOLE CARD, CIRCLE INCLUDED, and that is the avatar half of his report. It
                // used to be on the photo alone, so the slot the story flies out of kept its little
                // avatar floating over an empty hole, and the flying card — which covers that slot
                // for the whole journey — took the circle away at the tap and gave it back at the
                // teardown. One rectangle leaves, the same rectangle comes home.
                .modifier(MediaRectReporter(id: groupID, scope: .storyRow, cornerRadius: 24))
                Text(name).font(.system(size: 12)).lineLimit(1).frame(width: cardW)
            }
            .frame(width: cardW)
            .contentShape(Rectangle())
        }
        .buttonStyle(StoryCardDipStyle())
        // NATIVE iOS context menu (build 181 look). Each card owns its menu built from its OWN
        // props, and the explicit `preview:` lifts just the rounded photo. The row is OUTSIDE the
        // chat List now (which was what collapsed per-card menus into one), so per-card native menus
        // work; the stable `.id(authorUid)` at the call site keeps each menu bound to its person.
        .contextMenu {
            Button { onMessage() } label: { Label("Send Message", systemImage: "message") }
            Button { onProfile() } label: { Label("Open Profile", systemImage: "person.crop.circle") }
            Button(role: .destructive) { onHide() } label: { Label("Hide Stories", systemImage: "archivebox") }
        } preview: {
            // Lift the card AS IT LOOKS — avatar ring included. A bare photo made the small
            // circle visibly vanish during the lift (user report).
            ZStack(alignment: .bottomLeading) {
                coverView
                    .frame(width: cardW, height: cardH)
                // WHOSE STORY THIS IS. The lift showed a photo and a ring and no name, so a long
                // press on the chat list told you less than the card you were pressing — the name
                // sits under the card normally, and the preview leaves the card behind. The archived
                // row's lift names the person and that is the one he wants.
                //
                // Over the picture rather than under it, because a preview is the card itself
                // enlarged and must not grow a caption the card never had. Scrim so a bright cover
                // cannot swallow the text.
                HStack(spacing: 8) {
                    AvatarView(name: name, photoUrl: avatar, size: 32)
                        .overlay { if !seen.isEmpty { StoryRingView(seen: seen).frame(width: 37, height: 37) } }
                        .shadow(color: .black.opacity(0.28), radius: 2, y: 1)
                    Text(name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .shadow(color: .black.opacity(0.55), radius: 3, y: 1)
                }
                .padding(8)
            }
            .frame(width: cardW, height: cardH)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
        // "story-" prefix so the top card's source id is NOT the raw group id (which is ALSO the
        // story viewer's destination identity). Without the prefix, SwiftUI's zoom auto-matched the
        // destination to this card even when it was scrolled off-screen, overriding the explicit
        // chat-row source ("row-<cid>") and anchoring the zoom to the wrong (top, hidden) avatar.
        .matchedTransitionSource(id: "story-\(groupID)", in: storyNS)   // hero grow source
    }

    @ViewBuilder private var coverView: some View {
        if let cover, !cover.isEmpty {
            StoryImage(url: cover)
        } else {
            ZStack { Color.secondary.opacity(0.2); AvatarView(name: name, photoUrl: avatar, size: cardW * 0.62) }
        }
    }
}


// MARK: - Story Viewer

// Full-screen story viewer: thin progress bars at top, story-style header and
// bottom reply bar, tap-right = next / tap-left = back, hold = pause, swipe-down = close.
// Full-screen story viewer — now powered by the StoryUI library (MIT) for its native swipe,
// progress bars, tap-to-advance, hold-to-pause and reply/emoji bar. We map our StoryGroups into
// StoryUI's models and route replies/emoji/like back to the author as a DM (our existing behavior).
// NOTE: report-story / delete-my-story from inside the viewer are not exposed by StoryUI (do those
// from the story row's long-press instead). `StoryUI.Story` is qualified to avoid colliding with
// our own `Story` type.
struct StoryViewer: View {
    // Presentations WITHOUT the zoom transition (story opened from a chat reply-quote) have no
    // native interactive dismiss — the library's own swipe-down pan closes them instead. False
    // everywhere the zoom hero exists (the two dismissals would race — device-proven).
    let ownSwipeDismiss: Bool
    /// OUR OWN open and close, built on the card the viewers sheet already moves, flying to and from
    /// the rectangle the story was opened from. Replaces Apple's zoom transition wherever it is on:
    /// the two cannot coexist, because the zoom brings its own interactive dismissal.
    ///
    /// Only the stories row at the top of the chat list passes true so far. Everywhere else still
    /// opens with the zoom, which is deliberate — the owner asked for one surface to be made right
    /// before it is spread.
    var heroDismiss: Bool = false
    /// The key of the rectangle this was opened from, in `MediaOpenRects` (`.storyRow` scope).
    var heroSourceKey: String = ""
    /// False for a REFEED — the delete-with-stories-remaining swap, where the presenter replaces
    /// the viewer while the screen is already up and at rest. There is nothing to fly and no wall
    /// to paint: `stageHeroOpen` marks the open spent and shows the story where it stands, instead
    /// of replaying a grow-out-of-the-row nobody's finger asked for.
    var heroStageOpen: Bool = true
    /// Take the cover away with NO dismissal animation of its own. The card has already flown home
    /// by the time this runs; letting the cover animate as well would play a second, different
    /// close over the top of the one the finger just drew.
    var onHeroClose: (() -> Void)?
    let groups: [StoryGroup]
    var startIndex: Int = 0
    var onClose: () -> Void
    var onProfile: (StoryGroup) -> Void = { _ in }   // tap the story header → that user's profile
    var onDeletedRemaining: (StoryGroup) -> Void = { _ in }   // deleted an item but more of mine remain → re-feed
    @State private var isPresented = true
    @State private var sentToast = false   // "Sent" confirmation after a reply
    // Owner controls (my own story): Views/reactions/delete bar instead of the reply bar.
    @State private var currentBucketUid = ""
    @State private var currentStoryId = ""
    @State private var barViewers: [StoryViewerInfo] = []
    @State private var showViewers = false
    @State private var viewersProgress: CGFloat = 0   // 0 sheet closed … 1 open; drives BOTH layers
    @State private var openDragging = false           // kept: read by the storyLayer opacity/hit-test
    // THE ARBITER IS GONE, because the race it refereed is gone. It existed for three SwiftUI
    // `DragGesture`s writing one progress with three stale-able anchors. Every drag is a UIKit pan
    // inside StoryViewersSheetView now, location-partitioned so ONE recognizer owns any given
    // touch, and UIKit delivers .cancelled reliably — there is nothing left to arbitrate. The
    // sheet reports "a finger owns progress" through this box instead (a class in @State: writing
    // it never invalidates the view, so no re-render mid-gesture).
    final class FingerBox { var down = false }
    @State private var sheetFinger = FingerBox()
    @State private var progressWatchdog: Task<Void, Never>?   // parked-sheet self-heal (see onChange below)

    // Drives `viewersProgress` frame-by-frame with a display-link spring instead of
    // withAnimation. With withAnimation the MODEL value jumps to the target instantly and
    // only the animatable modifiers interpolate — every step function derived from progress
    // (mount the morph card, swap to the carousel) fired at commit time, mid-spring, which
    // made a no-crossfade design impossible. Here model == presentation on every frame, so
    // thresholds are exact. Class in @State: writes never invalidate the view by themselves.
    final class SheetProgressAnimator {
        private var link: CADisplayLink?
        private var target: CGFloat = 0
        private var velocity: CGFloat = 0
        private var current: CGFloat = 0
        private var write: ((CGFloat) -> Void)?
        private var completion: (() -> Void)?
        /// PER ANIMATOR, because the sheet and the hero want different answers and used to share one.
        ///
        /// The sheet keeps 340 and its tight finish: it was tuned against Telegram's and he signed it
        /// off. The HERO does not — he timed the open at 0.51s and the maths agrees exactly
        /// (`t = 9.2 / sqrt(340) = 0.50s`), because a critically damped spring spends its last quarter
        /// second delivering the final one percent. The eye is done at 0.25s and the rest reads as the
        /// card hanging.
        private let k: CGFloat
        /// How close is close enough to stop. Chasing 0.001 is what made that tail; the hero stops at
        /// a distance nobody can see on a card that size.
        private let settleEpsilon: CGFloat

        init(stiffness: CGFloat = 340, settleEpsilon: CGFloat = 0.001) {
            self.k = stiffness
            self.settleEpsilon = settleEpsilon
        }

        /// `velocity` is the finger's release velocity in progress-units/sec (+ = opening), handed
        /// straight to the spring so a flick continues at the speed it was thrown instead of
        /// restarting from rest. (Telegram animates with a fixed 0.4s ease-out and hides the
        /// discontinuity with additive animations; a spring fed the real velocity is the same feel
        /// with a scalar we own.)
        /// Per-RUN overrides on top of the per-animator numbers: the hero's open wants a softer,
        /// longer-tailed spring than its close (see `stageHeroOpen`), and two more animator
        /// instances would mean two more things to remember to cancel on a drag's `.began`.
        private var runK: CGFloat = 340
        private var runEpsilon: CGFloat = 0.001
        func animate(from: CGFloat, to: CGFloat, velocity initialVelocity: CGFloat = 0,
                     stiffness: CGFloat? = nil, settle: CGFloat? = nil,
                     write: @escaping (CGFloat) -> Void, completion: (() -> Void)? = nil) {
            cancel()
            runK = stiffness ?? k
            runEpsilon = settle ?? settleEpsilon
            current = from; target = to; velocity = initialVelocity
            self.write = write; self.completion = completion
            let l = CADisplayLink(target: self, selector: #selector(tick(_:)))
            l.add(to: .main, forMode: .common)
            link = l
        }
        func cancel() { link?.invalidate(); link = nil; write = nil; completion = nil }
        @objc private func tick(_ l: CADisplayLink) {
            let dt = CGFloat(min(l.targetTimestamp - l.timestamp, 1.0 / 30.0))
            // Critically damped, so it arrives without overshooting. `k` is per animator now — see
            // the property. 340 is interactiveSpring(response: ~0.34); 631 is Signal's own story
            // transition spring, `response: 0.25, damping: 1`, which expands to stiffness (2π/0.25)².
            let k = runK, settleEpsilon = runEpsilon
            velocity += (k * (target - current) - 2 * sqrt(k) * velocity) * dt
            current += velocity * dt
            if abs(target - current) < settleEpsilon, abs(velocity) < settleEpsilon * 20 {
                current = target
                write?(current)
                let done = completion
                cancel()
                done?()
                return
            }
            // A real release velocity can carry the spring a hair past its target for a frame;
            // progress is a 0…1 fraction everywhere downstream, so never publish outside it.
            write?(max(0, min(1, current)))
        }
    }
    @State private var sheetAnimator = SheetProgressAnimator()
    @State private var confirmDelete = false
    @State private var shareImg: StoryImagePayload?     // … → Share (system sheet)
    @State private var forwardImg: StoryImagePayload?   // … → Forward (chat picker)
    @State private var profileSheet: StoryGroup?        // tap the header → profile sheet OVER the story (paused)
    @State private var toastText = "Sent"               // reused for "Sent" (reply) and "Saved"
    @State private var dragDown: CGFloat = 0            // swipe-down amount → fade my overlays with the card
    // Horizontal carousel swipe in flight: all cards show + slide normally while the REAL
    // story steps aside; it takes the centre back once the swipe settles (identical pixels
    // at both hand-off moments = invisible swaps, and the swipe stays as smooth as ever).
    @State private var carouselInteracting = false
    /// The sheet's sideways page-drag, live per frame, in POINTS and signed. While it is non-zero
    /// the carousel draws the centre copy and slides the row with the panel, so the card's picture
    /// follows the finger instead of switching when the swipe commits.
    ///
    /// POINTS, and the carousel divides by its own `fullDist` — the same points-per-card its finger
    /// scroller uses. It was a fraction of the screen width, which made one whole width worth one
    /// card step while a finger on the row itself covers a card in about half that. So the row
    /// crawled at half speed behind the panel: his "when I swipe sheet viewer the window card is
    /// not working like when I'm using my finger".
    @State private var sheetPageDrag: CGFloat = 0
    /// The frame each of my VIDEO stories was actually showing the first time the sheet came up over
    /// it, by story id. The carousel draws this instead of the poster.
    ///
    /// The live card only occupies the centre slot while nothing is being swiped; the moment a swipe
    /// starts it steps aside (`StoryCardMorph.setHidden`) and the row draws its own card from
    /// `previewUrl`. For a video that url is the poster, which is second zero — so the picture in the
    /// slot jumped from the frame he was watching to the start of the clip at the first millimetre of
    /// every swipe. His report, and the last corner of the app where a video story still showed
    /// second zero.
    ///
    /// CAPTURED ONCE AND NEVER REFRESHED, which is his own instruction ("it should remain fixed and
    /// stable… keep the original cover"). Cleared when the viewer goes away.
    @State private var frozenCovers: [String: UIImage] = [:]
    /// The morph has no card to move. Only ever true when something upstream has gone wrong; it makes
    /// the story fade rather than sit there at full size under the sheet. See `driveMorph`.
    @State private var morphUnavailable = false

    // MARK: - The hero transition's live state
    //
    /// A CLASS, not `@State` scalars, and this is the whole reason the card can keep up with a
    /// finger. Every value in here is written on every frame of a drag, and a `@State` write
    /// invalidates the view — which would put a SwiftUI re-render of the entire viewer between the
    /// finger and the card, sixty times a second, on the one gesture whose whole requirement is that
    /// it not lag. The sheet's `FingerBox` is here for the same reason and says the same thing.
    ///
    /// The card itself is moved by `StoryCardMorph.apply`, which is a UIView transform: no layout
    /// pass, no re-inset, nothing for SwiftUI to do at all.
    final class HeroBox {
        var live = false                 // a drag or one of its animations owns the card
        /// The row card this flight is going to (or came from) is the one the cover was photographed
        /// from. False after swiping to somebody else: their card was never emptied and their
        /// picture is not on the cover, so that landing keeps the whole-card fade instead.
        var cover = false
        /// How much of the row card's own picture the flying card is wearing THIS FRAME, 0…1.
        ///
        /// A STORED VALUE, NOT A FUNCTION OF `f`, and that is his 2026-08-07 correction. Bound to
        /// the fraction, a long pull started the cross-fade under the finger — he wants the drag to
        /// show story A and nothing else, and the exchange to belong entirely to the snap that runs
        /// when he lets go. So the drag pins this at 0 and only a flight's own tick moves it.
        var coverAlpha: CGFloat = 0
        /// How much of the story's height is shaved to reach the row slot's shorter shape, 0…1.
        ///
        /// Same rule as `coverAlpha` and for the same reason: the drag pins it at 0 so what is in his
        /// hand is the whole picture, uniformly scaled and uncropped, and only a flight moves it.
        var crop: CGFloat = 0
        /// TRUE while the card is on its way OUT: a live drag, or a close that has committed.
        ///
        /// The surround (my own story's full-screen black, the owner footer, the reply bar) is taken
        /// away at once when this is set, instead of fading over the first 18% of the journey. False
        /// for an open and cleared by a cancel, both of which are arrivals and keep the fade.
        var exiting = false
        /// What the world was last told about the chrome outside the card (`storyFlightActive`).
        /// Tracked here rather than read back off `heroFlying` so the notification is posted exactly
        /// once per crossing, from the one place that knows the fraction.
        var chromeHidden = false
        /// The open has been STARTED, once, ever. Not the same as `live`, and that difference is a
        /// bug he filmed: `live` goes false when the flight FINISHES, so once the flight (0.3s) grew
        /// shorter than the ladder that starts it (0.55s), every remaining attempt saw "not flying,
        /// and I have both rectangles" and ran the whole open again. Two shakes, a second flight from
        /// the row card, and over black, because the first flight had already put the backing back.
        var staged = false
        var committing = false           // the close is running; nothing may cancel it now
        /// The close has actually handed the viewer off. Read by the watchdog in `commitHero`, which
        /// is there because `libraryPresented` swallows every close while `committing` is true: a
        /// flight that never lands would otherwise leave no way out of the screen at all.
        var closed = false
        var f: CGFloat = 0               // 0 = full screen, 1 = seated in the row card
        var center: CGPoint = .zero      // the card's centre this frame, window coords
        var alpha: CGFloat = 1
        var rest: CGPoint = .zero        // the card's centre at rest, window coords
        var anchor: CGRect = .zero       // the row card it flies to and from, window coords
        // The ends of whichever animation is running. One scalar drives them both (see heroAnimator).
        var fromF: CGFloat = 0, toF: CGFloat = 0
        var fromC: CGPoint = .zero, toC: CGPoint = .zero
        var fromA: CGFloat = 1, toA: CGFloat = 1
    }
    @State private var hero = HeroBox()
    /// TRUE while a hero open or close owns the card — the one thing about the flight that SwiftUI
    /// has to know, and therefore the one value that is @State rather than a field on `HeroBox`.
    ///
    /// It exists for my own story's black backing (see `storyLayer`). That layer is a SwiftUI view
    /// BEHIND the pager, not inside it, so the morph's UIKit transform does not move it: the card
    /// flew home over a full-screen black wall and the chat list only reappeared when the cover was
    /// finally taken away. His screenshots, twice, with the tab bar still showing underneath.
    ///
    /// Written ONCE per flight, at each end — never per frame. Everything that moves stays in
    /// `HeroBox` for the reason written on it.
    @State private var heroFlying = false
    /// One scalar, 0 → 1, driving the hero's open, its landing and its spring-back. Same display-link
    /// spring the sheet uses, on SIGNAL'S numbers rather than the sheet's: `response 0.25, damping 1`
    /// is stiffness (2π/0.25)² = 631, and it stops at a distance nobody can see. Together those take
    /// the flight from the 0.51s he measured to about 0.3s, which is what Signal's own story
    /// transition costs (0.2s grow + 0.1s cross fade).
    @State private var heroAnimator = SheetProgressAnimator(stiffness: 631, settleEpsilon: 0.004)
    /// How far the finger has to travel for the card to be fully seated in the row card. Generous on
    /// purpose: the shrink has to read as gradual under a slow drag, and the close commits long
    /// before this is reached.
    private static let heroDragSpan: CGFloat = 420
    // (`heroFade`, how much the story itself softened as it was pulled away, is GONE — 2026-08-07.
    // It was 0.22 and it is what he saw as the chat list showing through the story like glass. The
    // background giving way is `heroDimMax`'s job; the picture stays opaque.)
    /// The darkest the chat list gets under a story in flight. Judged against his Snapchat shots,
    /// where the list behind is dimmed well past half but never to black — you can still read it.
    private static let heroDimMax: CGFloat = 0.45

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
    private var isUploadingItem: Bool { StoriesService.isPending(currentStoryId) && uploadSvc.uploading }
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

    init(group: StoryGroup, ownSwipeDismiss: Bool = false,
         heroDismiss: Bool = false, heroSourceKey: String = "", heroStageOpen: Bool = true,
         onHeroClose: (() -> Void)? = nil,
         onClose: @escaping () -> Void,
         onProfile: @escaping (StoryGroup) -> Void = { _ in },
         onDeletedRemaining: @escaping (StoryGroup) -> Void = { _ in }) {
        self.init(groups: [group], startIndex: 0, ownSwipeDismiss: ownSwipeDismiss,
                  heroDismiss: heroDismiss, heroSourceKey: heroSourceKey, heroStageOpen: heroStageOpen,
                  onHeroClose: onHeroClose,
                  onClose: onClose, onProfile: onProfile,
                  onDeletedRemaining: onDeletedRemaining)
    }
    init(groups: [StoryGroup], startIndex: Int = 0, ownSwipeDismiss: Bool = false,
         heroDismiss: Bool = false, heroSourceKey: String = "", heroStageOpen: Bool = true,
         onHeroClose: (() -> Void)? = nil,
         onClose: @escaping () -> Void,
         onProfile: @escaping (StoryGroup) -> Void = { _ in },
         onDeletedRemaining: @escaping (StoryGroup) -> Void = { _ in }) {
        self.groups = groups
        self.startIndex = startIndex
        self.ownSwipeDismiss = ownSwipeDismiss
        self.heroDismiss = heroDismiss
        self.heroSourceKey = heroSourceKey
        self.heroStageOpen = heroStageOpen
        self.onHeroClose = onHeroClose
        self.onClose = onClose
        self.onProfile = onProfile
        self.onDeletedRemaining = onDeletedRemaining
    }

    /// Every story in this viewer, in the order they will actually be watched, one person after the
    /// next. FLATTENED ACROSS PEOPLE on purpose: the moment a story viewer is most likely to stall is
    /// the jump to somebody new, because nothing of theirs is warm. Signal crosses that boundary for
    /// the same reason (`ensureSubsequentItemsDownloaded`, the `contextAfter` loop).
    private var flatStories: [StoryUI.Story] { models.flatMap { $0.stories } }

    private func prefetchAhead(currentId: String) {
        let all = flatStories
        guard let i = all.firstIndex(where: { $0.id == currentId }) else { return }
        StoryPrefetcher.prefetch(from: i, in: all)
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
                        // The poster the story row already drew, so the viewer has something true to
                        // show blurred while the full-size media arrives instead of a grey block.
                        previewURL: s.previewUrl,
                        date: timeAgo(s.createdAt),
                        isLiked: StoryPrefs.isStoryLiked(s.id),   // heart stays red on reopen
                        // This flag decides WHERE THE VIEWER OPENS. The rule that reads it lives in
                        // the library now (`StoryDetailView.resumeIndex`): where the person was left
                        // in this session, else their first item with `isSeen == false`, else — for
                        // somebody fully watched — their newest when arriving backwards and their
                        // oldest when arriving forwards.
                        //  • MY OWN story: purely the real per-item seen flag (own items ARE marked
                        //    seen as I watch them), so a just-posted D opens on D. No watermark here,
                        //    so it tracks exactly what I actually viewed.
                        //  • A FRIEND's story: first genuinely unseen item, honoring the synced watermark
                        //    too (so after a reinstall it doesn't replay from item 0 — split brain).
                        isSeen: g.isMine
                            ? StoryPrefs.isStorySeen(s.id)
                            : (StoryPrefs.isStorySeen(s.id) || s.createdAt <= (g.lastViewedAt ?? .distantPast)),
                        // Video runs its REAL length (the player refines it from the loaded asset);
                        // photos keep the 5s standard.
                        duration: s.isVideo && s.duration > 0.5 ? s.duration : 5,
                        // ONE caption system: the library's, card-anchored. The host used to draw
                        // its own for the mine-only viewer, pinned 14pt above the PAGE bottom —
                        // written when the story filled the page (948a838), stranded when the story
                        // became a 9:16 card: it floated on the black gap ~35pt below the card,
                        // his "caption is incorrectly positioned too low". The library's captionView
                        // sits above the card's bottom edge (21c78c5), the same place friends'
                        // captions sit and the same place the editor's caption pill shows it.
                        caption: s.caption,
                        audience: audienceBadge(for: s, isMine: g.isMine),
                        config: StoryConfiguration(
                            // My own story shows NO reply bar (owner bar is overlaid instead).
                            // NO REPLY BAR FOR A STRANGER'S PUBLIC STORY (L3). A story reply is an
                            // ordinary 1:1 message, so the bar on a story reached from a profile was
                            // a direct line to somebody who never accepted you — on the one surface
                            // built for reach. `isFriend` is the same accepted-chat test the audience
                            // itself is built from, so the two cannot disagree about who counts.
                            storyType: g.isMine || !StoryContact.isFriend(g.authorUid)
                                ? .plain()
                                : (s.allowsReplies
                                    ? .message(config: StoryInteractionConfig(showLikeButton: true),
                                               emojis: [["😭", "😍", "🤣", "❤️", "😄", "🔥", "❤️‍🔥"]],
                                               placeholder: "Send message…")
                                    : .plain()),
                            mediaType: s.isVideo ? .video : .image
                        )
                    )
                }
            )
        }
    }

    var body: some View {
        // The modifier chain outgrew the Swift type-checker (CI: "unable to type-check in
        // reasonable time") — body is now three separately-checked pieces. Purely structural.
        lifecycleGlue(sheetsAndMenus(coreLayers))
    }

    private var coreLayers: some View {
        ZStack {
            // Solid black canvas behind the story while the viewers sheet is up (so the see-through
            // cover never shows the light chat list through the shrinking card = the "white" bug).
            // Fully OFF only at rest, so the swipe-down dismiss keeps its see-through look.
            Color.black.ignoresSafeArea()
                .opacity(showViewers ? 1 : 0)
            // BUILD 213 architecture (restored per user — the zoom that worked): the real story
            // just FADES OUT; the morph card in viewersBackdrop (ABOVE the story) does the visual
            // zoom by interpolating its FRAME with a StoryImage(fitBlur:) = image + blur. No
            // scaleEffect on the live story anywhere (that top-anchor scale was the break-out bug).
            storyLayer
            if showViewers { viewersBackdrop }
            // The viewers sheet is a SIBLING layer, NOT a system .sheet: a system sheet lives in
            // its own presentation layer and cannot drive a continuous transform on the story
            // behind it — that limitation is what pushed the old design to render story cards
            // INSIDE the sheet. Both layers share `viewersProgress`, so the drag and the release
            // spring stay perfectly in sync.
            if showViewers { viewersSheetLayer }
        }
    }

    private func sheetsAndMenus(_ v: some View) -> some View {
        v
        .sheet(item: $shareImg) { p in ActivityView(items: [p.image]) }
        .sheet(item: $forwardImg) { p in StoryForwardSheet(image: p.image, onSent: { flashSentToast() }) }
        .sheet(item: $profileSheet) { g in
            NavigationStack {
                ContactInfoView(cid: [me, g.authorUid].sorted().joined(separator: "_"),
                                name: g.name, photoUrl: g.photoUrl,
                                source: .story,   // no chat underneath → no Search/Wallpaper (audit)
                                isSelf: g.authorUid == me)
            }
            // FULL HEIGHT, not half (owner 2026-08-03: "if someone upload story then i open, then i
            // click his profile — open FULL profile sheet"). At `.medium` this profile has half a
            // screen to fit a page built around a full-width photo header: the header loses its room,
            // the name lands in the navigation bar's strip, and the story stack that lives in that
            // strip is drawn straight through it. That is the overlap in his screenshot, and it is
            // the symptom of the height rather than a bug in either piece.
            //
            // The drag indicator stays: pulling this down is how you get back to the story.
            .presentationDetents([.large])
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
        // `currentIsMine` ON ALL THREE, the same guard Hide, Report and Delete already carry. The
        // menu no longer offers them on someone else's story, but the menu is the part a modified
        // client replaces, and these three are the ones that take a story off the app for good.
        .onReceive(NotificationCenter.default.publisher(for: .init("storyActionSave"))) { _ in
            guard currentIsMine else { return }
            if currentStory?.isVideo == true { saveCurrentVideo(currentStory?.mediaUrl) }
            else { saveCurrentImage(currentStory?.mediaUrl) }
        }
        // Forward/Share pipelines are image-based (they re-encode a UIImage); on a video story they
        // would silently do nothing. Say so honestly instead — proper video forward/share comes later.
        .onReceive(NotificationCenter.default.publisher(for: .init("storyActionForward"))) { _ in
            guard currentIsMine else { return }
            guard currentStory?.isVideo != true else { flashSentToast("Not available for videos yet"); return }
            let u = currentStory?.mediaUrl
            Task { if let img = await loadCurrentImage(u) { forwardImg = StoryImagePayload(image: img) } }
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("storyActionShare"))) { _ in
            guard currentIsMine else { return }
            guard currentStory?.isVideo != true else { flashSentToast("Not available for videos yet"); return }
            let u = currentStory?.mediaUrl
            Task { if let img = await loadCurrentImage(u) { shareImg = StoryImagePayload(image: img) } }
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("storyActionHide"))) { _ in
            if !currentIsMine { StoryPrefs.setHidden(currentBucketUid, true); isPresented = false }
        }
        // "…" → Report (friend stories only): files a report doc for review (App Store 1.2).
        .onReceive(NotificationCenter.default.publisher(for: .init("storyActionReport"))) { _ in
            guard !currentIsMine, let s = currentStory else { return }
            Task { await StoriesService.shared.reportStory(s) }
            flashSentToast("Reported")
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
        // Fast downward flick: the system zoom-dismiss tends to bounce it back, so the
        // library's passive watcher asks us to commit — via the SAME native dismissal
        // (the zoom-back hero plays; no custom close animation involved).
        .onReceive(NotificationCenter.default.publisher(for: .init("storyForceClose"))) { _ in
            // Snappier zoom-back (user: sluggish): the dismissal follows this transaction.
            var t = Transaction(animation: .spring(response: 0.28, dampingFraction: 0.92))
            withTransaction(t) { isPresented = false }
        }
        // The still-UPLOADING placeholder is not a watchable story yet: ITS progress bar
        // pauses (user ask) so it can never tick away and auto-advance mid-upload. Leaving
        // it (or the upload finishing and swapping in the real item) resumes normally —
        // every other item keeps its usual timer.
    }

    private func lifecycleGlue(_ v: some View) -> some View {
        v
        // WARM THE MEMORY CACHE FOR THE STORY YOU ARE WATCHING, because that is the one whose card
        // you are about to pull up (owner 2026-08-03: the flash happens "only first time i enter
        // app… if i clear app then again i enter").
        //
        // That "only the first time" is the whole diagnosis. `StoryImage` already seeds itself from
        // MEMORY so a rebuilt card draws instantly — but memory starts empty on every cold launch,
        // and the photo is only on DISK. So the first pull of a session had nothing to seed from and
        // showed the skeleton; every pull after it was warm and fine.
        //
        // Reading it here rather than in the card is what keeps the gesture clean: this runs off the
        // main thread the moment a story appears, seconds before any finger arrives, where a
        // synchronous disk read inside the drag would trade his flash for a stutter.
        .task(id: currentStoryId) {
            guard let url = currentStory?.previewUrl, !url.isEmpty else { return }
            _ = await DiskImageCache.shared.image(for: url)
        }
        .onChange(of: isUploadingItem) { _, up in
            NotificationCenter.default.post(name: .init(up ? "pauseStory" : "resumeStory"), object: nil)
        }
        // (The arbiter's finger-beats-spring hook lives in the sheet's onDragActive now.)
        // Safety net: the sheet unmounting must NEVER leave a stray progress value behind
        // (a tiny leftover hid the owner footer with no sheet in sight — user screenshot).
        // THE SNAPSHOT MACHINERY IS GONE FROM HERE, and it had already stopped doing anything.
        //
        // This used to photograph every story offscreen the instant the sheet opened: one
        // full-screen `drawHierarchy(afterScreenUpdates: true)` per story on the MAIN THREAD,
        // staggered 0.12s apart, right through the opening spring. The only reader of what it
        // produced was `SnapshotCardContent`, and `21f3209` left that view unused, so since then it
        // has been a screen render per story per pull feeding a cache nobody looked at — a strong
        // candidate for the hitch the owner reported while the sheet comes up.
        //
        // Nothing replaces it. The card behind the sheet is the live story now, so there is nothing
        // left to photograph.
        .onChange(of: showViewers) { _, on in
            guard !on else { return }
            sheetAnimator.cancel(); viewersProgress = 0
            carouselInteracting = false
            // Same rule as driveMorph: a hero flight owns the card and this teardown must not
            // reset it out from under one.
            guard !hero.live else { return }
            // Full-screen, square, unmasked, visible. The sheet can be torn down from several paths
            // (close, dismiss, teardown) and a card left mid-transform would open the NEXT story
            // already shrunken.
            StoryCardMorph.shared.reset()
            NotificationCenter.default.post(name: .init("storyUnfreezeBlur"), object: nil)
        }
        // SELF-HEALING for a PARKED sheet (user video: sheet resting at ~73% open — story stuck
        // as a giant half-morphed card, carousel never faded in). Two ways to get parked: a
        // system-CANCELLED drag skips onEnded so no snap ever fires, and a stray touch during
        // the open spring kills the animator via the arbiter's fresh-claim hook. Every write
        // re-arms this; if progress then sits mid-air untouched for 0.8s — no finger writes,
        // no animator ticks — snap to the nearest rest state.
        .onChange(of: viewersProgress) { _, p in
            rearmProgressWatchdog(p)
            // The live story is driven from the SAME number as the sheet, on the same tick. During
            // the drag that number is written by the finger and during the release by the
            // display-link spring, so the story tracks both without an animation of its own.
            driveMorph(p)
            // ...and so is the caption, which fades out over the first third of the pull instead of
            // riding the card down into the slot still drawn (his circle). Posted RAW: the library
            // owns how its own chrome answers a pull, the same way it owns the caption's design.
            // Unconditional — this must keep arriving while the morph is unavailable and after the
            // sheet's own early-return paths, or the caption stays stuck at whatever it last heard.
            NotificationCenter.default.post(name: .init("storySheetProgress"), object: p)
            // Open enough that the card is showing the story properly: take its picture, once, so
            // the carousel has a true cover to draw when the live card steps aside. See frozenCovers.
            if p > 0.9 { captureFrozenCover() }
        }
        // The carousel row took over, or gave the centre back — by a finger on the row OR by the
        // sheet being thrown sideways (both slide cards through the slot, both need the copy).
        // See StoryCardMorph.setHidden.
        .onChange(of: carouselInteracting || sheetPageDrag != 0) { _, on in
            StoryCardMorph.shared.setHidden(on)
            // The swipe is over and the live card is back. Once the story underneath has finished
            // landing on the card he stopped at (the same beat `sheetStoryId`'s handler waits for
            // its re-freeze), photograph THIS story too, so the next swipe leaves a true cover
            // behind as well. A story already photographed is left alone — see frozenCovers.
            guard !on else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                guard showViewers, viewersProgress > 0.9,
                      !carouselInteracting, sheetPageDrag == 0 else { return }
                captureFrozenCover()
            }
        }
        // Safety net: never leave a story paused after the viewer goes away (the swipe-down dismiss posts
        // pauseStory and does not resume on commit; a sheet up at teardown can also skip the resume).
        .onDisappear {
            sheetAnimator.cancel()
            StoryCardMorph.shared.reset()   // never hand a transformed card to the next viewer
            NotificationCenter.default.post(name: .init("resumeStory"), object: nil)
            NotificationCenter.default.post(name: .init("storyChromeHidden"), object: false)
            // Same reason the chrome is restored here: a viewer torn down with the sheet still up
            // must not hand the next one a caption that is already faded out.
            NotificationCenter.default.post(name: .init("storySheetProgress"), object: CGFloat(0))
            NotificationCenter.default.post(name: .init("storyUnfreezeBlur"), object: nil)
            // The frozen covers belong to ONE viewing session. Kept across sessions they would be
            // bitmaps of frames nobody is watching any more, and the next open would show a cover
            // from the last one.
            frozenCovers.removeAll()
        }
        // Freeze the running story + progress while any sheet is shown over it; resume on dismiss.
        .onChange(of: sheetUp) { _, up in
            NotificationCenter.default.post(name: up ? .init("pauseStory") : .init("resumeStory"), object: nil)
        }
        // Viewers sheet: pause the moment it starts opening (progress > 0), resume only once fully
        // closed. This keeps the story frozen the entire time the sheet is up (fixes the auto-close).
        .onChange(of: viewersProgress > 0.01) { _, open in
            NotificationCenter.default.post(name: open ? .init("pauseStory") : .init("resumeStory"), object: nil)
        }
        // Chrome visibility MIRRORS the morph card: hidden while the card covers the story
        // (p ≥ 0.07-ish), visible the moment the story is exposed again. Completion-only
        // restores came back LATE (after the whole close spring) and some early-exit paths
        // never fired them at all — chrome stuck hidden forever (user screenshot).
        .onChange(of: viewersProgress < 0.15) { _, exposed in
            NotificationCenter.default.post(name: .init("storyChromeHidden"), object: !exposed)
        }
        // BULLETPROOF pause while the viewers sheet is open: reassert the freeze twice a second so the
        // story can NEVER creep forward and auto-advance/auto-close the sheet, even if some other event
        // resumed it meanwhile (the "sheet forcefully dismissed while reading it" bug). pauseStory just
        // sets hostPaused=true; re-setting a true @State is a no-op — no re-render, no gesture fights.
        .onReceive(Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()) { _ in
            // > 0.01 (not > 0.5): the freeze must hold through the ENTIRE close drag too — a story
            // resuming mid-collapse re-renders behind the moving sheet every tick and fights the
            // drag frame-by-frame (the violent "two views shaking" close). Resume still happens
            // via the viewersProgress onChange once the sheet is fully down.
            if showViewers && viewersProgress > 0.01 {
                NotificationCenter.default.post(name: .init("pauseStory"), object: nil)
            }
        }
        // NO host pause post during the swipe-DOWN dismiss drag — matching TestFlight build 210,
        // whose scroll-down-to-close the user confirmed as the correct one. The library already
        // pauses on its pan's own .began; this extra post only existed in 211+.
        // Carousel centred a different one of my stories while the sheet is up → advance the frozen
        // story underneath to match, so collapsing lands on that story with no photo-swap flash.
        .onChange(of: sheetStoryId) { _, id in
            guard showViewers, currentIsMine, !id.isEmpty else { return }
            NotificationCenter.default.post(name: .init("jumpToStoryItem"), object: id)
            // The jumped-to item arrives UNFROZEN (the stale-freeze fix clears it on URL change),
            // and its live blur misrenders under the sheet's scale — the centre card grew an
            // "extra blur" bar and the photo read as jumping (user report). Re-freeze once the
            // new item has rendered; the freeze uses the cached composite, so it's exact.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                guard showViewers else { return }
                NotificationCenter.default.post(name: .init("storyFreezeBlur"), object: nil)
            }
        }
        // The COVER'S OWN BACKING (not just an inner canvas) must be opaque black while the viewers
        // sheet is up — otherwise the .zoom transition composites the clear backing over the inner
        // black canvas and the light Chats list bleeds through as the "white" bug. Clear only at rest,
        // so the swipe-DOWN dismiss still reveals the Chats list sliding behind the story.
        // BLACK ALWAYS, NOT ONLY WHILE THE SHEET IS UP.
        //
        // It was `Color.black.opacity(showViewers ? 1 : 0)`, clear at rest, and the reason given was
        // that a see-through cover let the Chats list show behind a swipe-down. That was written for
        // our own dismiss, which no longer runs here.
        //
        // What clear actually gets you now is his screenshot: a WHITE band along the top edge of the
        // shrinking card. The library clears the page's black the instant a finger goes down, so only
        // the card pulls away — and underneath that black is this backing, which when clear is the
        // cover's default, white in light mode. Black is what the card already wears above the story
        // at rest, so the strip stops being visible at all.
        .presentationBackground(Color.black)
        // TELL THE PRESENTATION TO STAND DOWN, instead of arguing with its recogniser.
        //
        // His report: sometimes a downward drag over an OPEN sheet closes the whole viewer instead
        // of the sheet. The rule has been right for a long time and the enforcement has not — the
        // cover is presented with `.navigationTransition(.zoom)`, whose interactive drag-to-dismiss
        // is UIKit's, and every attempt so far has been made from inside the sheet's own view:
        // `require(toFail:)` (disproved on device, build 466) and then switching foreign pans off
        // by hand (`suspendForeignPans`). Both are archaeology on somebody else's recogniser, and
        // both have the same hole — they run when the sheet MOUNTS and when one of OUR pans begins,
        // so a system pan created lazily in between, or a drag our own gates deliberately refuse
        // (a sideways-ish one in the carousel band), is a drag nobody suspended. That is the
        // "sometimes".
        //
        // This is the documented API for the exact question, and UIKit asks it BEFORE it will begin
        // an interactive dismissal, so there is no recogniser to lose a race with and nothing to
        // re-scan. `suspendForeignPans` stays: it also stops other foreign pans riding along, and
        // this is the belt to its braces rather than a replacement.
        //
        // Released the moment the sheet is genuinely down, so the swipe-down dismiss AT REST is
        // still Apple's zoom-back hero — which is the behaviour he signed off and must not change.
        .interactiveDismissDisabled(showViewers && viewersProgress > 0.02)
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
                // The caption overlay that hung HERE is gone: it anchored to the PAGE bottom and
                // was stranded ~35pt under the card when the story shrank to 9:16 — see the
                // caption note at the model builder. The library's card-anchored captionView
                // draws my caption now, exactly as it draws a friend's.
                storyContent
                    // NO app-level CLIP (the clip pinned the card and broke the native dismiss) — the
                    // card's corners are rounded in UIKit inside the library now. But KEEP a solid black
                    // background: the cover is see-through (.clear) for the swipe-down, so without this
                    // the light chat list shows through as a WHITE story. A background (unlike a clip)
                    // doesn't pin the card, so the library dismiss stays smooth.
                    //
                    // AND IT STEPS ASIDE FOR A HERO FLIGHT. This layer is a SwiftUI view behind the
                    // pager, so the morph — a UIView transform on the pager's own card — cannot move
                    // it: it stayed full screen and opaque while the card flew, and what he saw was
                    // his story shrinking into the row over a black wall, with the chat list only
                    // arriving once the cover was gone ("it has that black background still, then
                    // after a bit it will go"). The library's own swipe-down does not need this
                    // because it slides the WHOLE page, black included, off the screen as one thing.
                    //
                    // Only during the flight. At rest the card does not fill the screen — the strip
                    // above it and the footer's surround are this black, and dropping it there would
                    // put the chat list back in the very gaps it was added to cover.
                    .background(Color.black.opacity(heroFlying ? 0 : 1))
                ownerFooter
                    // Hidden on swipe-down AND while the sheet is REALLY engaged (showViewers
                    // gate: a stray leftover progress value once hid the Views/Delete bar with
                    // no sheet in sight — the tab bar showed through the empty strip).
                    //
                    // AND FOR THE WHOLE HERO FLIGHT, not just for a drag. It paints its own black
                    // (`ownerFooter`) and it is outside the card, so on a BUTTON close — where
                    // `dragDown` never moves — it hung on at the bottom of the screen as a black
                    // bar while the card flew home over the chat list.
                    .opacity((heroFlying || dragDown > 6 || (showViewers && viewersProgress > 0.05)) ? 0 : 1)
                    .animation(.easeOut(duration: 0.15), value: dragDown > 6)
                    .animation(.easeOut(duration: 0.15), value: heroFlying)
                    .animation(.easeOut(duration: 0.15), value: showViewers && viewersProgress > 0.05)
            } else {
                // Friend's story: full-bleed, NO clip → the library's swipe-down dismiss works.
                storyContent
            }
        }
        // NO app-level drag gesture on the story anymore. BOTH directions are the library's native
        // UIKit pans: swipe-DOWN → dismiss (smooth, same as friends), swipe-UP → onSwipeUp → openViewers.
        // An app gesture here fought the library's swipe-down pan and broke the dismiss.
        // THE STORY DOES NOT FADE ANY MORE, and there is deliberately no SwiftUI modifier here that
        // moves or scales it. It shrinks into the card slot as a UIKit transform on the pager's own
        // card, applied by `driveMorph` through `StoryCardMorph` — the same view, the same way, that
        // the swipe-down dismiss has always transformed.
        //
        // Read the two reverted attempts before changing this. `c938ad8` scaled the live story with
        // `.scaleEffect(anchor:)` and `da0bc72` tore it out again: "every version scaled the LIVE
        // story with scaleEffect ... = the top break-out". A SwiftUI scale re-lays-out the hosted
        // representable and re-insets it against the safe area, which is how the top edge escaped. A
        // UIView transform changes no bounds and runs no layout pass, so that failure cannot recur —
        // but a `.scaleEffect` added back here would bring it straight back.
        //
        // THE FADE IS BACK ONLY AS A SAFETY NET, never as the normal path. It applies when, and only
        // when, the morph has no card to move — see `driveMorph`. Opacity is not a transform and
        // cannot re-inset anything, so it does not reopen the break-out this file spent two reverts
        // escaping.
        .opacity(morphUnavailable && viewersProgress > 0.08 ? 0 : 1)
        // NO app-level swipe-down transform anymore. The card is dismissed by the library's native UIKit
        // pan (moves the view directly = friend-smooth), so the app never offsets/scales the pager.
        .allowsHitTesting(viewersProgress == 0 || openDragging)
        // NO app-level SwiftUI gesture on the story AT ALL anymore. A SwiftUI DragGesture activates
        // after its minimumDistance in ANY direction (the direction guard runs only inside onChanged),
        // and its ACTIVATION cancels the touches of the hosted UIKit views — frame-measured on device:
        // every slow swipe-down tracked ~20-30pt (≈ the 14pt activation + latency) then got cancelled
        // and sprang back, over and over. Swipe-UP is now the library's own DirectionalPan (.up) again
        // (swipeUpEnabled: true below): it never fired historically because its direction test had
        // inverted signs — fixed — and being direction-locked it FAILS cleanly on a downward drag, so
        // the down dismiss pan can never be starved or cancelled by it.
        .ignoresSafeArea()
        // NOTE: do NOT add a .clipShape here to round the story during the pull — a clipShape after
        // ignoresSafeArea re-insets to the SAFE-AREA bounds, so the status-bar + home-indicator strips
        // stopped being covered and the clear cover showed the chat list through them (white top/
        // bottom bug). The rounded corners during the pull are handled by the morph card, which now
        // pops opaque from p≈0 and covers the story's square corners anyway.
    }

    private var storyContent: some View {
        StoryView(
            stories: models,
            selectedIndex: startIndex,
            isPresented: libraryPresented,
            userClosure: { story, message, emoji, isLiked in
                handle(storyId: story.id, message: message, emoji: emoji, isLiked: isLiked)
            },
            onProfile: { user in
                // Open the profile OVER the story (paused) — do NOT close the viewer.
                if let g = groups.first(where: { $0.authorUid == user.id }) { profileSheet = g }
            },
            // Landing on a person no longer greys their whole ring — seen state advances per ITEM
            // below (the standard rule: the ring stays colored until every story is watched).
            onUserChanged: { uid in currentBucketUid = uid; loadBarViewers() },
            onItemSeen: { id in
                currentStoryId = id
                // DOWNLOAD WHAT IS COMING WHILE THIS ONE PLAYS. Signal fires this on every item
                // change rather than only when a person's stories run out, and keeps THREE ahead —
                // see StoryPrefetcher for the rule and where it is written down.
                prefetchAhead(currentId: id)
                // The synthetic still-uploading item has no real doc — don't persist it as "seen"
                // (junk entry) or fetch its (non-existent) viewers.
                guard !StoriesService.isPending(id) else { return }
                StoryPrefs.markStorySeen(id)
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
                // Same gate as `openViewers`: an uploading placeholder has no viewers to show.
                guard !isUploadingItem else { return }
                sheetAnimator.cancel()   // the finger owns progress; kill any in-flight snap
                let sheetH = UIScreen.main.bounds.height * StoryViewersSheetView.heightFraction
                if !showViewers {
                    sheetStoryId = targetStoryId; showViewers = true
                    // Freeze the story the INSTANT the sheet starts to open (don't wait for the
                    // progress>0.01 onChange) so it can never advance/auto-close under the sheet.
                    NotificationCenter.default.post(name: .init("pauseStory"), object: nil)
                    // Freeze the blurred backdrop AS IT LOOKS RIGHT NOW (user spec: the pull-up
                    // must keep the exact pre-pull blur, never re-compute it at the smaller size).
                    NotificationCenter.default.post(name: .init("storyFreezeBlur"), object: nil)
                    // Chrome-only exit: progress bar / avatar / name / scrim fade via the library;
                    // the story IMAGE never animates (user spec: no flash, no re-render).
                    NotificationCenter.default.post(name: .init("storyChromeHidden"), object: true)
                }
                openDragging = true   // keep the storyLayer visible/hit-testable through the drag
                viewersProgress = max(0, min(1, up / sheetH))
            },
            onSwipeUpEnded: { translation, velocity in
                guard currentIsMine || mineOnly else {
                    // Friend's story: a swipe UP opens the reply keyboard (like tapping the reply
                    // pill). StoryUI's MessageView focuses its TextField on this notification.
                    openDragging = false
                    if translation > 40 || velocity > 300 {
                        NotificationCenter.default.post(name: .init("focusStoryReply"), object: nil)
                    }
                    return
                }
                openDragging = false
                guard viewersProgress > 0 else {
                    // Engaged but the sheet never actually rose: undo the engagement posts, or
                    // the chrome stays hidden forever (no close path will ever run) — and the
                    // mount itself (audit C2: a stuck showViewers kept the cover's backing black
                    // and skipped pause/freeze on the NEXT swipe-up).
                    showViewers = false
                    NotificationCenter.default.post(name: .init("storyChromeHidden"), object: false)
                    NotificationCenter.default.post(name: .init("storyUnfreezeBlur"), object: nil)
                    NotificationCenter.default.post(name: .init("resumeStory"), object: nil)
                    return
                }
                let sheetH = UIScreen.main.bounds.height * StoryViewersSheetView.heightFraction
                // Telegram's open rule, in points (viewListDismissPanGesture .ended): commit past
                // 200pt of pull, or past 100pt with 100pt/s of speed behind it. The finger's
                // velocity rides into the spring, so a flick's sheet arrives at flick speed.
                if translation > 200 || (translation > 100 && velocity > 100) {
                    sheetAnimator.animate(from: viewersProgress, to: 1, velocity: velocity / sheetH,
                                          write: { viewersProgress = $0 })
                } else {
                    closeViewers(velocity: velocity / sheetH)
                }
            },
            dismissEnabled: ownSwipeDismiss && !heroDismiss,
                                               // zoom presentations: Apple's dismiss ONLY (user's final call);
                                               // reply-quote presentations have no zoom — the library pan closes;
                                               // hero presentations: our own, and it takes precedence
            swipeUpEnabled: true,  // library's DirectionalPan(.up) owns swipe-up: with the direction-sign
                                   // fix it fires reliably, and it FAILS cleanly on downward drags — unlike
                                   // the removed SwiftUI DragGesture whose activation cancelled the down pan
            heroDismiss: heroDismiss,
            onHeroDrag: { phase, t, v in onHeroDrag(phase, t, v) }
        )
        // The card is attached at a different moment in each of the two hosts and is in a window at
        // neither of them, so the open waits for real geometry rather than for an event. See
        // `stageHeroOpen`. A no-op unless this presentation owns its own transition.
        .onAppear {
            stageHeroOpen()
            // A FRESH VIEWER NEVER STARTS PAUSED, whatever the last one left behind.
            //
            // His report: post a story, open it, leave, open it again — and it sits there paused.
            // The pause is a notification, and there are several places that post `pauseStory` and
            // rely on something else posting `resumeStory` later: the dismiss watcher pauses on the
            // drag's `.began` and only resumes on the branches where the drag was ABANDONED, and the
            // sheet's watchdog reasserts a pause twice a second while it is up. A close that
            // committed, or a drag that never delivered an end, leaves the last word as "paused".
            //
            // This is a BACKSTOP, not a diagnosis, and it is worth being straight about that: I have
            // not proved which of those paths leaves it stuck. But "a viewer that has just been
            // opened is playing" is unconditionally true, so asserting it on mount is safe no matter
            // which one it was — the same reasoning as the bulletproof pause the sheet already does,
            // pointed the other way.
            NotificationCenter.default.post(name: .init("resumeStory"), object: nil)
        }
        // REPLIES ARE OFF: SAY SO, rather than showing nothing.
        //
        // A story whose author turned replies off maps to `.plain()`, which draws no bar at all —
        // so the screen simply ended below the card and there was no way to tell a story you may
        // not answer from one that never had a bar. His design says it outright.
        //
        // Drawn by the host, not the library: it is a statement about OUR permission rule, the
        // library has no idea replies can be refused, and adding a whole story type to say one
        // sentence would be the wrong place to put it.
        //
        // Same three conditions the reply bar itself is built from, so the pill appears exactly
        // where a bar would have been and never anywhere else: somebody else's story, somebody you
        // actually have a chat with, and replies refused.
        .overlay(alignment: .bottom) {
            if !currentIsMine,
               StoryContact.isFriend(currentBucketUid),
               currentStory?.allowsReplies == false {
                Text("You can't reply to this story 🔒")
                    .font(.system(size: 16))
                    .foregroundStyle(.white.opacity(0.55))
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(Capsule().stroke(.white.opacity(0.28), lineWidth: 1))
                    .padding(.horizontal, 16)
                    .padding(.bottom, max(10, bottomInset))
                    // Steps aside for the same three things every other piece of chrome does: the
                    // close drag, a hero flight (a button close moves no finger), and the viewers
                    // sheet coming up over the card.
                    .opacity((heroFlying || dragDown > 6 || (showViewers && viewersProgress > 0.05)) ? 0 : 1)
                    .animation(.easeOut(duration: 0.15), value: dragDown > 6)
                    .animation(.easeOut(duration: 0.15), value: heroFlying)
                    .allowsHitTesting(false)   // it is a statement, not a control
            }
        }
        // Exotic safety net: my story inside a MIXED feed (not the normal flow) still gets the
        // old gradient overlay bar, since the footer layout is only applied to mine-only feeds.
        .overlay(alignment: .bottom) {
            if currentIsMine && !mineOnly {
                ownerBar
                    .opacity((heroFlying || dragDown > 6) ? 0 : 1)
                    .animation(.easeOut(duration: 0.15), value: dragDown > 6)
                    .animation(.easeOut(duration: 0.15), value: heroFlying)
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

    /// THE CARD SLOT, worked out in ONE place.
    ///
    /// Three things have to agree on this rectangle to the pixel: the carousel that lays the cards
    /// out, the live story that shrinks into the centre one, and the sheet whose height defines the
    /// free space above them. It used to be written out three times — `morphGeometry`, `tgZoom` and
    /// inline in `viewersBackdrop` — and two of those three had gone stale AND unused, left behind
    /// when `da0bc72` reverted the scaleEffect zoom. Duplicated geometry that has to agree is
    /// exactly what produced the picture-jumping-inside-its-frame bug in `402ec4d`.
    private struct CardSlot {
        let w: CGFloat          // card width
        let h: CGFloat          // card height, deliberately shorter than aspect-true (see below)
        let miniH: CGFloat      // full mini-screen composite height; the card shows a `h` window of it
        let top: CGFloat        // the card block's top edge on screen
        var centerY: CGFloat { top + h / 2 }
    }

    private var cardSlot: CardSlot {
        let scr = UIScreen.main.bounds
        let sheetH = scr.height * StoryViewersSheetView.heightFraction
        let avail = scr.height - sheetH - topInset          // free area above the open sheet
        // Card block = the centred card + the big count row (~40) below it, centred vertically in
        // the free space with the status bar cleared. The narrow slot is what makes the neighbours
        // sit clearly off-centre so their scale-down actually reads.
        let countArea: CGFloat = 40
        let contentH = scr.height - (mineOnly ? Self.ownerFooterHeight + max(10, bottomInset) : 0)
        // BUILD 249 card size (user: "make it exactly like 249, 250 is too long"). `slotHRef` is the
        // aspect-true reference and it DEFINES the width, so the card keeps its width and only loses
        // height; the story is centre-cropped into what is left.
        let slotHRef = (avail - countArea) * 0.94
        let w = slotHRef * (scr.width / max(contentH, 1))
        let h = slotHRef * 0.88
        return CardSlot(w: w, h: h, miniH: w * (scr.height / scr.width),
                        top: topInset + (avail - countArea - h) / 2)
    }

    /// Put the LIVE story where the drag says it should be. This is the whole of the frozen-frame
    /// fix.
    ///
    /// There is no picture of the story any more. The real view shrinks into the slot with its
    /// player paused where it stands, so a video you are 21 seconds into shows second 21 — it is
    /// still the same layer drawing it, and nothing is swapped for anything at any point. See
    /// `StoryCardMorph` for why this is a UIKit transform and not the SwiftUI `.scaleEffect` that
    /// was reverted twice.
    ///
    /// The rectangle handed over is the SAME frame interpolation the deleted morph card used, so the
    /// motion the owner already signed off is unchanged; only the pixels inside it are real now.
    /// Photograph the live card for the story the sheet is on, if it is a video and has not been
    /// photographed already. See `frozenCovers` for why only videos and why only once.
    private func captureFrozenCover() {
        guard showViewers, frozenCovers[sheetStoryId] == nil, !sheetStoryId.isEmpty else { return }
        let live = StoriesRepository.shared.mine?.stories ?? myStories
        guard let s = live.first(where: { $0.id == sheetStoryId }), s.isVideo else { return }
        // A photo's poster IS the photo, so the row's own card already matches and a snapshot would
        // only be a second, staler copy of it.
        guard let shot = StoryCardMorph.shared.snapshotCard(width: cardSlot.w) else { return }
        frozenCovers[sheetStoryId] = shot
    }

    /// THE LINE UNDER THE NAME: which audience this story went to.
    ///
    /// Per story, so an author with ten stories up can tap through them and watch the label change
    /// (his request, 2026-08-06, with three reference screens).
    ///
    /// ⚠️ THE NAME OF A CUSTOM STORY IS THE AUTHOR'S ALONE. Everybody else is told the TYPE and
    /// nothing more — his rule, stated twice: "only you can see the name of this story", and "they
    /// should not see any private details beyond the audience type". It holds by construction rather
    /// than by care, because the name is not in the story document at all; it lives on the author's
    /// own device (`StoryPrefs.audienceName`) and there is nothing here for anybody else to read.
    ///
    /// Everyone deliberately does NOT wear the profile photo, which is his other instruction on this
    /// screen ("do not use the profile picture as the audience icon, use the dedicated Everyone
    /// icon"). The audience row in the share sheet does wear it, and that is a different question:
    /// there it is a picture of who you are posting AS, here it is a statement of who can see it.
    private func audienceBadge(for s: Story, isMine: Bool) -> StoryAudienceBadge? {
        // NOBODY BUT THE AUTHOR SEES THIS LINE AT ALL (owner, 2026-08-07: "only owner story can see
        // that label… when I want to see other people story don't show that label, show only name
        // and time like before"). It used to tell everybody else the TYPE — "My Friends", "Everyone"
        // — which is a fact about the author's own audience settings and is nobody else's business
        // on a screen they did not post to. The header falls back to its old stacked name-over-time
        // shape when there is nothing here; see `UserView`.
        guard isMine else { return nil }
        if s.oneTime { return StoryAudienceBadge(systemImage: "1.circle", text: "View once") }
        switch s.audienceLabel {
        case "everyone": return StoryAudienceBadge(systemImage: "globe", text: "Everyone")
        case "custom":
            // The author's private name for the list. A name this device happens not to have
            // (posted from another phone, or reinstalled) falls through to the plain type, which is
            // the safe way round to be wrong. The story still UPLOADING has no document id to file
            // a name under, so it reads the one the post in flight was given.
            let name = StoriesService.isPending(s.id)
                ? StoriesService.shared.uploadingAudienceName(for: s.id)
                : (StoryPrefs.audienceName(storyId: s.id) ?? "")
            return StoryAudienceBadge(systemImage: "person.crop.rectangle.stack",
                                      text: name.isEmpty ? "Custom" : name)
        default: return StoryAudienceBadge(systemImage: "person.2.fill", text: "My Friends")
        }
    }

    // MARK: - The hero transition
    //
    // ONE PIECE OF GEOMETRY, USED BOTH WAYS. The open runs it from 1 to 0 and the close runs it from
    // 0 to 1, so the story cannot leave by a different door than it arrived through. Everything it
    // needs is two rectangles: where the card is (`StoryCardMorph.cardWindowRect`, the library's own
    // answer rather than a second copy of its rule) and where the row card is (`MediaOpenRects`).

    /// Put the card where `hero` currently says it is. The only place that talks to the morph.
    ///
    /// `applyFlight`, NOT `apply`: the flight moves the presenter's own full-screen container
    /// (`StoryZoomPresenter`'s flightView) and masks it down to the card. It used to move the same
    /// inner view the sheet shrinks — for a friend's story that is UIPageViewController's private
    /// scroll view, and transforming it while UIKit animated it is the build-481 crash. The inner
    /// card still belongs to the viewers sheet; the flight now has a view of its own.
    /// THE SHAPE THE FLIGHT LANDS IN, ASKED OF THE SOURCE RATHER THAN ASSUMED.
    ///
    /// This was a hardcoded 24, which is the story row card's radius and nothing else's. Every source
    /// that registers itself with `MediaOpenRects` already reports its REAL corner radius — the
    /// machinery has been there since the chat media transition, where a flat 14 made bubbles change
    /// shape at the hand-over — and the story flight was the one caller ignoring it.
    ///
    /// ⚠️ THIS IS WHAT MAKES SNAPCHAT'S CIRCLE WORK, and it is why the circle needed almost no new
    /// code. A chat-row ring or a profile avatar reports its radius as half its width; the flight
    /// then interpolates to a full circle on its own, and the crop that already converges the card to
    /// the target's ASPECT (square, for an avatar) is what crops the story to fill as it rounds. Card
    /// from the row, circle from an avatar, one system, no per-site branch.
    private var heroLandingRadius: CGFloat {
        let key = MediaOpenRects.key(.storyRow, heroKeyNow())
        // A source that never registered a radius answers 14, which is not this screen's default, so
        // fall back to the row card's 24 rather than to the chat bubble's number.
        let r = MediaOpenRects.cornerRadius(key)
        return r == 14 ? 24 : r
    }

    private func applyHero() {
        guard StoryCardMorph.shared.isFlightAvailable else { return }
        let f = hero.f
        StoryCardMorph.shared.applyFlight(fraction: f,
                                          targetSize: hero.anchor.size,
                                          targetCenter: CGPoint(x: hero.anchor.midX, y: hero.anchor.midY),
                                          cornerRadius: heroLandingRadius,
                                          centerOverride: hero.center,
                                          alpha: hero.alpha,
                                          dim: heroDim(f),
                                          chrome: heroChrome(f),
                                          crop: hero.crop)
        // THE COVER BELONGS TO THE FLIGHT, NOT TO THE FINGER. Written by whichever run is going
        // (see `HeroBox.coverAlpha`); the drag holds it at 0, so what is under the hand is story A,
        // unaltered, all the way down.
        StoryCardMorph.shared.setFlightCoverAlpha(hero.cover ? hero.coverAlpha : 0)
        // AND THE SURROUND LEAVES AND ARRIVES ON THE SAME FRACTION. `heroFlying` (my own footer, the
        // no-replies pill, the page's black) and `storyFlightActive` (the library's reply bar) used
        // to flip at the START of a flight and back at its END, so the bottom of the screen popped
        // into place after the card had already stopped moving — his "the reply bar comes late… it
        // must be there at 85, 90 percent". They now cross where the mask's own surround begins to
        // let light through, so the fade they run and the crop that reveals them are the same event.
        // ⚠️ AN EXIT HIDES THE SURROUND AT ONCE; ONLY AN ARRIVAL IS ALLOWED TO TAKE ITS TIME.
        //
        // His 2026-08-07 report, with the top and bottom circled: "when i scroll down my owner story
        // i see black top header and buttom, other story is working good". Both halves of that are
        // this line. `heroChrome` draws the surround at up to full alpha for the first 18% of the
        // journey, and for MY OWN story the surround contains a full-screen `Color.black` (the
        // `storyLayer` backing, which a friend's story does not have — that asymmetry IS his "other
        // story works"). So the first 76pt of a pull painted his black page over the chat list, top
        // and bottom, and only then dropped it.
        //
        // A fade is right for the surround ARRIVING — that fix is his too ("the reply bar comes late,
        // it must be there at 85, 90 percent") and the open keeps it exactly. It is wrong for the
        // surround LEAVING, because the thing being faded out is an opaque wall standing between him
        // and the list he is pulling towards. So an exit takes it away on the first frame.
        let hide = hero.exiting || f > Self.heroChromeSpan
        if hero.chromeHidden != hide {
            hero.chromeHidden = hide
            if heroFlying != hide { heroFlying = hide }
            NotificationCenter.default.post(name: .init("storyFlightActive"), object: hide)
        }
    }

    /// How much of the viewer's surround (reply bar, footers, the page's own black) is let through
    /// the flight's mask: nothing while the card is out in the room, everything by the time it is
    /// home at full screen. The window is the last sixth of the journey, which on the open's spring
    /// is its long settle — a real fade of about a fifth of a second, ending exactly as the card
    /// stops. Read with `heroDim`: the black behind and the furniture in front arrive together.
    private static let heroChromeSpan: CGFloat = 0.18
    private func heroChrome(_ f: CGFloat) -> CGFloat {
        max(0, min(1, (Self.heroChromeSpan - f) / Self.heroChromeSpan))
    }

    /// THE EXCHANGE, ON THE SNAP'S OWN TIMELINE. `t` is the flight animation's progress, 0 at the
    /// instant the finger lets go and 1 as the card touches down.
    ///
    /// Finished by 0.85 rather than at 1, and that is his requirement stated as a number: "by the
    /// time the view lands, the cross-fade must be 100% complete… zero post-dismissal updates". A
    /// curve that only reaches 1 exactly at the end leaves its last few percent to be finished by
    /// the hand-over, which is the pop. Ending early means the last stretch of the flight is
    /// already carrying the row card's own picture, avatar ring and all — so the teardown swaps two
    /// identical rectangles.
    private func heroCoverIn(_ t: CGFloat) -> CGFloat {
        max(0, min(1, t / 0.85))
    }

    /// The same exchange on the way IN, reversed: the seat wears the thumbnail, and it dissolves
    /// into the live story over the first half of the open so the glide to full screen is the story
    /// itself. (The open's `t` runs the other way round — 0 at the row, 1 at full screen.)
    private func heroCoverOut(_ t: CGFloat) -> CGFloat {
        1 - max(0, min(1, (t - 0.2) / 0.35))
    }

    /// THE WALL'S ALPHA, AS A FUNCTION OF WHERE THE CARD IS — and the two ends are DIFFERENT.
    ///
    /// At the ROW end (f → 1) it lets go to nothing: the landing must reveal the chat list, and a
    /// dim held all the way home would still be on screen at the instant the cover is taken away —
    /// a grey-to-white flash exactly where the eye is. Down over the last quarter, as before.
    ///
    /// At the FULL-SCREEN end (f → 0) it goes to OPAQUE, not back to nothing. The wall IS the
    /// story screen's black above and below the card, so it must arrive WITH the card. The first
    /// curve here was symmetric ("fades in and out the same way at both ends"), which handed the
    /// last stretch of every open to a transparent wall and then snapped to black at completion —
    /// his first build-487 report, with the white strips circled top and bottom: "the black bottom
    /// and top draws late… shows as the story fully opens". Ramping to opaque over the last 15%
    /// also makes `resetFlight`'s black a visual no-op, and gives the close drag Telegram's look:
    /// the letterbox black GIVES WAY progressively as the card leaves, instead of vanishing on the
    /// first frame of the drag.
    ///
    /// In the middle: Snapchat's grey, from his screenshots — the list behind is clearly dimmed but
    /// still readable, which is what makes the story read as lifting off it.
    private func heroDim(_ f: CGFloat) -> CGFloat {
        let f = max(0, min(1, f))
        if f < 0.15 {
            return 1 - (1 - Self.heroDimMax) * (f / 0.15)
        }
        return Self.heroDimMax * (f > 0.75 ? max(0, (1 - f) / 0.25) : 1)
    }

    /// THE CARD THIS STORY BELONGS TO RIGHT NOW, which is not always the one it was opened from.
    ///
    /// A friend's viewer pages from person to person. Closing the fourth person's story back into
    /// the first person's card would be a matched transition that does not match anything — the
    /// picture flying home would land on somebody else's face. So the current bucket's own card is
    /// preferred, and the one it opened from is the fallback for the moment before the first bucket
    /// is reported.
    private func heroKeyNow() -> String {
        guard heroDismiss else { return "" }
        if let g = groups.first(where: { $0.authorUid == currentBucketUid }),
           onScreenRect(for: g.id) != nil { return g.id }
        return heroSourceKey
    }

    /// The row card's rectangle, but only if it is somewhere a story could believably fly to. The
    /// row scrolls sideways and the whole strip scrolls off the top of the chat list, so a card can
    /// be registered and still be nowhere near the screen; flying to it would send the story off the
    /// edge, which reads as the story being thrown away rather than put back.
    private func onScreenRect(for key: String) -> CGRect? {
        // `liveRect`, not `rect`: it asks the card's own view where it is at this instant, the way
        // Telegram's TransitionIn carries a `sourceView` rather than a remembered rectangle. A
        // written-down rect is only as true as the last layout pass that wrote it.
        guard !key.isEmpty,
              let r = MediaOpenRects.liveRect(MediaOpenRects.key(.storyRow, key)),
              r.width > 1, r.height > 1,
              UIScreen.main.bounds.insetBy(dx: -r.width / 2, dy: -r.height / 2).contains(CGPoint(x: r.midX, y: r.midY))
        else { return nil }
        return r
    }

    /// Both rectangles, or nothing. A missing one means the row has scrolled the card away or the
    /// story was opened from somewhere that does not report a rect, and in either case there is
    /// nowhere to fly: the caller falls back to a plain open/close rather than flying to `.zero`,
    /// which is the top-left corner of the screen and looks like a bug because it is one.
    private func heroEndpoints() -> (rest: CGPoint, anchor: CGRect)? {
        // `flightRestRect`, not `cardWindowRect`: the flight transforms the presenter's container,
        // so its rest geometry must be resolved against THAT view. Same published metrics, same
        // card strip, a view whose bounds origin is structurally zero. Still nil until
        // StoryDetailView has laid out and published a height — which is exactly what the open's
        // ladder waits for.
        guard let card = StoryCardMorph.shared.flightRestRect,
              let src = onScreenRect(for: heroKeyNow()) else { return nil }
        return (CGPoint(x: card.midX, y: card.midY), src)
    }

    /// Run the single scalar from 0 to 1, interpolating every value in `hero` between the two ends
    /// stored on it. `velocity` is the finger's, in progress units per second, so a flick carries
    /// its own speed into the spring instead of restarting from rest.
    /// `alphaCurve` reshapes TIME for the whole-card alpha alone (geometry stays on the spring's
    /// own t). Since the shared-element cover arrived, NEITHER flight fades the card itself on the
    /// main path — the card stays solid end to end and the COVER dissolves instead. The curve is
    /// still what the close to a DIFFERENT person uses; if a caller ever needs it again, never make
    /// it whole-journey linear — that was the see-through flying card he reported on an earlier
    /// build.
    ///
    /// `cover` is the thumbnail's alpha as a function of THIS RUN's progress, and it is a per-run
    /// curve rather than a function of `f` on purpose: the exchange must belong to the snap that
    /// follows the release, not to the drag (his 2026-08-07 spec, in as many words — "bind the
    /// transition progress directly to the destination snap animation timeline rather than the
    /// interactive gesture drag value"). It is written BEFORE `applyHero` so the value it sets is
    /// the one that frame paints, not the one after.
    private func runHero(to endF: CGFloat, center endC: CGPoint, alpha endA: CGFloat,
                         velocity: CGFloat, alphaCurve: @escaping (CGFloat) -> CGFloat = { $0 },
                         stiffness: CGFloat? = nil, settle: CGFloat? = nil,
                         cover: ((CGFloat) -> CGFloat)? = nil,
                         crop: ((CGFloat) -> CGFloat)? = nil,
                         done: @escaping () -> Void) {
        hero.fromF = hero.f;      hero.toF = endF
        hero.fromC = hero.center; hero.toC = endC
        hero.fromA = hero.alpha;  hero.toA = endA
        heroAnimator.animate(from: 0, to: 1, velocity: velocity, stiffness: stiffness, settle: settle, write: { t in
            hero.f = hero.fromF + (hero.toF - hero.fromF) * t
            hero.center = CGPoint(x: hero.fromC.x + (hero.toC.x - hero.fromC.x) * t,
                                  y: hero.fromC.y + (hero.toC.y - hero.fromC.y) * t)
            hero.alpha = hero.fromA + (hero.toA - hero.fromA) * alphaCurve(t)
            if let cover { hero.coverAlpha = cover(t) }
            if let crop { hero.crop = crop(t) }
            applyHero()
        }, completion: done)
    }

    /// THE OPEN. The page is born invisible (see `StoryCardMorph.revealAfterHeroOpen`) and stays
    /// that way until the card can be seated on the row card, so the story's first painted frame is
    /// already the size of the card it came out of rather than full screen.
    private func stageHeroOpen() {
        guard heroDismiss else { return }
        guard heroStageOpen else {
            // A refeed: the screen is already up and at rest, the wall already opaque. Mark the
            // open spent so the ladder never runs, and show the story where it stands.
            hero.staged = true
            StoryCardMorph.shared.revealAfterHeroOpen?()
            return
        }
        // WAITING FOR REAL GEOMETRY, NOT JUST FOR A CARD.
        //
        // A card is attached in `viewDidLoad` on one host and in an async pass on the other, and in
        // neither case is it in a window or laid out at that instant — so the first ask for its
        // rectangle legitimately answers "not yet". Asking once and giving up would degrade the open
        // to no animation every single time on the solo host, which is exactly the sort of thing
        // that looks like it works because the fallback is a real screen.
        //
        // Frames, not a timer: the answer arrives when layout happens, and layout happens on a
        // frame. The page is invisible for however few of them this takes, and the pager's own 0.4s
        // backstop reveals it if this never comes good.
        // THE BLACK GOES FIRST, BEFORE ANY OF THIS. A @State write lands on the next render pass,
        // and the reveal below is synchronous — so setting it inside `start` would paint one frame
        // of full-screen black underneath a card the size of a row card. Set here, at mount, it is
        // long gone by the time anything is visible; a hero presentation always intends to fly, and
        // the two paths that turn out not to (no rectangle, or the ladder running out) put it back.
        heroFlying = true
        let start: () -> Void = {
            // ONCE, EVER. See `HeroBox.staged`. Every path out of here counts as having started,
            // including the one that finds nothing to fly from, or the ladder would keep asking.
            guard !hero.staged else { return }
            hero.staged = true
            guard let (rest, anchor) = heroEndpoints() else {
                // Nothing to fly from. Show the story rather than hold it hostage to an animation.
                // `resetFlight` here is what paints the presenter's wall opaque: it is born
                // transparent so the tap never blacks the screen out before a flight, and this is
                // the one arrival at rest that no flight ends.
                heroFlying = false
                StoryCardMorph.shared.resetFlight()
                StoryCardMorph.shared.revealAfterHeroOpen?()
                return
            }
            hero.live = true
            hero.rest = rest
            hero.anchor = anchor
            hero.f = 1
            hero.center = CGPoint(x: anchor.midX, y: anchor.midY)
            // BORN SOLID, WEARING THE ROW CARD'S OWN PICTURE. Two failed shapes came before this
            // one. A hard-alpha seat swapped the card's preview (newest story) for the story the
            // viewer opens on (first unwatched) in one frame — his B-pops-to-A report. Then an
            // alpha-0 fade-in fixed the pop but flew as a half-transparent ghost over a row card
            // that never moved — his frame-grab, against Snapchat where "the thumbnail itself
            // expands". The shared-element answer keeps both promises: the presenter photographed
            // the tapped card at tap time, that snapshot (`flightCover`) sits on top of the flying
            // card, the seat is fully opaque and pixel-identical to the slot it covers, and the
            // cover dissolves into the live story while the card grows. Nothing can pop, and
            // nothing is ever transparent.
            hero.alpha = 1
            hero.cover = true          // the tapped card is the one on the cover, by definition
            hero.coverAlpha = 1        // the seat is the thumbnail; the flight dissolves it away
            // Seated IN the slot, so it wears the slot's shape; the open lets it back out to the
            // whole 9:16 picture on the same curve that dissolves the cover, which is what keeps
            // the unfolding hidden under the thumbnail while it happens.
            hero.crop = 1
            // An ARRIVAL. The surround comes back on the fraction over the last 18%, which is the
            // fix he asked for by number, and it is the only direction that should ever fade.
            hero.exiting = false
            // The cube must not fold while the card is in flight, in EITHER direction: `getAngle`
            // reads the page's global position and this moves it. Raised for the open as well as
            // the close, which is a difference from the library's own dismiss — that one only ever
            // ran on the way out.
            StoryCardMorph.heroDismissActive = true
            // SEE-THROUGH FOR THE FLIGHT, on the way in as well as the way out. The page behind the
            // card is opaque black at rest, and the morph transforms the CARD, not the page — so
            // without this the open would be a small story growing on a full black screen instead of
            // growing out of the row over the chat list.
            StoryCardMorph.shared.prepareForHero?()
            // The seat, the cover it wears and the crop that hides the surround are all written by
            // this one call, in one transaction — the seat must never paint the fitted mini-layout
            // bare, and it cannot, because the cover's alpha is part of the same apply.
            applyHero()
            // THE SLOT EMPTIES, Snapchat's way, on his frame-grabs (2026-08-07): "the card goes
            // [to] the empty place it comes from... [the] place is empty and waiting to fill it
            // back". The card that lifted off IS the slot's picture (the cover above), so hiding
            // the real one costs nothing and the row shows a waiting hole for as long as the story
            // is open. Revealed by the teardown (`storyPresenterClosed`), not by the open.
            MediaSourceVisibility.shared.hide(MediaOpenRects.key(.storyRow, heroKeyNow()))
            StoryCardMorph.shared.revealAfterHeroOpen?()
            // THE OPEN'S OWN SPRING — softer than the close's, on his Snapchat frame-scrub
            // (2026-08-07): what reads as "smoother" there is not the total time, it is the long
            // gentle glide into full screen, where Signal's 631 arrives and stops. Still softer than
            // the close, so the glide he asked for is intact.
            //
            // TIGHTENED ON HIS WORD, 2026-08-07 ("when i click story opening add slightly speed"):
            // 450 → 530 and the settle 0.0008 → 0.0015. The stiffness is the smaller half of it —
            // spring time goes as 1/√k, so that alone is only about 8%. The epsilon is where the
            // waiting actually was: it is the distance from target at which the run is allowed to
            // stop, and at 0.0008 of a 0…1 fraction the last stretch is sub-pixel motion nobody can
            // see but everybody can feel. 0.0015 is still well under a pixel at this card's size.
            // Read with the dip beat in `afterStoryDip`, trimmed in the same breath.
            runHero(to: 0, center: rest, alpha: 1, velocity: 0,
                    stiffness: 530, settle: 0.0015,
                    cover: heroCoverOut, crop: heroCoverOut) {
                hero.live = false
                hero.cover = false
                hero.coverAlpha = 0
                hero.crop = 0
                // Belt only: `applyHero` has already crossed both of these on the way in, at 0.18.
                if heroFlying { heroFlying = false }
                if hero.chromeHidden {
                    hero.chromeHidden = false
                    NotificationCenter.default.post(name: .init("storyFlightActive"), object: false)
                }
                StoryCardMorph.heroDismissActive = false
                // `resetFlight`: identity, unmasked, cover off, and the presenter's wall opaque
                // again. The sheet's own `reset` has no business here — the flight never touched
                // its view. NO `MediaSourceVisibility.reveal()` any more: the slot stays EMPTY for
                // the whole viewing, waiting for the close to fill it back (his Snapchat spec);
                // the teardown reveals it.
                StoryCardMorph.shared.resetFlight()
                StoryCardMorph.shared.restoreAfterHero?()   // the page is opaque black again at rest
            }
        }
        // A fixed ladder of attempts rather than a self-rescheduling retry: the first one that finds
        // real geometry wins and the rest see `hero.live` and stand down, and the LAST one runs
        // whatever happens so a story can never be left invisible waiting for a rectangle that is
        // not coming.
        //
        // PATIENCE IS NOT THE SAME AS HOPE, and one flat deadline could not tell them apart. It
        // waited ~0.25s and then showed the story wherever it was. The SOLO host never reaches
        // that: `StorySoloHostVC.viewDidLoad` attaches its card synchronously, before the first
        // paint. The friends' pager structurally cannot — it waits for UIPageViewController to
        // build its internal scroll view (an async hop, with retries) and then for a hosting
        // controller built AT TAP TIME to lay out and publish the card's height. Run past 0.25s and
        // the story was revealed at full size, which is his report to the letter: his own story
        // grows out of its card and a friend's "pops up and fully becomes the screen".
        //
        // So the long ceiling applies only while a host has actually claimed the card and is
        // therefore still coming good. If nobody has claimed it inside the old window, there is
        // nothing to wait for and the story is shown rather than held hostage to an animation.
        let ceiling = 33            // ~0.55s: the outer limit while a host is building
        let noHostPatience = 15     // ~0.25s with no card attached at all = nothing is coming
        for i in 0..<ceiling {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) / 60.0) {
                // `staged`, not `live`: a finished flight is still a flight that happened.
                guard !hero.staged, !hero.live else { return }
                if heroEndpoints() != nil { start(); return }
                if i == ceiling - 1 || (i == noHostPatience && !StoryCardMorph.shared.isAvailable) { start() }
            }
        }
    }

    /// EVERY WAY OUT GOES THROUGH THE SAME FLIGHT.
    ///
    /// The library closes itself by setting its `isPresented` binding false — the X button, the last
    /// story running out, "hide this person". If that reached the real state directly, the pager
    /// would stop rendering on that same update pass and the card would be gone before anything
    /// could fly it home: the drag would land on the row card and every other exit would drop the
    /// cover instead. So the binding is intercepted, the flight is run, and the state is set at the
    /// end of it. The chat media viewer learned this the same way — its arrow used a different exit
    /// from its drag, and the owner reported it.
    private var libraryPresented: Binding<Bool> {
        Binding(get: { isPresented },
                set: { shown in
                    if !shown, heroDismiss {
                        // A flight is already carrying this viewer out, or a finger is on the card
                        // and about to decide. Either way the close is in hand: unmounting now would
                        // take the card away mid-air, which is the failure this binding exists to
                        // prevent, just arriving from a different direction.
                        if hero.live || hero.committing { return }
                        // WITH THE VIEWERS SHEET ENGAGED THE CARD IS NOT AT REST — it is morphed
                        // into the sheet's slot, and a "from rest" flight would crop and fly a
                        // screen that does not look like the card it claims to be (the sheet panel
                        // rides inside the crop). The one close that arrives this way is the
                        // sheet's own "Send Message"; it falls through to the plain close instead,
                        // which the presenter answers with its drift-away.
                        if !(showViewers && viewersProgress > 0.02), beginHeroCloseFromRest() { return }
                    }
                    isPresented = shown
                })
    }

    /// Set the hero up from the card's resting position and fly it home. Returns false when there is
    /// nowhere to fly to, so the caller can fall back to closing the ordinary way.
    @discardableResult
    private func beginHeroCloseFromRest() -> Bool {
        guard !hero.live, let (rest, anchor) = heroEndpoints() else { return false }
        heroAnimator.cancel()
        hero.live = true
        hero.rest = rest
        hero.anchor = anchor
        hero.f = 0
        hero.center = rest
        hero.alpha = 1
        hero.coverAlpha = 0        // starts on the live story, exactly as a released drag does
        hero.crop = 0              // and on the whole picture, so a button close is the same flight
        hero.exiting = true        // and the surround leaves at once, as it does under a finger
        StoryCardMorph.heroDismissActive = true
        StoryCardMorph.shared.prepareForHero?()
        // The surround leaves on the fraction, exactly as it does under a finger — a button close
        // and a drag close must not be two animations. See `applyHero`.
        commitHero(velocity: 0)
        return true
    }

    /// THE CLOSE. The pan reports; this decides. See `StoryPager.handleHeroDrag`.
    private func onHeroDrag(_ phase: StoryHeroPhase, _ t: CGPoint, _ v: CGPoint) {
        switch phase {
        case .began:
            // THE SHEET WINS WHILE IT IS UP. Both gestures move the same card through the same
            // `apply`, and the sheet is already holding it somewhere between full screen and its
            // slot — a close starting from that state would fly from a rectangle neither of them
            // agrees on. The sheet's own touch partition should never let this pan begin up there
            // anyway; this is the belt to that braces.
            guard !(showViewers && viewersProgress > 0.02) else { return }
            heroAnimator.cancel()
            guard !hero.committing, let (rest, anchor) = heroEndpoints() else { return }
            hero.live = true
            hero.rest = rest
            hero.anchor = anchor
            hero.f = 0
            hero.center = rest
            hero.alpha = 1
            // NOTHING CROSS-FADES UNDER THE FINGER (his spec: "keep rendering story A exactly as it
            // is… do not trigger any cross-fade during the drag"). Taking the cover off here also
            // answers the finger that seizes a card mid-open, which would otherwise be dragging a
            // half-dissolved thumbnail. It comes back only if this drag commits.
            hero.cover = heroKeyNow() == heroSourceKey
            hero.coverAlpha = 0
            hero.exiting = true        // a pull is an exit: the black page goes now, not over 76pt
            // AND NOTHING IS SHAVED OFF IT EITHER (his spec: "uniform scale only… preserving the
            // full video/image visibility without cropping any edges"). A finger seizing the card
            // mid-open gets the same deal, which is why this is written here rather than only on
            // `.began`: whatever the open had reconciled so far is released back to the whole
            // picture the moment the gesture takes over.
            hero.crop = 0
            // THE REPLY BAR STEPS ASIDE ON THE FRACTION, THE CARD'S OWN CHROME STAYS ON THE CARD.
            //
            // This used to post `storyChromeHidden`, which took the progress bars and the name with
            // it and left a bare photo sliding around. Snapchat keeps them: they are drawn inside the
            // card, so they shrink with it and the thing in your hand still looks like a story. What
            // has to go is the reply bar, which is drawn BELOW the card, does not move, and carries a
            // solid black footer that would lie across the chat list — and it now goes gradually, as
            // the finger travels, instead of blinking out on the first millimetre. See `applyHero`.

        case .changed:
            guard hero.live, !hero.committing else { return }
            // DOWN ONLY, and measured from the touch rather than accumulated: dragging back up above
            // where you started returns the card to rest instead of pushing it off the top. That
            // reversibility is behaviour the owner asked for and liked, and it is why the commit
            // test below reads the raw translation rather than this clamped one.
            let ty = max(0, t.y)
            hero.f = min(1, ty / Self.heroDragSpan)
            // VERTICAL ONLY (owner, 2026-08-06: "only scroll up and down… block left right").
            //
            // The x is deliberately dropped rather than damped or clamped. The card followed the
            // finger on both axes for about an hour and he asked for it gone, and he is right that a
            // close which drifts sideways reads as a drag that has not decided what it is — the
            // gesture is already direction-locked to `.down` by the recogniser, so letting the card
            // move on the other axis was the one part of it that disagreed with that.
            //
            // The LANDING still travels sideways, and that is a different thing: the card it flies
            // home to sits wherever it sits in the row. What is locked is the part the finger owns.
            hero.center = CGPoint(x: hero.rest.x, y: hero.rest.y + ty)
            // OPAQUE ALL THE WAY DOWN. This used to be `1 - heroFade * f`, softening the story to
            // about 94% across a normal pull and 78% at the end of the span, and his report is that
            // the chat list shows THROUGH the story like glass. It does: there is a dimmed but fully
            // drawn list right behind it, so even a few percent reads as the card being see-through.
            // The background giving way is `heroDim`'s job and it already does it. Nothing about the
            // picture itself should say "leaving" except its size and its position.
            hero.alpha = 1
            applyHero()
            // NOTHING ELSE IS WRITTEN HERE. `dragDown` used to be set on the first six points so the
            // owner bar could hide itself, which made the same piece of chrome answer to two rules —
            // a 6pt switch and, since the mask, a fraction. It answers to the fraction alone now
            // (`applyHero`); `dragDown` still serves the LIBRARY's own dismiss pan, which is the
            // path where there is no hero at all.

        case .ended:
            guard hero.live, !hero.committing else { return }
            // A SHORT PULL OR ANY REAL FLICK CLOSES. The library's old rule wanted 200pt, which the
            // owner has called too much work on the chat viewer's version of this gesture; the
            // profile photo viewer, the one he has always said feels right, commits on far less.
            if t.y > 120 || v.y > 550 {
                commitHero(velocity: v.y)
            } else {
                cancelHero(velocity: v.y)
            }

        case .cancelled:
            guard hero.live, !hero.committing else { return }
            cancelHero(velocity: 0)
        }
    }

    private func commitHero(velocity vy: CGFloat) {
        hero.committing = true
        // String-named on purpose: the library's `Notification.Name` extension is internal to the
        // package, so the app has always posted these by name. Every other post in this file does
        // the same.
        NotificationCenter.default.post(name: .init("stopVideo"), object: nil)
        let anchorCentre = CGPoint(x: hero.anchor.midX, y: hero.anchor.midY)
        // THE CARD FILLS THE EMPTY SLOT IT LEFT, his Snapchat spec in his own words: "the card
        // goes [to] the empty place it comes from... waiting to fill it back". The slot has been
        // hidden since the open. On the way home the flying card puts the COVER back on (the
        // landing tick below: in from just before half-way, fully worn by four-fifths), so what
        // touches down is pixel-identical to the row card the teardown then reveals — the swap at
        // the landing exchanges two identical pictures and cannot pop. This replaces the previous
        // fade-into-a-visible-card landing: he watched Snapchat frame by frame and asked for the
        // hole. (The first design here blanked the slot AND landed the live story on it — the
        // one-frame "still picture pop" he caught in slow motion. The cover is what squares that
        // circle: the slot can be empty AND the landing seamless, because the flying card itself
        // becomes the row card before it arrives.)
        // Distance left to travel, so the finger's speed enters the spring in the right units.
        // A hard flick is a strong "close this" and the landing should carry that speed. Capped
        // because the row card can be very close to where the finger let go, and a small `remaining`
        // would otherwise turn an ordinary flick into a spring nobody can see.
        let remaining = max(1, hypot(anchorCentre.x - hero.center.x, anchorCentre.y - hero.center.y))
        let land: () -> Void = {
            guard !hero.closed else { return }
            hero.closed = true
            // The card is home. Take the cover away with no animation of its own — see onHeroClose.
            if let onHeroClose { onHeroClose() } else { isPresented = false }
            // Cleared here rather than on teardown: this is a static, so a viewer that left it
            // raised would keep the NEXT story's cube flat for as long as that story was open.
            StoryCardMorph.heroDismissActive = false
        }
        // The cover-and-hole landing belongs to the TAPPED person's slot alone: only that slot was
        // emptied, and only its pixels are on the cover. A close after swiping to somebody ELSE
        // lands on their still-visible card, where a wrong-picture cover would be worse than none —
        // that case keeps the proven crossfade landing: solid while it travels (t³), melting into
        // the visible card as it arrives.
        hero.cover = heroKeyNow() == heroSourceKey
        if hero.cover {
            // THE WHOLE EXCHANGE HAPPENS HERE, in the snap that follows the release: the flying
            // card cross-fades from the story he was watching into the row card's own picture —
            // avatar ring, border and all — and is finished before it touches down.
            runHero(to: 1, center: anchorCentre, alpha: 1, velocity: min(6, max(0, vy) / remaining),
                    cover: heroCoverIn, crop: heroCoverIn, done: land)
        } else {
            // No cover on this one, but the SHAPE still has to converge: it is landing on somebody
            // else's card and a 9:16 rectangle would overhang their slot top and bottom. Same curve,
            // so it too is the row's shape before it touches down.
            runHero(to: 1, center: anchorCentre, alpha: 0, velocity: min(6, max(0, vy) / remaining),
                    alphaCurve: { $0 * $0 * $0 }, crop: heroCoverIn, done: land)
        }
        // A FLIGHT THAT NEVER LANDS MUST NOT TRAP HIM IN THE VIEWER.
        //
        // `libraryPresented` swallows every close while `committing` is true, which is right — a
        // button press must not yank the card out of the air. But it also means a spring that never
        // reports back leaves no way out of the screen at all, and he has filmed the viewer freezing.
        // 1.2s is four times the flight; if it has not landed by then it is not going to.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            guard !hero.closed else { return }
            heroAnimator.cancel()
            land()
        }
    }

    private func cancelHero(velocity vy: CGFloat) {
        NotificationCenter.default.post(name: .init("resumeStory"), object: nil)
        // The surround comes back the way it left — on the fraction, as the card springs home. It
        // used to be told to return on the first frame of the spring-back, which put the reply bar
        // on screen while the story was still small and travelling.
        let remaining = max(1, hypot(hero.rest.x - hero.center.x, hero.rest.y - hero.center.y))
        // A spring-back is an ARRIVAL, so the surround stops being taken away at once and goes back
        // to fading in over the last 18% with the card. Cleared BEFORE the run, or the first frame
        // would still be an exit.
        hero.exiting = false
        // No cover on a spring-back: there is nothing to exchange, the story is going back to being
        // the whole screen. It was already 0 through the drag and stays there.
        runHero(to: 0, center: hero.rest, alpha: 1, velocity: -abs(vy) / remaining,
                cover: { _ in 0 }, crop: { _ in 0 }) {
            hero.live = false
            hero.cover = false
            if heroFlying { heroFlying = false }     // belt: applyHero crossed this at 0.18
            if hero.chromeHidden {
                hero.chromeHidden = false
                NotificationCenter.default.post(name: .init("storyFlightActive"), object: false)
            }
            // Full screen, square, unmasked, and the wall behind opaque again. `resetFlight` is
            // what puts the container back exactly, rather than an `applyFlight(fraction: 0)` that
            // leaves a mask covering the whole card for every frame the story renders from here on.
            StoryCardMorph.shared.resetFlight()
            StoryCardMorph.heroDismissActive = false
            StoryCardMorph.shared.restoreAfterHero?()
        }
    }

    private func driveMorph(_ p: CGFloat) {
        // A hero open or close owns the card outright. Without this, the sheet's reset-on-zero would
        // slam a card that is mid-flight back to full screen — and `viewersProgress` is written to 0
        // by several teardown paths, one of which is the close this would be interrupting.
        guard !hero.live else { return }
        guard showViewers else { StoryCardMorph.shared.reset(); return }
        // IF THERE IS NO CARD TO MOVE, HIDE THE STORY INSTEAD OF LEAVING IT FULL SIZE.
        //
        // Twice now a broken binding has produced the same screenshot: the sheet slides up over a
        // story sitting at full size, because `apply` guards on a nil card and returns. Both times
        // the cause was different and both times the SYMPTOM was this, because the design had no
        // answer for "the morph is not available". It has one now — the same fade the viewer used
        // before the morph existed. A story that fades is a worse animation; a story that ignores
        // the sheet entirely is a broken screen, and the difference matters more than the polish.
        guard StoryCardMorph.shared.isAvailable else {
            morphUnavailable = true
            return
        }
        if morphUnavailable { morphUnavailable = false }
        // BELOW THE CAROUSEL'S PLATEAU THE LIVE CARD MUST BE VISIBLE, whatever the row's scroller
        // thinks. The hide (`setHidden(true)`) belongs to the copy-swap, and the copy fades out
        // WITH the carousel under p≈0.9 — so a collapse drag that had also tickled the row's pan,
        // or a hide stuck by a cancelled swipe, left alpha-0 under a vanished copy: his black
        // window. Idempotent and cheap, and legit swipes only exist above the 0.95 band gate, so
        // this cannot fight the designed exchange.
        if p < 0.9 { StoryCardMorph.shared.setHidden(false) }
        let slot = cardSlot
        let scr = UIScreen.main.bounds
        // Same staging the morph card used: the frame shrinks across 0.08 → 0.9. The first hair of
        // the pull stays full size so a stray touch shrinks nothing visible, and the last tenth is
        // left for the carousel to fade in behind a card that has already stopped moving.
        let sizeP = max(0, min(1, (p - 0.08) / (0.9 - 0.08)))
        StoryCardMorph.shared.apply(fraction: sizeP,
                                    targetSize: CGSize(width: slot.w, height: slot.h),
                                    targetCenter: CGPoint(x: scr.width / 2, y: slot.centerY),
                                    cornerRadius: 24)
    }

    // The layer behind the viewers sheet: the carousel of ALL my stories, and NOTHING in its centre
    // slot, because the live story is put there by `driveMorph`. The neighbours and the count row
    // fade in over the last tenth of the pull, behind a centre that has already stopped moving.
    @ViewBuilder private var viewersBackdrop: some View {
        let p = viewersProgress
        // ONE source for the slot (see `cardSlot`). The fill-vs-blur decision the neighbour cards
        // make against `slotH / slotW` still lives in `card(_:)`; only the numbers moved.
        let slot = cardSlot
        let slotW = slot.w
        let slotH = slot.h
        let miniH = slot.miniH
        let cropY: CGFloat = 0
        let blockTop = slot.top
        // STAGING. `carIn` fades the neighbours and the count row in over the last tenth of the
        // pull, behind a centre card that has already stopped moving.
        //
        // THERE IS NO MORPH CARD ANY MORE, and that is the whole of the frozen-frame fix. The centre
        // of this carousel is the REAL story, put there by `driveMorph` as a UIKit transform, so a
        // video shows the frame it is actually on because it is still the same layer drawing it.
        // The carousel's own centre card keeps its frame and its tap target but draws no pixels, so
        // there is exactly ONE picture in that slot at every moment and nothing to hand over at
        // p=0.97 — that seam, where two renderers disagreed about framing, was `402ec4d`'s bug.
        let carIn = max(0, min(1, (p - 0.9) / 0.07))
        // Feed the carousel from the LIVE repo (not the viewer's immutable snapshot), so a story
        // deleted while viewing doesn't linger as a ghost card. Fall back to the snapshot.
        let liveMyStories = StoriesRepository.shared.mine?.stories ?? myStories
        ZStack(alignment: .top) {
            MyStoriesCarousel(stories: liveMyStories, activeId: $sheetStoryId,
                              slotW: slotW, slotH: slotH, miniH: miniH, cropY: cropY,
                              onActiveTap: { closeViewers() },
                              // The live story occupies the centre slot, so the carousel draws no
                              // pixels there — EXCEPT while the row is being swiped. The story
                              // cannot follow a card that is mid-flight (it sits at the slot centre
                              // while the row slides past), so for the length of the swipe the
                              // carousel draws its own centre card and the real story hides
                              // underneath. Same size, same place, so the exchange is invisible.
                              hideActiveContent: !(carouselInteracting || sheetPageDrag != 0),
                              onInteracting: { carouselInteracting = $0 },
                              pageDrag: sheetPageDrag,
                              frozenCovers: frozenCovers)
                .padding(.top, blockTop)
                .opacity(Double(carIn))
                .allowsHitTesting(carIn > 0.5)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // NO gestures here any more. Every touch above the sheet panel is routed by
        // StoryViewersSheetView.hitTest now: the dark area's tap-to-collapse and the vertical
        // drag that collapses the sheet (story card included) are ITS UIKit recognizers, and the
        // only thing that reaches this SwiftUI layer is the carousel band while the sheet is
        // fully open — the cover-flow swipe and the card taps. The old SwiftUI DragGesture here
        // was one of the three writers the arbiter existed to referee.
        .ignoresSafeArea()
    }
    /// The viewers sheet, UIKit (owner's original request). Same `viewersProgress` in and out, so
    /// the live story's morph is driven by exactly the number the finger is writing. The sheet owns
    /// EVERY touch above its panel except the carousel band it is told about; releases come back
    /// through `settleViewers`, the one spring — see StoryViewersSheetUIKit's header for the
    /// routing map.
    private var viewersSheetLayer: some View {
        // Neighbour flags for the sheet's horizontal page-swipe (Telegram's sheet-to-sheet slide),
        // in the SAME live order the carousel lays its cards out in, so "next" is the card to the
        // right and never a stale snapshot's idea of it.
        let arr = StoriesRepository.shared.mine?.stories ?? myStories
        let idx = arr.firstIndex { $0.id == sheetStoryId }
        return StoryViewersSheet(activeStoryId: sheetStoryId,
                          progress: $viewersProgress,
                          carouselBand: carouselBandRect,
                          hasPrev: (idx ?? 0) > 0,
                          hasNext: idx.map { $0 < arr.count - 1 } ?? false,
                          // The ids as well as the flags: the sheet fetches the neighbour's viewers
                          // as soon as a sideways drag picks a side, so what slides in is that
                          // story's real list rather than a spinner.
                          prevStoryId: idx.flatMap { $0 > 0 ? arr[$0 - 1].id : nil } ?? "",
                          nextStoryId: idx.flatMap { $0 < arr.count - 1 ? arr[$0 + 1].id : nil } ?? "",
                          onClose: { closeViewers() },
                          onCollapseTap: { closeViewers() },
                          onRelease: { p, start, v in settleViewers(progress: p, dragStart: start, velocityUp: v) },
                          onDragActive: { down in
                              sheetFinger.down = down
                              if down { sheetAnimator.cancel() }   // finger beats spring
                          },
                          onPage: { d in
                              // Swipe the sheet sideways → the neighbour story's sheet. One value
                              // changes and everything follows it: the list reloads, the carousel
                              // recentres (activeId IS sheetStoryId), and the frozen story under
                              // the card jumps via the existing onChange choreography.
                              let live = StoriesRepository.shared.mine?.stories ?? myStories
                              guard let i = live.firstIndex(where: { $0.id == sheetStoryId }),
                                    live.indices.contains(i + d) else {
                                  withAnimation(.easeOut(duration: 0.28)) { sheetPageDrag = 0 }
                                  return
                              }
                              // The drag zeroes IN THE SAME TRANSACTION as the id flip, on the
                              // panel's own 0.28s return curve — the row glides its remaining
                              // distance while the new sheet slides in, one motion.
                              withAnimation(.easeOut(duration: 0.28)) {
                                  sheetStoryId = live[i + d].id
                                  sheetPageDrag = 0
                              }
                          },
                          onPageDrag: { f in sheetPageDrag = f },
                          // A viewer's profile opens in the SAME sheet the story header uses, so
                          // there is one profile screen in this viewer and not two that drift.
                          onOpenProfile: { v in
                              profileSheet = StoryGroup(authorUid: v.id, name: v.name,
                                                        photoUrl: v.photoUrl, stories: [],
                                                        lastViewedAt: nil, isMine: false)
                          })
            .ignoresSafeArea()
    }

    /// The carousel row's rectangle on screen — the one strip of the sheet's territory that passes
    /// through to SwiftUI while the sheet is open, so the cover-flow swipe and card taps keep
    /// working. Derived from the same `cardSlot` the carousel lays out from, so they cannot drift.
    private var carouselBandRect: CGRect {
        let slot = cardSlot
        return CGRect(x: 0, y: slot.top, width: UIScreen.main.bounds.width, height: slot.h)
    }

    /// THE ONE RELEASE RULE, for every finger that lets go of the sheet — the panel drag, the
    /// story-card drag, and the list hand-off all end here. Telegram's thresholds, read from
    /// `viewListDismissPanGesture` in StoryItemSetContainerComponent and converted to our progress
    /// units (their rule is on translation in points, screen-height fractions): close on a
    /// deliberate pull OR a modest flick; anything less springs back open. Their old counterpart
    /// here demanded 80% of the sheet's travel, which is why "scroll down to close is soo hard".
    private func settleViewers(progress p: CGFloat, dragStart: CGFloat, velocityUp: CGFloat) {
        let sheetH = UIScreen.main.bounds.height * StoryViewersSheetView.heightFraction
        let droppedPts = (dragStart - p) * sheetH          // + = dragged toward closed
        let vDownPts = -velocityUp * sheetH                // + = moving toward closed, pt/s
        // Telegram: close if the drag covered ≥30% of the screen, or ≥5% with ≥150pt/s of speed.
        let screenH = UIScreen.main.bounds.height
        if droppedPts >= screenH * 0.30 || (droppedPts >= screenH * 0.05 && vDownPts >= 150) {
            closeViewers(velocity: velocityUp)
        } else {
            sheetAnimator.animate(from: p, to: 1, velocity: velocityUp, write: { viewersProgress = $0 })
        }
    }

    private func openViewers() {
        // Re-open allowed even while the previous close is still unmounting: animating progress back
        // to 1 cancels the close animator (and with it the unmount completion) — no more
        // "swipe up does nothing for 0.42s after closing".
        guard currentIsMine else { return }
        // NOT ON A STORY THAT DOES NOT EXIST YET. The item on screen while a post is uploading is a
        // synthetic placeholder with no document behind it, so the viewers sheet would come up over
        // it asking the server who has seen a story id that has never been written — an empty list
        // and a carousel with nothing in its slot. It opens the moment the real story lands.
        guard !isUploadingItem else { return }
        NotificationCenter.default.post(name: .init("pauseStory"), object: nil)   // freeze the story immediately
        NotificationCenter.default.post(name: .init("storyFreezeBlur"), object: nil)   // keep the exact pre-pull blur
        NotificationCenter.default.post(name: .init("storyChromeHidden"), object: true)   // chrome-only exit
        if !showViewers {
            sheetStoryId = targetStoryId
            showViewers = true   // mount at progress 0 (offscreen) …
        }
        DispatchQueue.main.async {   // … then raise it on the next tick so the insertion animates
            sheetAnimator.animate(from: viewersProgress, to: 1, write: { viewersProgress = $0 })
        }
    }

    // See the .onChange(of: viewersProgress) note: parked-sheet self-heal.
    private func rearmProgressWatchdog(_ p: CGFloat) {
        progressWatchdog?.cancel(); progressWatchdog = nil
        guard showViewers, p > 0.02, p < 0.995 else { return }
        progressWatchdog = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled, showViewers,
                  viewersProgress > 0.02, viewersProgress < 0.995,
                  // Never snap under a LIVE finger (audit M3): a held-still drag writes nothing
                  // for 0.8s but the sheet still reports the finger down; UIKit pans deliver
                  // .cancelled reliably, so a dead finger always clears the flag.
                  !openDragging, !sheetFinger.down
            else { return }
            if viewersProgress >= 0.5 {
                sheetAnimator.animate(from: viewersProgress, to: 1, write: { viewersProgress = $0 })
            } else {
                closeViewers()
            }
        }
    }

    /// Collapse the sheet: the story grows back to full screen and the viewer STAYS OPEN. This is
    /// the only close path there is — every way out of the sheet (drag, tap, centre-card tap,
    /// self-heal) funnels here, and none of them may dismiss the whole viewer. (Telegram's
    /// closePressed does the same check in as many words: list open → hide the list only.)
    private func closeViewers(velocity: CGFloat = 0) {
        sheetAnimator.animate(from: viewersProgress, to: 0, velocity: velocity, write: { viewersProgress = $0 }) {
            // Reaching here means the close actually finished (a re-open cancels this animator).
            showViewers = false
            NotificationCenter.default.post(name: .init("storyChromeHidden"), object: false)   // chrome back
            NotificationCenter.default.post(name: .init("storyUnfreezeBlur"), object: nil)     // live material again
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

    // Video story → Photos: download the mp4 to a temp file, then add it as a video asset.
    private func saveCurrentVideo(_ mediaUrl: String?) {
        Task {
            guard let s = mediaUrl, let url = URL(string: s) else { return }
            guard let (tmp, _) = try? await MediaSession.shared.download(from: url) else { return }
            // .download hands back an extension-less temp file; PhotoKit needs .mp4 to accept it.
            let mp4 = FileManager.default.temporaryDirectory.appendingPathComponent("story-save-\(UUID().uuidString).mp4")
            try? FileManager.default.moveItem(at: tmp, to: mp4)
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else { return }
            try? await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: mp4)
            }
            try? FileManager.default.removeItem(at: mp4)
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
        // is still red when the story is reopened. Un-like removes my reaction from
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
        // A REACTION LIVES IN THE VIEWERS SHEET ONLY (owner 2026-08-05): the heart and the
        // react-bar emojis record on the story's "Seen by" row and never become a chat message.
        // They used to ALSO land in the conversation as a text bubble with a status quote, which
        // is exactly what he ordered removed. Only a TYPED reply enters the chat.
        let isReaction = typed == nil && (emoji != nil || isLiked)
        if isReaction {
            Task { await StoriesService.shared.setStoryReaction(s, emoji: text) }   // shows in "Seen by"
            flashSentToast("Reacted")
            return
        }
        let cid = [me, s.authorUid].sorted().joined(separator: "_")
        // Attach the status reference so the reply shows as a "Status" quote (thumbnail) in chat.
        let ref = ReplyRef(id: s.id, authorId: s.authorUid, text: "", isStatus: true, storyThumbUrl: s.previewUrl)
        Task { try? await ChatService.sendText(cid: cid, text: text, replyTo: ref) }
        flashSentToast()   // optimistic "Sent" confirmation
    }

    // Receipt ONLY the photo actually shown (drives accurate view counts + "Seen by"), and
    // advance the local watermark so the ring/row update instantly (H8 race fix).
    private func markSeenItem(_ storyId: String) {
        guard let s = groups.flatMap(\.stories).first(where: { $0.id == storyId }) else { return }
        StoriesRepository.shared.markSeenLocally(s.authorUid, upTo: s.createdAt)
        Task { await StoriesService.shared.markViewed(s) }
    }

    private func timeAgo(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .abbreviated
        return f.localizedString(for: d, relativeTo: Date())
    }

    // Owner bar: overlapping viewer avatars + "N Views" + ❤️ reactions (tap → sheet) + delete.
    // Views/reactions/delete controls, shared by the gradient overlay bar and the solid footer.
    private var ownerControls: some View {
        let reactions = barViewers.filter { !($0.reaction ?? "").isEmpty }.count
        // EVERY SELECTED VIEWER HAS USED THEIR ONE VIEW (owner 2026-08-07: "when all selected users
        // have viewed the story once, show Once Viewer Is Full to me").
        //
        // Counted from the audience itself rather than from the receipts, and that is the only
        // honest count: consuming a one-time story IS being removed from `recipientUids`, so an
        // empty audience means everybody has been through, while a view receipt is a setting the
        // viewer can turn off. `recipientsLeft` is -1 on anything that is not my own story, so this
        // can never read "full" from a story whose audience we are not allowed to see.
        let s = currentStory
        let oneTimeFull = (s?.oneTime ?? false) && s?.recipientsLeft == 0
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
                        Image(systemName: oneTimeFull ? "1.circle" : "eye")
                            .font(.subheadline).foregroundStyle(.white)
                    }
                    // The label carries the state rather than a second chip beside it: this row
                    // already holds avatars, a count, hearts and the bin, and for a one-time story
                    // "everybody has seen it" and "N views" are the same sentence twice.
                    Text(oneTimeFull ? "Once viewer is full"
                                     : "\(barViewers.count) View\(barViewers.count == 1 ? "" : "s")")
                        .font(.subheadline.weight(.medium)).foregroundStyle(.white)
                        .lineLimit(1)
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

    // The look: the cancel X lives INSIDE the loading ring (one element, not a separate X +
    // spinner + trash), then the "Uploading…" label. Tapping the ring cancels the upload. (The reference
    // ring is determinate — grows with % — but we only track an uploading flag, so the ring spins.)
    private var uploadingControls: some View {
        HStack(spacing: 12) {
            Button { uploadSvc.cancelUpload(); onClose() } label: {
                UploadCancelRing(diameter: 28)
            }.buttonStyle(.plain)
            Text("Uploading…").font(.subheadline).foregroundStyle(.white)
            Spacer()
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
                // Loading look: cancel X INSIDE the loading ring, then "Uploading…".
                HStack(spacing: 12) {
                    Button { stories.cancelUpload(); onClose() } label: {
                        UploadCancelRing(diameter: 28)
                    }.buttonStyle(.plain)
                    Text("Uploading…").font(.subheadline).foregroundStyle(.white)
                    Spacer()
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

    // My stories + one synthetic item per post still in the air. Once they finish (the list empties),
    // this is just my real stories, which now include the just-posted one.
    private var group: StoryGroup? {
        // EVERY post in the air, not just the newest (owner 2026-08-07: "I need to see all, when I
        // click right or left each one must be uploading"). Posts have always queued; only the
        // state describing them was single, so two of three uploads had no item to be drawn as.
        let pending = svc.uploadingStories
        guard let first = pending.first else { return repo.mine }
        if var g = repo.mine { g.stories.append(contentsOf: pending); return g }
        return StoryGroup(authorUid: first.authorUid, name: meName, photoUrl: mePhoto,
                          stories: pending, lastViewedAt: nil, isMine: true)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()   // constant backdrop so the re-feed never blinks
            if let g = group {
                // ownSwipeDismiss:false → the library's custom pan is OFF; the cover's native zoom
                // transition owns the scroll-down-to-close, same as every other story.
                StoryViewer(group: g, ownSwipeDismiss: false, onClose: onClose, onProfile: onProfile)
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

// "Seen by" sheet — who viewed my status (premium).
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
                    EmptyStateView(title: "No views yet", icon: "eye",
                                   text: "When people view your status, they'll appear here.")
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


// Carousel of ALL my posted stories, shown above the open viewers sheet (per the user mockup):
// ONLY the rounded photos — no captions, no avatars, no progress bars. Side cards carry a small
// eye+heart count inside their bottom edge; the CENTRED card shows its count BIG underneath.
// Swiping (or tapping a side card) re-centres a story and re-targets the viewers list below.
// `SnapshotCardContent` lived here. It rendered a card from `StoryCompositeCache`, and `21f3209`
// removed its last call site without removing it, so it has been dead code with a live feeder ever
// since. The feeder is gone too now (see the note on `.onChange(of: showViewers)`), and the CENTRE
// card is the real story, so nothing needs a photograph of a story any more.

// Story-style upload indicator: a thin ring with the cancel X inside it (one control).
// Tapping it cancels the upload. The ring spins (we track an uploading flag, not a % — the reference
// grows with real progress). Generous frame so the whole ring is an easy tap target.
struct UploadCancelRing: View {
    var diameter: CGFloat = 28
    @State private var spin = false
    var body: some View {
        ZStack {
            Circle()
                .trim(from: 0, to: 0.72)
                .stroke(Color.white.opacity(0.9), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(spin ? 360 : 0))
            Image(systemName: "xmark")
                .font(.system(size: diameter * 0.42, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: diameter, height: diameter)
        .padding(6)                       // bigger tap target around the ring
        .contentShape(Rectangle())
        .onAppear {
            withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { spin = true }
        }
    }
}

// The chat-list uploading card's indicator: my avatar with a clean thin ring spinning
// around it (same arc style as UploadCancelRing). Replaces the native circular
// ProgressView, whose pinwheel blades rendered as a messy wedge over the avatar.
struct UploadingAvatarRing: View {
    let name: String
    let photoUrl: String?
    @State private var spin = false
    var body: some View {
        // AN OVERLAY, NOT A SECOND ITEM IN A STACK, and 37 rather than 42. Both halves of his report
        // come from that one line: a ZStack takes the size of its LARGEST child, so the ring made
        // this view 42pt where every other card's circle is 32, and since the card pins its circle to
        // the bottom-left corner, the extra 10pt pushed the avatar up and in by 5. An overlay draws
        // outside the view without resizing it, which is exactly how the posted-story ring already
        // hangs off its own 32pt avatar at the same 37.
        AvatarView(name: name, photoUrl: photoUrl, size: 32)
            .overlay {
                // EVERY NUMBER HERE IS StoryRingView'S, so the ring you watch while it uploads is the
                // same ring you get when it has uploaded: 32pt circle, 37pt frame, 2.0 line, and the
                // `.inset(by: lineWidth / 2)` that keeps the stroke INSIDE that frame. Without the
                // inset a stroke straddles its path, so a 2.5pt line reached 38.25 — a ring that grew
                // by a point and a quarter the moment the upload finished.
                Circle()
                    .inset(by: 1)
                    .trim(from: 0, to: 0.72)
                    .stroke(Color.white.opacity(0.95), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .frame(width: 37, height: 37)
                    .rotationEffect(.degrees(spin ? 360 : 0))
            }
        .onAppear {
            withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { spin = true }
        }
    }
}

struct MyStoriesCarousel: View {
    let stories: [Story]
    @Binding var activeId: String
    let slotW: CGFloat
    let slotH: CGFloat
    let miniH: CGFloat                  // full mini-screen composite height; the card shows a slotH window of it
    let cropY: CGFloat                  // the window's top within the composite (photo-centred, mirrors the morph)
    var onActiveTap: () -> Void = {}    // tap the centred card → collapse back to full screen
    var hideActiveContent = false       // the REAL story covers the centre slot — keep the frame/tap, hide the pixels
    var onInteracting: (Bool) -> Void = { _ in }   // horizontal swipe in flight (drag + settle spring)
    /// The sheet's sideways page-drag IN POINTS (see onPageDrag). Slides the whole row in step with
    /// the sliding panel, so the picture in the slot follows the finger instead of switching at
    /// commit. Converted to card units below with `fullDist`, which is exactly what CarouselScroller
    /// divides a finger's own travel by — so both ways of moving the row move it the same distance.
    var pageDrag: CGFloat = 0
    /// Frames photographed off the live card, by story id — see the host's `frozenCovers`. A story in
    /// here draws THIS instead of its `previewUrl`, because for a video the previewUrl is the poster
    /// and the poster is second zero.
    var frozenCovers: [String: UIImage] = [:]

    @State private var byStory: [String: [StoryViewerInfo]] = [:]   // per-story viewers (counts)
    // Native paged scroll position: the id of the card snapped to centre. Seeded to the opened-on story
    // so the row opens centred on it; SwiftUI's .viewAligned physics follow the finger 1:1 and snap to
    // the nearest card on release (swipe past ~50% → next). It only updates when the scroll SETTLES, so
    // the parent no longer re-renders every frame mid-swipe (that was the jank / "hard to swipe").
    // Custom finger-tracking pager (replaces a .viewAligned ScrollView, which needed a ~50% drag or a
    // hard flick to advance and snapped back otherwise — the "hard to swipe"). `index` is the centred
    // card; the row is a plain offset HStack so the drag follows the finger 1:1 and commits to the next
    // card at just 30%. Seeding `index` in init also kills the old .scrollPosition centring race.
    /// ONE CONTINUOUS POSITION, in card units, and everything is derived from it: 2.0 means card 2
    /// is centred, 2.5 means you are exactly between 2 and 3.
    ///
    /// THIS IS THE FIX FOR THE FLICK (owner 2026-08-04: dragging is smooth, a flick "sticks" and
    /// then continues). It used to be an Int `index` plus the live finger translation, and SwiftUI
    /// cannot interpolate an Int — so on release the index CHANGED AT ONCE, teleporting the cards by
    /// however many steps the flick was worth, and only the leftover finger distance was animated.
    /// The jump was the stick, and the scaling looked choppy because it is computed from the same
    /// number. A CGFloat animates, so position and scale now move together for the whole glide.
    @State private var scroll: CGFloat = 0

    /// The card the carousel considers centred. Derived, never stored: with `scroll` continuous
    /// there is exactly one answer and it cannot drift from what is on screen.
    private var index: Int {
        // `Int(_:)` traps on infinity and NaN rather than clamping. `scroll` is written by a
        // division, and this is read on every layout pass — see the 463 crash for what that costs.
        scroll.isFinite ? max(0, min(max(0, stories.count - 1), Int(scroll.rounded()))) : 0
    }

    init(stories: [Story], activeId: Binding<String>, slotW: CGFloat, slotH: CGFloat, miniH: CGFloat, cropY: CGFloat,
         onActiveTap: @escaping () -> Void = {}, hideActiveContent: Bool = false,
         onInteracting: @escaping (Bool) -> Void = { _ in }, pageDrag: CGFloat = 0,
         frozenCovers: [String: UIImage] = [:]) {
        self.frozenCovers = frozenCovers
        self.stories = stories
        self._activeId = activeId
        self.slotW = slotW
        self.slotH = slotH
        self.miniH = miniH
        self.cropY = cropY
        self.onActiveTap = onActiveTap
        self.hideActiveContent = hideActiveContent
        self.onInteracting = onInteracting
        self.pageDrag = pageDrag
        self._scroll = State(initialValue: CGFloat(stories.firstIndex(where: { $0.id == activeId.wrappedValue }) ?? 0))
    }

    // The settle timer that used to live here is gone: the scroller's own delegate events say
    // exactly when the row has stopped, so the story hand-off no longer waits a guessed beat.

    // Carousel geometry (ported from the reference container). itemSpacing=12;
    // side cards are 54pt narrower (sideVisibleItemWidth); fullItemScrollDistance / halfItemScroll-
    // Distance are the reference metrics; sideVisibleItemScale is the side card's relative
    // scale. Each card's x + scale come straight from the combinedFraction math.
    private var itemSpacing: CGFloat { 12 }
    private var sideW: CGFloat { max(1, slotW - 54) }                          // sideVisibleItemWidth
    /// FLOORED, because `scroll` is computed by dividing by this and `scroll` is then fed to `Int()`.
    /// A zero or negative divisor gives infinity or NaN, and `Int(_:)` on either is a runtime trap,
    /// not a wrong number — the same shape as the crash in build 463. `slotW` is derived from the
    /// screen minus the sheet, so a short screen or a taller sheet could in principle drive it
    /// negative; a floor costs nothing and removes the question.
    private var fullDist: CGFloat { max(1, slotW * 0.5 + itemSpacing + sideW * 0.5) }
    private var halfDist: CGFloat { max(1, sideW * 0.5 + itemSpacing + sideW * 0.5) }
    private var sideRelScale: CGFloat { slotW > 0 ? sideW / slotW : 1 }        // sideVisibleItemScale (relative)

    var body: some View {
        let focusedID = stories.indices.contains(index) ? stories[index].id : activeId
        let active = byStory[focusedID] ?? []
        let activeReacts = active.filter { !($0.reaction ?? "").isEmpty }.count
        let n = stories.count
        VStack(spacing: 12) {
            GeometryReader { geo in
                let centralX = geo.size.width / 2
                ZStack {
                    ForEach(Array(stories.enumerated()), id: \.element.id) { pair in
                        let i = pair.offset
                        let s = pair.element
                        // combinedFraction = (index offset) + scroll fraction. `pageDrag` biases the
                        // whole row while the SHEET is being thrown sideways: finger left → points
                        // negative → effective scroll grows → the NEXT card slides toward the
                        // centre, in step with the panel under the same finger.
                        //
                        // ⚠️ DIVIDED BY `fullDist`, AND THAT DIVISION WAS MISSING. `pageDrag` arrives
                        // in POINTS (its own doc says so, and says it is "converted to card units
                        // below with fullDist"), while `scroll` is in CARD UNITS. Subtracting one
                        // from the other spent every point as a whole card, so a few millimetres of
                        // sheet travel threw the row tens of cards sideways and the position formula
                        // — which saturates past one card — piled them on top of each other at
                        // assorted scales. That is his 2026-08-07 screenshot of the carousel with
                        // five cards overlapping, and it only happens when the SHEET is the thing
                        // being swiped, because a finger on the row itself goes through
                        // `CarouselScroller`, which has always divided by `fullDist` — which is
                        // exactly why he said the row alone "is working good".
                        //
                        // The comment that used to sit here claimed pageDrag was "already a
                        // fraction". It was not, and the property's own doc four hundred lines up
                        // said the opposite. Two comments disagreeing is what hid this.
                        let cf = CGFloat(i) - (scroll - pageDrag / fullDist)
                        let sign: CGFloat = cf < 0 ? -1 : 1
                        let acf = abs(cf)
                        // itemPositionX = centralX + min(1,|cf|)·sign·fullDist + max(0,|cf|-1)·sign·halfDist
                        let posX = centralX
                            + min(1, acf) * sign * fullDist
                            + max(0, acf - 1) * sign * halfDist
                        // scaleFraction = |clamp(cf,-1,1)|; itemScale = centre(1)…side(sideRelScale)
                        let scaleFraction = min(1, acf)
                        let itemScale = 1.0 * (1 - scaleFraction) + sideRelScale * scaleFraction
                        card(s)
                            .scaleEffect(itemScale)
                            .opacity(1.0 - 0.20 * Double(scaleFraction))
                            .position(x: posX, y: slotH / 2)
                            .zIndex(Double(2 - acf))     // centred card on top
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: slotH)
            // TELEGRAM'S ENGINE, not a SwiftUI gesture (owner 2026-08-05: "make it exactly telegram
            // no lag and clear... deep read first"). The overlay owns the row's touches; a hidden
            // UIScrollView's re-homed pan does the physics, willEndDragging snaps to a whole card,
            // and `scroll` is fed continuously from its contentOffset — the same number the cards
            // below already draw from, so the drag, the glide and the scale are one motion on the
            // native deceleration curve. The hand-rolled momentum formula, the engage dead-zone and
            // the settle timer are deleted with the gesture that needed them; settle is now an
            // exact scroll-view event, so the story hand-off happens when the row has actually
            // stopped, not a guessed 0.58s later.
            .overlay {
                CarouselScroller(count: n, fullDist: fullDist, scroll: $scroll,
                                 onInteracting: { on in onInteracting(on) },
                                 onSettled: { i in
                                     if stories.indices.contains(i) { activeId = stories[i].id }
                                 },
                                 onTap: { steps in if steps == 0 { onActiveTap() } })
            }
            // The centred card's count, big + centred under the carousel (mockup).
            countRow(views: active.count, likes: activeReacts, big: true)
        }
        // The CENTRED card is the single source of truth: keep sheetStoryId (activeId) in lockstep with
        // it, so the story behind + the close ALWAYS land on exactly the card you see. Without this the
        // seeded `index` and `activeId` could drift (open on A, close showed B).
        // Watch the POSITION, act on the card it resolves to. `index` is derived now, and a computed
        // property is not something onChange can observe.
        .onChange(of: index) { _, i in
            guard stories.indices.contains(i), stories[i].id != activeId else { return }
            activeId = stories[i].id
        }
        // External retarget (rare) → recentre. The scroller ignores pushed positions while a
        // finger is down (its sync checks isTracking), so this cannot fight a live drag.
        .onChange(of: activeId) { _, v in
            guard let ni = stories.firstIndex(where: { $0.id == v }), ni != index else { return }
            withAnimation(.interactiveSpring(response: 0.30, dampingFraction: 0.82)) { scroll = CGFloat(ni) }
        }
        // Re-seed from the opened-on story in case `stories` was still loading at init.
        .onAppear {
            if let ni = stories.firstIndex(where: { $0.id == activeId }), ni != index { scroll = CGFloat(ni) }
        }
        .task { await loadAll() }
    }

    /// The picture on a carousel card: the frame photographed off the live story if there is one,
    /// otherwise the poster the way it has always been.
    ///
    /// The fill lives INSIDE an overlay of `Color.clear` for the same reason every other fill in this
    /// file does: a bare `scaledToFill` reports its own oversized layout and the ZStack adopts it.
    @ViewBuilder private func cardMedia(_ s: Story) -> some View {
        if let shot = frozenCovers[s.id] {
            Color.clear
                .overlay(Image(uiImage: shot).resizable().scaledToFill())
                .clipped()
        } else {
            StoryImage(url: s.previewUrl, fitBlur: true, bakedBars: false, cardFillThreshold: slotH / slotW)
        }
    }

    private func card(_ s: Story) -> some View {
        let vs = byStory[s.id] ?? []
        let reacts = vs.filter { !($0.reaction ?? "").isEmpty }.count
        // IMAGE + BLUR (build 213, user: keep both): the card is a live StoryImage(fitBlur:) — the
        // whole image over its own blur — exactly what the morph card shows, so the morph→carousel
        // hand-off at full-open is seamless (same view, same size).
        // fitBlur keeps the story exactly as full-screen (user rule: keep image + blur if it has
        // blur; fill with no blur if it doesn't). bakedBars:false = the real live material, so the
        // resting card's dark bars match the story's own bars (the baked copy read weaker).
        // A story with a frozen cover draws that instead — see cardMedia.
        return cardMedia(s)
            .frame(width: slotW, height: slotH)
            .clipped()
            .opacity(hideActiveContent && s.id == activeId ? 0 : 1)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(alignment: .bottom) {
                // Side cards show a small count inside; the CENTRED card hides it (big count below).
                countRow(views: vs.count, likes: reacts, big: false)
                    .padding(.bottom, 10)
                    .visualEffect { content, proxy in
                        content.opacity(Self.centreDistance(proxy) < 0.35 ? 0 : 1)
                    }
            }
            // (Cover-flow scale now comes from the itemScale applied in body — no per-card
            // visualEffect scale here, or it would double.)
            .id(s.id)
            // Taps live on the scroller overlay now (centre card → collapse, side card → native
            // glide to it) — a gesture here would never fire underneath it.
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

// `StoryViewersBottomSheet` lived here. It is UIKit now — see StoryViewersSheetUIKit.swift, which
// explains what the move bought: one pan and one scroll view recognised simultaneously, instead of
// three SwiftUI DragGestures, an arbiter to stop them fighting, a scroll-disable, a bounce-disable
// and a watchdog. The struct is deleted rather than left unreferenced, because a "removed" thing
// that is still in the file is how ClearSegmentedTrack stayed live for two rounds.

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
        let list = repo.conversations.filter { ((Flags.groupsEnabled && $0.isGroup) || !$0.otherUid(me).isEmpty) && !$0.isCleared(me) && (Flags.groupsEnabled || !$0.isGroup) }
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
