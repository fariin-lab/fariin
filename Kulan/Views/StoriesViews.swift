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
    // Fill vs fit. Against the STABLE screen aspect by default (identical to ImageLoader.decideContent
    // Mode, incl. the 0.02 tolerance — so a photo looks the same in the story and the sheet), OR
    // against cardFillThreshold when a (shorter) card passes its own aspect, so an image as tall as
    // the card fills it with no side bars.
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

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: storySpacing) {
                myCard
                    .id("my-story")   // STABLE identity so its "Add Story/Posted Stories" menu never binds
                                      // to a friend card when the row re-sorts (SwiftUI context-menu bug).
                ForEach(orderedOthers) { g in
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
                    .matchedTransitionSource(id: "my-story", in: storyNS)   // hero source for the native zoom close
            } else {
                // Cover = last story, else the profile photo fills the card (user rollback
                // 2026-07-22: they prefer the full-photo look). No photo at all → centered circle.
                card(cover: repo.mine?.stories.last?.previewUrl ?? mePhoto,
                     name: "My Story", avatarName: meName, avatar: mePhoto,
                     seen: StoryPrefs.seenFlags(repo.mine?.stories ?? [], upTo: repo.mine?.lastViewedAt), onBadge: onCompose) {
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

                UploadingAvatarRing(name: meName, photoUrl: mePhoto)   // my avatar + clean spinning ring
                    // The same shadow `card()` puts under every other circle in the row. Without it
                    // this one sat flat on the photo while its neighbours lifted off theirs, which is
                    // the last way the uploading circle differed from the one it turns into.
                    .shadow(color: .black.opacity(0.28), radius: 2, y: 1)
                    .padding(8)
            }
            Text("Uploading…").font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).frame(width: cardW)
        }
        .frame(width: cardW)
    }

    // avatarName: what the LETTER CIRCLE falls back to when there's no photo. The my-card's
    // label is "My Story" but its circle must use the user's real name — label-as-avatar-name
    // drew a purple "M" while Edit Profile drew the correct initial (user's device report).
    private func card(cover: String?, name: String, avatarName: String? = nil, avatar: String?, seen: [Bool],
                      onBadge: (() -> Void)? = nil, tap: @escaping () -> Void) -> some View {
        // Button (not onTapGesture) so the caller's .contextMenu long-press fires reliably.
        Button(action: tap) {
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
            Text(name).font(.system(size: 12)).lineLimit(1).frame(width: cardW)
        }
        .frame(width: cardW)
        .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
            // Lift the card AS IT LOOKS — avatar ring included. A bare photo made the small
            // circle visibly vanish during the lift (user report).
            ZStack(alignment: .bottomLeading) {
                coverView
                    .frame(width: cardW, height: cardH)
                AvatarView(name: name, photoUrl: avatar, size: 32)
                    .overlay { if !seen.isEmpty { StoryRingView(seen: seen).frame(width: 37, height: 37) } }
                    .shadow(color: .black.opacity(0.28), radius: 2, y: 1)
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
    let groups: [StoryGroup]
    var startIndex: Int = 0
    var anonymous: Bool
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
    @State private var closeDragStart: CGFloat? = nil // progress at grab for the backdrop collapse drag
    // SINGLE-OWNER drag arbiter: `viewersProgress` may be written by three drag handlers (sheet
    // header, sheet list, backdrop collapse) each with its OWN grab anchor. When iOS cancels a drag
    // mid-flight (no onEnded!) its anchor went stale, and a later touch could engage TWO handlers
    // whose anchors disagree — they alternated writes EVERY FRAME (frame-measured: the whole layout
    // ping-ponged ~90pt between two states = the violent sheet "vibrating / two sheets fighting").
    // The arbiter lets exactly ONE handler write at a time; a claim after >0.25s of silence is
    // FRESH and forces re-anchoring at the CURRENT progress, healing stale anchors for free.
    // A class held in @State: mutating it never invalidates the view (no re-render mid-gesture).
    final class SheetDragArbiter {
        enum Claim { case fresh, continuing }
        private var owner: String?
        private var lastEvent = Date.distantPast
        var onFreshClaim: (() -> Void)?   // StoryViewer hooks this to cancel a running snap animation
        func claim(_ id: String) -> Claim? {
            let now = Date()
            defer { lastEvent = now }
            if owner == id {
                if now.timeIntervalSince(lastEvent) > 0.25 { onFreshClaim?(); return .fresh }
                return .continuing
            }
            if owner == nil || now.timeIntervalSince(lastEvent) > 0.25 { owner = id; onFreshClaim?(); return .fresh }
            return nil
        }
        func release(_ id: String) { if owner == id { owner = nil } }
        // A finger is actively driving progress (events within the fresh-claim window).
        var ownedRecently: Bool { owner != nil && Date().timeIntervalSince(lastEvent) < 0.25 }
    }
    @State private var sheetDragArbiter = SheetDragArbiter()
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

        func animate(from: CGFloat, to: CGFloat,
                     write: @escaping (CGFloat) -> Void, completion: (() -> Void)? = nil) {
            cancel()
            current = from; target = to; velocity = 0
            self.write = write; self.completion = completion
            let l = CADisplayLink(target: self, selector: #selector(tick(_:)))
            l.add(to: .main, forMode: .common)
            link = l
        }
        func cancel() { link?.invalidate(); link = nil; write = nil; completion = nil }
        @objc private func tick(_ l: CADisplayLink) {
            let dt = CGFloat(min(l.targetTimestamp - l.timestamp, 1.0 / 30.0))
            // Critically-damped spring, feel-matched to interactiveSpring(response: ~0.34).
            let k: CGFloat = 340
            velocity += (k * (target - current) - 2 * sqrt(k) * velocity) * dt
            current += velocity * dt
            if abs(target - current) < 0.001, abs(velocity) < 0.02 {
                current = target
                write?(current)
                let done = completion
                cancel()
                done?()
                return
            }
            write?(current)
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

    init(group: StoryGroup, anonymous: Bool = false, ownSwipeDismiss: Bool = false,
         onClose: @escaping () -> Void,
         onProfile: @escaping (StoryGroup) -> Void = { _ in },
         onDeletedRemaining: @escaping (StoryGroup) -> Void = { _ in }) {
        self.init(groups: [group], startIndex: 0, anonymous: anonymous, ownSwipeDismiss: ownSwipeDismiss,
                  onClose: onClose, onProfile: onProfile,
                  onDeletedRemaining: onDeletedRemaining)
    }
    init(groups: [StoryGroup], startIndex: Int = 0, anonymous: Bool = false, ownSwipeDismiss: Bool = false,
         onClose: @escaping () -> Void,
         onProfile: @escaping (StoryGroup) -> Void = { _ in },
         onDeletedRemaining: @escaping (StoryGroup) -> Void = { _ in }) {
        self.groups = groups
        self.startIndex = startIndex
        self.anonymous = anonymous
        self.ownSwipeDismiss = ownSwipeDismiss
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
                        // Video runs its REAL length (the player refines it from the loaded asset);
                        // photos keep the 5s standard.
                        duration: s.isVideo && s.duration > 0.5 ? s.duration : 5,
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
            if showViewers {
                StoryViewersBottomSheet(activeStoryId: sheetStoryId,
                                        progress: $viewersProgress,
                                        arbiter: sheetDragArbiter,
                                        onSnapOpen: { sheetAnimator.animate(from: viewersProgress, to: 1,
                                                                            write: { viewersProgress = $0 }) },
                                        onClose: closeViewers)
            }
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
        .onReceive(NotificationCenter.default.publisher(for: .init("storyActionSave"))) { _ in
            if currentStory?.isVideo == true { saveCurrentVideo(currentStory?.mediaUrl) }
            else { saveCurrentImage(currentStory?.mediaUrl) }
        }
        // Forward/Share pipelines are image-based (they re-encode a UIImage); on a video story they
        // would silently do nothing. Say so honestly instead — proper video forward/share comes later.
        .onReceive(NotificationCenter.default.publisher(for: .init("storyActionForward"))) { _ in
            guard currentStory?.isVideo != true else { flashSentToast("Not available for videos yet"); return }
            let u = currentStory?.mediaUrl
            Task { if let img = await loadCurrentImage(u) { forwardImg = StoryImagePayload(image: img) } }
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("storyActionShare"))) { _ in
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
        // A fresh drag claim takes over from any in-flight snap animation (finger beats spring).
        .onAppear { sheetDragArbiter.onFreshClaim = { sheetAnimator.cancel() } }
        // Safety net: the sheet unmounting must NEVER leave a stray progress value behind
        // (a tiny leftover hid the owner footer with no sheet in sight — user screenshot).
        .onChange(of: showViewers) { _, on in
            if on {
                // Photograph every story's full-screen render offscreen (app-switcher pattern)
                // so each card shows NATIVE pixels the moment it appears. Same media height as
                // the live viewer (audit M1) and STAGGERED — parallel material renders during
                // the opening spring caused hitching.
                let mediaH = morphContentH
                for (i, s) in (StoriesRepository.shared.mine?.stories ?? myStories).enumerated() {
                    if s.isVideo && s.id == currentStoryId {
                        // Video: photograph the CURRENT playing frame (the active PlayerView answers)
                        // so the morph card matches where the video is, not its first-frame poster.
                        NotificationCenter.default.post(name: .init("captureStoryFrame"), object: s.previewUrl)
                    } else {
                        DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.12) {
                            StorySnapshotFactory.warm(urlString: s.previewUrl, contentHeight: mediaH)
                        }
                    }
                }
            } else {
                sheetAnimator.cancel(); viewersProgress = 0
                NotificationCenter.default.post(name: .init("storyUnfreezeBlur"), object: nil)
            }
        }
        // SELF-HEALING for a PARKED sheet (user video: sheet resting at ~73% open — story stuck
        // as a giant half-morphed card, carousel never faded in). Two ways to get parked: a
        // system-CANCELLED drag skips onEnded so no snap ever fires, and a stray touch during
        // the open spring kills the animator via the arbiter's fresh-claim hook. Every write
        // re-arms this; if progress then sits mid-air untouched for 0.8s — no finger writes,
        // no animator ticks — snap to the nearest rest state.
        .onChange(of: viewersProgress) { _, p in rearmProgressWatchdog(p) }
        // Safety net: never leave a story paused after the viewer goes away (the swipe-down dismiss posts
        // pauseStory and does not resume on commit; a sheet up at teardown can also skip the resume).
        .onDisappear {
            sheetAnimator.cancel()
            NotificationCenter.default.post(name: .init("resumeStory"), object: nil)
            NotificationCenter.default.post(name: .init("storyChromeHidden"), object: false)
            NotificationCenter.default.post(name: .init("storyUnfreezeBlur"), object: nil)
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
                                .lineLimit(4)   // don't let a long caption climb over the whole photo (caption cap)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 16).padding(.top, 26).padding(.bottom, 14)
                                .background(LinearGradient(colors: [.clear, .black.opacity(0.45)],
                                                           startPoint: .top, endPoint: .bottom))
                                .opacity((dragDown > 6 || (showViewers && viewersProgress > 0.05)) ? 0 : 1)
                                .animation(.easeOut(duration: 0.15), value: dragDown > 6)
                                .animation(.easeOut(duration: 0.15), value: showViewers && viewersProgress > 0.05)
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
                    // Hidden on swipe-down AND while the sheet is REALLY engaged (showViewers
                    // gate: a stray leftover progress value once hid the Views/Delete bar with
                    // no sheet in sight — the tab bar showed through the empty strip).
                    .opacity((dragDown > 6 || (showViewers && viewersProgress > 0.05)) ? 0 : 1)
                    .animation(.easeOut(duration: 0.15), value: dragDown > 6)
                    .animation(.easeOut(duration: 0.15), value: showViewers && viewersProgress > 0.05)
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
        // THE REAL STORY IS THE MORPH (user's final call — no duplicate card, ever): the
        // original story layer itself scales from full screen into the carousel's centre
        // slot, driven by the drag. Same pixels the whole way — nothing can mismatch.
        // PERFORMANCE: mid-drag the story moves by scale+offset ONLY (pure GPU transforms).
        // Re-clipping the live-material story with a changing radius EVERY finger frame was
        // the "follows then stutters" jank — corners now apply only once the card has
        // SETTLED into the slot (p ≥ 0.97, static), matching the carousel cards' 24pt.
        // FINGER-TRACKED NATIVE ZOOM (user request): the story's scale + position interpolate 1:1
        // with viewersProgress — the SAME value that drives the sheet — so the image, the sheet,
        // and the finger all move together in real time (no fixed-duration animation, no "sheet
        // first then image" delay). There is deliberately NO .animation here: during the drag the
        // image tracks the finger directly; on release the sheet's own spring animates
        // viewersProgress and the image rides that spring home (the native-feeling settle).
        // Minimal: a clean lerp between full-screen (frac 0) and the card slot (frac 1).
        // The zoom (ported verbatim from the reference container): the story content
        // is scaled about its OWN CENTRE and its CENTRE is moved to the card slot — NOT anchored to
        // the top with a separate offset and a trimming clip. The reference:
        //   currentContentScale = contentMinScale * fraction + 1.0 * (1 - fraction)
        //   transform = CATransform3DMakeScale(scale, scale, 1)   // about the layer centre
        //   setPosition(contentContainerView, contentFrame.centre) // move the centre
        //   cornerRadius = 12.0 / scale
        // Centre-anchored scaling makes the top edge move INWARD (down) as it shrinks, so it can
        // never break out upward — that top-anchor was the shared root cause of both prior versions.
        // BUILD 213: the live story is NOT transformed at all — it simply FADES OUT over the first
        // 8% of the pull (a hair kept alive during an open drag so the gesture keeps tracking),
        // and the morph card in viewersBackdrop takes over the visual zoom. No scaleEffect / offset
        // / trimming clip on the live story = no top break-out, no snap.
        .opacity(max(openDragging ? 0.02 : 0, 1 - Double(min(viewersProgress / 0.08, 1))))
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
            isPresented: $isPresented,
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
            // Anonymous viewing leaves NO trace (incognito / anonymous): no local flags either.
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
                sheetAnimator.cancel()   // the finger owns progress; kill any in-flight snap
                let sheetH = UIScreen.main.bounds.height * StoryViewersBottomSheet.heightFraction
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
                let sheetH = UIScreen.main.bounds.height * StoryViewersBottomSheet.heightFraction
                // Build 216's exact release rule (the feel the user wants): fling weight 0.3,
                // open past 0.4 — a modest upward pull commits, a small nudge settles back.
                let projected = viewersProgress + (velocity / sheetH) * 0.3
                if projected > 0.4 {
                    sheetAnimator.animate(from: viewersProgress, to: 1, write: { viewersProgress = $0 })
                } else {
                    closeViewers()
                }
            },
            dismissEnabled: ownSwipeDismiss,   // zoom presentations: Apple's dismiss ONLY (user's final call);
                                               // reply-quote presentations have no zoom — the library pan closes
            swipeUpEnabled: true   // library's DirectionalPan(.up) owns swipe-up: with the direction-sign
                                   // fix it fires reliably, and it FAILS cleanly on downward drags — unlike
                                   // the removed SwiftUI DragGesture whose activation cancelled the down pan
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

    // The REAL story's morph into the carousel slot — geometry MUST mirror viewersBackdrop's
    // slot math exactly, so the shrunk story lands pixel-on the (hidden) centre card.
    // UNIFORM scale (aspect-true — the slot has the story's real shape, so the story lands
    // on it exactly; no stretch means hand-offs can never change the picture's size/shape).
    // (Fixed-aspect cards retired for good — the core rule: the card is the zoom's
    // endpoint, the story's own shape. Any fixed card shape forces trimming or a settle
    // mismatch; both were user-rejected.)

    private var morphGeometry: (sizeP: CGFloat, scaleX: CGFloat, scaleY: CGFloat, offsetY: CGFloat, topCut: CGFloat, botCut: CGFloat) {
        let p = viewersProgress
        let scr = UIScreen.main.bounds
        let sheetH = scr.height * StoryViewersBottomSheet.heightFraction
        let avail = scr.height - sheetH - topInset
        let countArea: CGFloat = 40
        let slotH = (avail - countArea) * 0.94
        let blockTop = topInset + (avail - countArea - slotH) / 2
        // 1:1 WITH THE FINGER (user: one small jump mid-swipe, both ways): the shrink used to
        // run only across p 0.08→0.9, so the photo sat FULL until 8% pulled (start dead zone),
        // then jumped into motion — and on close it finished at 0.08 and waited (settle jump).
        // Now it tracks the sheet from the FIRST pixel (0 → 0.9), so it grows/shrinks in
        // lockstep with the drag, no dead zone at either end. Upper bound kept at 0.9 so the
        // carousel hand-off is untouched.
        let sizeP = max(0, min(1, p / 0.9))
        let contentH = scr.height - (mineOnly ? Self.ownerFooterHeight + max(10, bottomInset) : 0)
        // Core rule: pure uniform zoom of the whole story, centre-anchored, zero cuts.
        // The landing scale (slotH/contentH) makes the story exactly the card's size — the
        // settle swap is pixel-identical, so the image can never jump.
        let s1 = slotH / max(contentH, 1)
        let s = 1 - (1 - s1) * sizeP
        let restCentre = contentH / 2
        let targetCentre = blockTop + slotH / 2
        let centre = restCentre + (targetCentre - restCentre) * sizeP
        return (sizeP, s, s, centre - restCentre * s, 0, 0)
    }
    private var morphScale: CGFloat { morphGeometry.scaleY }
    private var morphOffsetY: CGFloat { morphGeometry.offsetY }

    // FINGER-TRACKED NATIVE ZOOM. `storyZoomFrac` is viewersProgress clamped 0…1 — the fraction of
    // the way from full-screen to the card. The story reads it directly (no animation), so it
    // tracks the finger exactly like the sheet; on release the sheet's spring drives viewersProgress
    // and the story rides it home. The endpoint mirrors the carousel slot exactly (scale =
    // slotH/contentH, offset = blockTop) so the story lands on the card's size/position.
    private var storyZoomFrac: CGFloat { max(0, min(1, viewersProgress)) }   // = the content scale fraction
    // Zoom parameters. scale = contentMinScale·frac + 1·(1-frac); anchorY = the media's
    // own centre as a fraction of the full-screen layer (so the scale pivots on the content
    // centre); centreShift = how far to move that centre to land on the card slot's centre.
    private var tgZoom: (scale: CGFloat, anchorY: CGFloat, centerShift: CGFloat) {
        let scr = UIScreen.main.bounds
        let sheetH = scr.height * StoryViewersBottomSheet.heightFraction
        let avail = scr.height - sheetH - topInset
        let countArea: CGFloat = 40
        let slotH = (avail - countArea) * 0.94
        let blockTop = topInset + (avail - countArea - slotH) / 2
        let contentH = scr.height - (mineOnly ? Self.ownerFooterHeight + max(10, bottomInset) : 0)
        let minScale = slotH / max(contentH, 1)                       // contentMinScale
        let s = minScale * storyZoomFrac + 1.0 * (1 - storyZoomFrac)  // the standard formula
        let mediaCenterRest = contentH / 2                           // content centre at rest
        let mediaCenterTarget = blockTop + slotH / 2                 // slot centre
        return (s, mediaCenterRest / scr.height,
                (mediaCenterTarget - mediaCenterRest) * storyZoomFrac)
    }
    // The story CONTENT's height (photo card without the footer) — the clip must end HERE,
    // not at the layer's true bottom (which extends into the faded footer area below the
    // photo: rounding down there left the VISIBLE bottom corners square, user report).
    private var morphContentH: CGFloat {
        UIScreen.main.bounds.height - (mineOnly ? Self.ownerFooterHeight + max(10, bottomInset) : 0)
    }
    // Radius in UNSCALED space so it reads ~24pt constant on screen; 0 at rest (no-op).
    private var morphClipRadius: CGFloat {
        let g = morphGeometry
        return g.sizeP <= 0.001 ? 0 : 24 / max(g.scaleY, 0.2) * g.sizeP
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
        // slotHRef = the aspect-true reference height; it DEFINES the width so W stays exactly as
        // before. slotH = a modestly SHORTER card (user: "each one is too long — only touch H, and
        // don't cut too much"). Because slotW is tied to the taller reference, the card keeps its
        // width and just loses a little height; the story is CENTER-CROPPED to fill it (the cards
        // render in fill mode below), so there are no side blur bars.
        let contentH = scr.height - (mineOnly ? Self.ownerFooterHeight + max(10, bottomInset) : 0)
        // BUILD 249 card size (user: "make it exactly like 249, 250 is too long"): 12% shorter than
        // aspect-true. slotW comes from the aspect-true reference so the WIDTH is unchanged; only the
        // height is cut. A shorter card is WIDER than the screen aspect, which would make a near-
        // full-screen image narrower than the card → fitBlur would add SIDE blur bars. The fix is
        // NOT a taller card but deciding fill-vs-blur against the CARD's own aspect (cardFillThreshold
        // = slotH/slotW below): any image at least as tall as the card FILLS (no side bars), only
        // clearly wide/square images keep top/bottom blur — so 249's size AND no side bars.
        let slotHRef = (avail - countArea) * 0.94
        let slotW = slotHRef * (scr.width / max(contentH, 1))
        let slotH = slotHRef * 0.88
        let miniH = slotW * (scr.height / scr.width)
        let cropY: CGFloat = 0
        let blockTop = topInset + (avail - countArea - slotH) / 2
        // BUILD 213 staging (image + blur morph card that FRAME-INTERPOLATES full-screen → slot):
        //  • morphVis: the morph card fades IN OPAQUE 0→0.05 (over the fading story), holds, fades
        //    OUT 0.95→1 into the live carousel centre card.
        //  • sizeP: the card's FRAME shrinks 0.08→0.9 (StoryImage(fitBlur:) re-renders image+blur
        //    cleanly at every size — no scaleEffect, so nothing can break out or snap).
        //  • carIn: neighbours + counts fade in 0.9→1 behind the opaque morph card.
        let sizeP = max(0, min(1, (p - 0.08) / (0.9 - 0.08)))
        // Carousel is fully opaque by p=0.97 (see morphVis) so the morph→carousel hand-off is a clean
        // swap between two IDENTICAL live-material cards, never a fractional-opacity crossfade.
        let carIn = max(0, min(1, (p - 0.9) / 0.07))
        // The morph card is now LIVE material (bakedBars:false) so its blur is IDENTICAL to the
        // full-screen story's — the baked copy read lighter/weaker (user: "blur weakens when I scroll
        // up, keep the original blur"). A live UIVisualEffectView drops its blur at FRACTIONAL
        // opacity, so morphVis is strictly BINARY (0 or 1) — never a crossfade: it pops opaque at
        // p>0.001 (pixel-identical to the story, invisible) and HARD-hides at p≥0.97 once the carousel
        // (also live, same size) is fully opaque behind it. No fractional opacity anywhere = no flash.
        let morphVis = (p > 0.001 && p < 0.97) ? 1.0 : 0.0
        // Feed the carousel from the LIVE repo (not the viewer's immutable snapshot), so a story
        // deleted while viewing doesn't linger as a ghost card. Fall back to the snapshot.
        let liveMyStories = StoriesRepository.shared.mine?.stories ?? myStories
        let morphURL = (currentStory ?? liveMyStories.first { $0.id == sheetStoryId }).map { $0.previewUrl }
        ZStack(alignment: .top) {
            MyStoriesCarousel(stories: liveMyStories, activeId: $sheetStoryId,
                              slotW: slotW, slotH: slotH, miniH: miniH, cropY: cropY,
                              onActiveTap: { closeViewers() })
                .padding(.top, blockTop)
                .opacity(Double(carIn))
                .allowsHitTesting(carIn > 0.5)
            if morphVis > 0.001, let url = morphURL {
                // The morph card FRAME-lerps full-screen → slot. fitBlur KEEPS the story exactly as it
                // looks full-screen (user rule): a story WITH blur bars keeps its image AND its blur;
                // a full-bleed story just fills (no blur added). bakedBars = static blur for the
                // crossfade (a live material breaks at fractional opacity).
                let startH = scr.height - (mineOnly ? Self.ownerFooterHeight + max(10, bottomInset) : 0)
                let mW = lerp(scr.width, slotW, sizeP)
                let mH = lerp(startH, slotH, sizeP)
                // Fill/blur decided against the morph's CURRENT frame aspect (screen-shaped at the
                // start of the pull → card-shaped at the end), so at pull-start the morph matches the
                // full-screen story (letterboxed = keeps its blur) and by the card it fills (no side
                // bars). A fixed card threshold would make a letterboxed story FILL from the first
                // pixel — its blur bars would vanish as you drag, reading as "the blur disappears".
                StoryImage(url: url, fitBlur: true, bakedBars: false, cardFillThreshold: mH / mW)
                    .frame(width: mW, height: mH)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .padding(.top, blockTop * sizeP)
                    .frame(maxWidth: .infinity)
                    .opacity(Double(morphVis))
                    .allowsHitTesting(false)
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
                    // ONE writer at a time (see SheetDragArbiter). A fresh claim re-anchors at the
                    // CURRENT progress, so a stale anchor from a cancelled drag can never jump/fight.
                    guard let claim = sheetDragArbiter.claim("backdrop") else { return }
                    let h = UIScreen.main.bounds.height * StoryViewersBottomSheet.heightFraction
                    if claim == .fresh || closeDragStart == nil {
                        closeDragStart = viewersProgress + v.translation.height / h   // anchor so current touch maps to current progress
                    }
                    var next = max(0, min(1, (closeDragStart ?? 1) - v.translation.height / h))
                    // Same stale-anchor teleport guard as the sheet drag: a cancelled stroke's
                    // leftover anchor must never let the next stroke's first event jump the story.
                    if abs(next - viewersProgress) > 0.12 {
                        closeDragStart = viewersProgress + v.translation.height / h
                        next = viewersProgress
                    }
                    viewersProgress = next
                }
                .onEnded { v in
                    sheetDragArbiter.release("backdrop")
                    guard let start = closeDragStart else { return }   // guarded-out drag (horizontal) → not ours
                    closeDragStart = nil
                    let h = UIScreen.main.bounds.height * StoryViewersBottomSheet.heightFraction
                    let projected = start - v.predictedEndTranslation.height / h
                    // 0.8 (was 0.6): demanding nearly half the sheet's travel made ordinary drags
                    // bounce back over and over ("scroll down to close is soo hard"). A deliberate
                    // downward pull now commits; only a tiny nudge springs back.
                    if projected < 0.8 { closeViewers() }   // collapse → story reopens full screen
                    else { sheetAnimator.animate(from: viewersProgress, to: 1, write: { viewersProgress = $0 }) }
                }
        )
        .ignoresSafeArea()
    }
    private func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }

    private func openViewers() {
        // Re-open allowed even while the previous close is still unmounting: animating progress back
        // to 1 cancels the close animator (and with it the unmount completion) — no more
        // "swipe up does nothing for 0.42s after closing".
        guard currentIsMine else { return }
        closeDragStart = nil   // never let a cancelled drag leave a stale anchor
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
    // Reference-exact (user's final call): the centre is the REAL story scaled as ONE living
    // unit — through the drag AND at rest. No stand-in card renderer, no trimming, no
    // re-framing. (The settle stand-in existed to mask geometry mismatches now fixed at the
    // root: aspect-true zoom endpoint == card size, factory frames at contentH, freeze
    // overlays cropped 1:1.) The story steps aside ONLY while the carousel is actively
    // swiping; its backdrop is FROZEN pixels (storyFreezeBlur), so scaling never re-blurs.
    private var storyLayerSteppedAside: Bool {
        carouselInteracting && viewersProgress > 0.9
    }
    private var hideCarouselCentreContent: Bool { !carouselInteracting }

    // See the .onChange(of: viewersProgress) note: parked-sheet self-heal.
    private func rearmProgressWatchdog(_ p: CGFloat) {
        progressWatchdog?.cancel(); progressWatchdog = nil
        guard showViewers, p > 0.02, p < 0.995 else { return }
        progressWatchdog = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled, showViewers,
                  viewersProgress > 0.02, viewersProgress < 0.995,
                  // Never snap under a LIVE finger (audit M3): a held-still drag writes nothing
                  // for 0.8s but is still owned; a cancelled drag's stale owner goes quiet and
                  // the heal proceeds.
                  !openDragging, closeDragStart == nil, !sheetDragArbiter.ownedRecently
            else { return }
            if viewersProgress >= 0.5 {
                sheetAnimator.animate(from: viewersProgress, to: 1, write: { viewersProgress = $0 })
            } else {
                closeViewers()
            }
        }
    }

    private func closeViewers() {
        closeDragStart = nil   // never let a cancelled drag leave a stale anchor
        sheetAnimator.animate(from: viewersProgress, to: 0, write: { viewersProgress = $0 }) {
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
        let cid = [me, s.authorUid].sorted().joined(separator: "_")
        // Attach the status reference so the reply shows as a "Status" quote (thumbnail) in chat.
        let ref = ReplyRef(id: s.id, authorId: s.authorUid, text: "", isStatus: true, storyThumbUrl: s.previewUrl)
        let isReaction = typed == nil && (emoji != nil || isLiked)
        Task {
            try? await ChatService.sendText(cid: cid, text: text, replyTo: ref)
            if isReaction { await StoriesService.shared.setStoryReaction(s, emoji: text) }   // shows in "Seen by"
        }
        flashSentToast()   // optimistic "Sent" confirmation
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

    // Owner bar: overlapping viewer avatars + "N Views" + ❤️ reactions (tap → sheet) + delete.
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
// One story card's pixels: the NATIVE snapshot of its full-screen render (photo + real
// material bars, photographed by StorySnapshotFactory — the app-switcher pattern). Until the
// offscreen render lands (first frames only), a plain photo crop stands in, then swaps.
private struct SnapshotCardContent: View {
    let url: String
    let slotW: CGFloat
    let miniH: CGFloat
    @State private var snap: UIImage?
    var body: some View {
        Group {
            if let snap {
                Image(uiImage: snap).resizable()
                    .frame(width: slotW, height: miniH)
            } else {
                // Fit composite stand-in — the same framing the snapshot will have, so the
                // swap-in is invisible (a fill-crop stand-in visibly popped, audit finding 5).
                StoryImage(url: url, fitBlur: true)
                    .frame(width: slotW, height: miniH)
            }
        }
        .onAppear { snap = StoryCompositeCache.image(for: url) }
        .onReceive(NotificationCenter.default.publisher(for: .init("storySnapshotReady"))) { n in
            guard (n.object as? String) == url else { return }
            snap = StoryCompositeCache.image(for: url)   // later (corrected) captures replace earlier ones
        }
    }
}

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
    @State private var scrollAtDragStart: CGFloat = 0
    @State private var dragging = false

    /// The card the carousel considers centred. Derived, never stored: with `scroll` continuous
    /// there is exactly one answer and it cannot drift from what is on screen.
    private var index: Int {
        max(0, min(max(0, stories.count - 1), Int(scroll.rounded())))
    }

    init(stories: [Story], activeId: Binding<String>, slotW: CGFloat, slotH: CGFloat, miniH: CGFloat, cropY: CGFloat,
         onActiveTap: @escaping () -> Void = {}, hideActiveContent: Bool = false,
         onInteracting: @escaping (Bool) -> Void = { _ in }) {
        self.stories = stories
        self._activeId = activeId
        self.slotW = slotW
        self.slotH = slotH
        self.miniH = miniH
        self.cropY = cropY
        self.onActiveTap = onActiveTap
        self.hideActiveContent = hideActiveContent
        self.onInteracting = onInteracting
        self._scroll = State(initialValue: CGFloat(stories.firstIndex(where: { $0.id == activeId.wrappedValue }) ?? 0))
    }

    @State private var interactGen = 0   // invalidates a stale "settled" callback when a new swipe starts
    // Swipe finished settling → hand the centre back to the real story (identical pixels = invisible swap).
    /// `after`: how long the glide that just started will take. The hand-off has to wait for the
    /// card to actually stop — handing the centre back to the real story on a still-moving card was
    /// a logged bug, and a long flick now glides for longer than the old fixed 0.55s allowed.
    private func endInteractionSoon(after: Double = 0.42) {
        interactGen += 1
        let gen = interactGen
        // The spring's tail outlives its response: a 1-3pt drift was still visible well after the
        // stated duration, which is why this waits a beat past it rather than exactly for it.
        DispatchQueue.main.asyncAfter(deadline: .now() + after + 0.16) {
            if gen == interactGen, !dragging { onInteracting(false) }
        }
    }

    // Carousel geometry (ported from the reference container). itemSpacing=12;
    // side cards are 54pt narrower (sideVisibleItemWidth); fullItemScrollDistance / halfItemScroll-
    // Distance are the reference metrics; sideVisibleItemScale is the side card's relative
    // scale. Each card's x + scale come straight from the combinedFraction math.
    private var itemSpacing: CGFloat { 12 }
    private var sideW: CGFloat { max(1, slotW - 54) }                          // sideVisibleItemWidth
    private var fullDist: CGFloat { slotW * 0.5 + itemSpacing + sideW * 0.5 }  // fullItemScrollDistance
    private var halfDist: CGFloat { sideW * 0.5 + itemSpacing + sideW * 0.5 }  // halfItemScrollDistance
    private var sideRelScale: CGFloat { sideW / slotW }                        // sideVisibleItemScale (relative)

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
                        // combinedFraction = (index offset) + scroll fraction.
                        let cf = CGFloat(i) - scroll
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
            .contentShape(Rectangle())
            .simultaneousGesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { v in
                        if !dragging {
                            // Engage almost immediately (5pt, was 12) so the cards start tracking the
                            // finger right away — the 12pt dead-zone read as laggy.
                            guard abs(v.translation.width) > 5,
                                  abs(v.translation.width) > abs(v.translation.height) * 1.2 else { return }
                            dragging = true
                            scrollAtDragStart = scroll
                            interactGen += 1
                            onInteracting(true)
                        }
                        // 1:1 finger tracking, expressed as a position rather than an offset, so the
                        // release below has nothing to convert.
                        scroll = scrollAtDragStart - v.translation.width / fullDist
                    }
                    .onEnded { v in
                        let wasDragging = dragging
                        dragging = false
                        if !wasDragging {
                            // A fast flick that never crossed the engage gate still turns the page —
                            // otherwise it's a tap: engage so the momentum path below runs.
                            if abs(v.predictedEndTranslation.width) < fullDist * 0.15 { return }
                            scrollAtDragStart = scroll
                            onInteracting(true)
                        }
                        // MOMENTUM: predictedEndTranslation already carries the gesture VELOCITY (UIKit
                        // projects where the finger would coast to). Convert that projected landing to
                        // card-steps so a quick flick GLIDES across as many cards as the fling would
                        // carry (capped so it never flies off), and a gentle pull past ~40% advances one.
                        let predicted = v.predictedEndTranslation.width
                        let hardSteps = Int((predicted / fullDist).rounded())          // velocity-driven
                        let softStep = abs(v.translation.width) > fullDist * 0.4        // gentle-drag commit
                            ? (v.translation.width < 0 ? -1 : 1) : 0
                        var steps = abs(hardSteps) >= 1 ? hardSteps : softStep
                        steps = max(-6, min(6, steps))                                  // never fly off
                        // Drag/flick RIGHT (+) reveals the PREVIOUS card → the position decreases.
                        let ni = max(0, min(n - 1, Int((scrollAtDragStart).rounded()) - steps))
                        // ONE animation on ONE number, so every card's x AND scale are interpolated by
                        // the same curve for the whole glide — which is the whole point: the scaling
                        // can no longer stutter, because it is the same value that is moving.
                        //
                        // The further the flick throws it, the longer it is given to get there, so a
                        // four-card fling decelerates instead of arriving at the speed of a one-card
                        // nudge. Damping 0.86 lands without a wobble at these distances.
                        let travel = abs(CGFloat(ni) - scroll)
                        let response = min(0.62, 0.34 + Double(travel) * 0.07)
                        withAnimation(.spring(response: response, dampingFraction: 0.86)) {
                            scroll = CGFloat(ni)
                        }
                        if stories.indices.contains(ni) { activeId = stories[ni].id }
                        endInteractionSoon(after: response)
                    }
            )
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
        // External retarget (rare) → recentre, but never while the finger is dragging.
        .onChange(of: activeId) { _, v in
            guard !dragging, let ni = stories.firstIndex(where: { $0.id == v }), ni != index else { return }
            withAnimation(.interactiveSpring(response: 0.30, dampingFraction: 0.82)) { scroll = CGFloat(ni) }
        }
        // Re-seed from the opened-on story in case `stories` was still loading at init.
        .onAppear {
            if let ni = stories.firstIndex(where: { $0.id == activeId }), ni != index { scroll = CGFloat(ni) }
        }
        .task { await loadAll() }
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
        return StoryImage(url: s.previewUrl, fitBlur: true, bakedBars: false, cardFillThreshold: slotH / slotW)
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
            .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))   // tappable even with hidden content
            .onTapGesture {
                if s.id == activeId { onActiveTap() }
                else if let ni = stories.firstIndex(where: { $0.id == s.id }) {
                    onInteracting(true)   // tap-to-recentre animates cards too — same hand-off dance
                    withAnimation(.interactiveSpring(response: 0.4, dampingFraction: 0.84)) { index = ni }
                    activeId = s.id
                    endInteractionSoon()
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

// The reference viewers-sheet architecture: a SEPARATE bottom layer holding ONLY the drag handle, search,
// and the scrollable viewer list — NO story media (the carousel above it is its own layer). It drives
// `progress` (0 closed … 1 open); the StoryViewer's backdrop reads the same value → always in sync.
struct StoryViewersBottomSheet: View {
    // Sheet height as a fraction of the screen. The story viewer derives the carousel slot from this
    // same value, so the two layers always agree on the layout. The design makes the LIST the dominant
    // element (~70%) with the story shrunk to a small preview card on top — so the sheet is tall.
    static let heightFraction: CGFloat = 0.60   // tuned so the ASPECT-TRUE cards land at ~231's 120pt width (chunky) — stable size everywhere, no stretch

    let activeStoryId: String
    @Binding var progress: CGFloat
    let arbiter: StoryViewer.SheetDragArbiter   // single-owner rule for all progress-writing drags
    let onSnapOpen: () -> Void                  // released mid-drag, staying open → host's display-link spring
    let onClose: () -> Void

    @State private var viewers: [StoryViewerInfo] = []
    @State private var search = ""
    @State private var loading = true
    @State private var tab = 0   // 0 = All Viewers, 1 = Contacts (tabs)
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
        // Sort order (sortMode .reactionsFirst): people who REACTED come first, then most-recent.
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
            // sheet eases to a soft stop instead of a hard wall.
            .offset(y: (1 - min(progress, 1)) * sheetH - overshoot(progress) )
        }
        .ignoresSafeArea()
        // A system-CANCELLED drag skips onEnded and would leave dragStart set forever — which
        // keeps the viewer list scroll-locked (audit M4). Progress settling at a rest state
        // means no drag owns the sheet: clear the anchor.
        .onChange(of: progress) { _, p in
            if p >= 1 || p <= 0 { dragStart = nil }
        }
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

    // ONE unified drag: dragging the handle/search OR the list (when the list is at its
    // top and you pull down) drives the sheet up/down. `fromList` gates the list case so mid-list
    // scrolling isn't hijacked. The list is scroll-disabled while the sheet isn't fully open, so once
    // a collapse starts the list locks and the drag owns the motion.
    private func sheetDrag(sheetH: CGFloat, fromList: Bool) -> some Gesture {
        // GLOBAL coordinate space, not the default .local: this drag MOVES the sheet it is
        // attached to, so local-space translation kept shrinking as the sheet followed the
        // finger — a per-frame feedback loop (sheet down → reading smaller → sheet back up)
        // that read as the jitter/heaviness when dragging ON the sheet. The backdrop drag
        // never had this because its layer is stationary. Global space = honest finger truth.
        DragGesture(minimumDistance: fromList ? 8 : 4, coordinateSpace: .global)
            .onChanged { v in
                if fromList {
                    let atTop = listOffset <= 0.5
                    // Take over only when already collapsing, or at the top pulling DOWN.
                    guard progress < 1 || (atTop && v.translation.height > 0) else { return }
                }
                // ONE writer at a time (SheetDragArbiter): a second handler with a different anchor
                // used to alternate writes with this one every frame = the violent sheet vibration.
                // A fresh claim re-anchors so the current touch maps to the CURRENT progress — a
                // stale dragStart from a system-cancelled drag can never jump the sheet again.
                guard let claim = arbiter.claim(fromList ? "list" : "header") else { return }
                if claim == .fresh || dragStart == nil {
                    dragStart = progress + v.translation.height / sheetH
                }
                // Track the finger 1:1; allow a little past 1.0 so overshoot() rubber-bands; clamp bottom at 0.
                var next = max(0, min(1.14, (dragStart ?? 1) - v.translation.height / sheetH))
                // A system-CANCELLED stroke skips onEnded and leaves dragStart behind; the next quick
                // stroke's first event would then TELEPORT the sheet by the difference between the two
                // strokes' translations (the "violent bounce/jump-cut" mid-close). A finger cannot move
                // 12% of the sheet between two ~8ms events — re-anchor instead of jumping.
                if abs(next - progress) > 0.12 {
                    dragStart = progress + v.translation.height / sheetH
                    next = progress
                }
                progress = next
            }
            .onEnded { v in
                arbiter.release(fromList ? "list" : "header")
                guard dragStart != nil else { return }   // fromList drag that never engaged
                dragStart = nil
                // Where the sheet would COME TO REST given the fling: predictedEndTranslation is the
                // ADDITIONAL travel from here, so subtract only that.
                let extra = (v.predictedEndTranslation.height - v.translation.height) / sheetH
                let projected = progress - extra
                // 0.8 / 160 (was 0.6 / 240): the old thresholds demanded almost half the sheet's
                // travel or a hard fling, so ordinary pulls bounced back repeatedly ("soo hard").
                let close = projected < 0.8 || v.predictedEndTranslation.height > 160
                if close { onClose() }
                else { onSnapOpen() }   // host display-link spring: model == presentation every frame
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

    // "All Viewers | Contacts" tabs (the viewer-list tabs component): active tab is white
    // with an underline, inactive is dimmed. Tapping switches the list filter (no sheet drag).
    private var tabSelector: some View {
        HStack(spacing: 24) {
            ForEach(0..<2, id: \.self) { i in
                Button { withAnimation(.easeInOut(duration: 0.18)) { tab = i } } label: {
                    VStack(spacing: 6) {
                        Text(i == 0 ? "All Viewers" : "Friends")
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
                    EmptyStateView(title: "No views yet", icon: "eye",
                                   text: "When people view this story, they'll show up here.")
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
        // Pulling the list down at its top collapses the sheet (hand-off).
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
                // Open my 1:1 chat with this viewer (same pending-chat route the group-member
                // sheet uses); close the sheet AND the story viewer so the chat lands on top.
                // No "View profile" here — this sheet has no profile route, and we never fake.
                Button {
                    AppRouter.shared.pendingChatName = v.name
                    AppRouter.shared.pendingChatPhoto = v.photoUrl
                    AppRouter.shared.pendingChatId = ChatService.convId(AuthService.shared.uid ?? "", v.id)
                    onClose()
                    NotificationCenter.default.post(name: .init("storyForceClose"), object: nil)
                } label: { Label("Send message", systemImage: "message") }
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
