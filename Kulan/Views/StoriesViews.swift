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

// `StoryDarkBlur` (a live `UIVisualEffectView(.systemThickMaterialDark)`) and `StoryBlurBake` (a
// hand-calibrated 4x4 imitation of it, for the crossfades where a real material collapses) stood
// here. Both are gone. What replaced them is `StoryCanvas` in StoryUI — Telegram's two-colour
// gradient — and the reason the imitation existed at all is the reason the whole system had to go:
// a material cannot be composited at fractional opacity, cannot be scaled by a gesture, and cannot
// be snapshotted, so every surface that did one of those needed its own copy of the look. A gradient
// needs none, and the at-rest look and the mid-transition look are now the same object rather than
// two things calibrated against each other.

struct StoryImage: View {
    let url: String
    // fitCanvas = show the WHOLE image (aspect-fit) over Telegram's canvas — the same treatment the
    // story viewer gives it, so a wide/tall photo isn't cropped/zoomed. Used for the swipe-up morph
    // card + the viewers carousel; the small story-row covers stay plain fill (crop).
    //
    // `bakedBars` used to sit beside this, choosing between the live material and the baked
    // imitation. There is one canvas now and it is correct in every context, so the choice — and the
    // whole class of bug where a card picked the wrong one — is gone.
    var fitCanvas = false
    // cardFillThreshold = the fill-vs-canvas decision uses THIS aspect (image height/width) instead
    // of the screen's. The shorter viewer cards pass slotH/slotW so any image as tall as the card
    // fills (no side bars) and only wider images get a canvas; nil = decide against the full screen.
    var cardFillThreshold: CGFloat? = nil
    @State private var image: UIImage?
    /// The canvas colours for this photo, sampled once when it lands. Nil until then, and a card
    /// with no colours yet simply draws black — which is what it drew before the photo arrived
    /// anyway, so there is no state where this shows something wrong.
    @State private var canvas: (top: Color, bottom: Color)?

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
    init(url: String, fitCanvas: Bool = false, cardFillThreshold: CGFloat? = nil) {
        self.url = url
        self.fitCanvas = fitCanvas
        self.cardFillThreshold = cardFillThreshold
        if let warm = DiskImageCache.shared.memoryImage(url) {
            _image = State(initialValue: warm)
            // Seed the canvas in the SAME breath as the photo. If it were left to `apply` the card
            // would draw one frame of photo-on-black before the gradient arrived, and one frame of
            // black bars under a moving finger is exactly the flash this initializer exists to stop.
            if fitCanvas, !Self.fills(warm, threshold: cardFillThreshold) {
                _canvas = State(initialValue: Self.colours(of: warm, url: url))
            }
        }
    }

    var body: some View {
        Group {
            if let image {
                if fitCanvas {
                    // Match the story viewer's ImageLoader EXACTLY, both rules:
                    //  • an image at least as TALL as the card fills edge-to-edge with NO canvas —
                    //    don't add bars the story never had;
                    //  • shorter images aspect-FIT over Telegram's canvas, the same gradient the
                    //    viewer draws behind the same photo.
                    // The fill lives INSIDE an overlay of Color.clear so it can never report an
                    // oversized layout (a bare scaledToFill blew a wide panorama into a huge zoomed
                    // crop the moment the viewers sheet appeared — the ZStack adopted its size).
                    if fillsScreen(image) {
                        Color.clear
                            .overlay(Image(uiImage: image).resizable().scaledToFill())
                            .clipped()
                            .transition(.opacity)
                    } else {
                        // The canvas is a plain `LinearGradient`, which is two colours the GPU
                        // interpolates inside this view's own frame. It cannot adopt an oversized
                        // layout the way the aspect-filled copy of the photo it replaced could, so
                        // the `Color.clear` overlay nesting that used to be needed to contain that
                        // copy is gone with it.
                        //
                        // ⚠️ THIS IS THE SEAM AND IT IS SUPPOSED TO BE INVISIBLE, so do not "fix" it
                        // by cropping or by dimming the edges. The carousel slot is taller than 9:16
                        // (see `cardSlot`), so even a story that was baked to fill a story frame is
                        // FIT here and wears a canvas around it. Those extra strips read as
                        // continuous because the strip's colours are sampled from the file's own top
                        // and bottom bands — which, for a baked story, ARE the ends of the gradient
                        // already in it. The canvas continues the picture rather than framing it.
                        // That only holds while both sides go through `StoryCanvas`.
                        ZStack {
                            LinearGradient(colors: [canvas?.top ?? .black, canvas?.bottom ?? .black],
                                           startPoint: .top, endPoint: .bottom)
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
                //
                // ⚠️ AND IT IS ALWAYS THE DARK SKELETON, WHATEVER THE APP IS WEARING.
                //
                // His 2026-08-10 report — "when I click a story to open, the first opening story
                // corners" with all four circled — MEASURED off the screenshot: neutral grey wedges
                // outside the card's rounded corners, running 226 to 243 across the wedge. That
                // gentle ramp is the giveaway: it is not a flat fill, it is THIS view's shimmer
                // sweep, and 226-243 is `systemGray4` plus a white highlight, i.e. the LIGHT half of
                // the branch below, drawn while his whole app is in dark mode.
                //
                // It shows in the corners rather than across the card because the flight's cover cuts
                // its own corners transparent ON PURPOSE (`StoryCardShot.crop`'s over-cut, which is
                // what keeps photographed chat-list pixels out of them), so for the first frames of an
                // open the corners are a window onto the story page underneath — and that page is
                // still this placeholder.
                //
                // A story card is a dark surface in both appearances: the viewer is black, the
                // carousel is black, and a loaded card draws `StoryCanvas`'s near-black gradient. A
                // light-grey shimmer there is a hole in it, not a placeholder for it — the same
                // reasoning as the composer's segmented control, which pins its trait rather than
                // hardcoding colours. Pinned here rather than in `SkeletonFill`, which is shared with
                // the chat and call lists where the light shimmer is correct.
                SkeletonFill().environment(\.colorScheme, .dark)
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
    private func fillsScreen(_ img: UIImage) -> Bool { Self.fills(img, threshold: cardFillThreshold) }

    /// Static so the initializer can seed the canvas colours before the first frame is drawn.
    private static func fills(_ img: UIImage, threshold: CGFloat?) -> Bool {
        guard img.size.width > 0 else { return false }
        let ratio = img.size.height / img.size.width
        if let threshold { return ratio >= threshold - 0.02 }
        let screen = UIScreen.main.bounds
        return ratio >= screen.height / screen.width - 0.02
    }

    /// Through `StoryCanvas`, the same sampler the story viewer and the export both read. A card in
    /// the carousel and the full-screen story behind it are the same photo, and they must not be
    /// able to disagree about what colour sits behind it.
    ///
    /// ⚠️ CACHED PER URL, AND THAT IS NOT AN OPTIMISATION, IT IS WHAT MAKES THE `init` CALL LEGAL.
    /// `init` seeds these colours so a warm card never draws a frame of black bars, and SwiftUI
    /// builds a view struct on EVERY body evaluation — so during a sheet page-drag this would run
    /// two crops and two 8x8 context draws per card per frame. That is main-thread pixel work in the
    /// middle of a gesture, which is the lag it would have caused. One dictionary lookup instead,
    /// and the sampling happens once per photo for the life of the process.
    /// ⚠️ AN `NSCache`, WHICH IS THREAD-SAFE, and that is the whole reason it is not a dictionary.
    /// A plain static dictionary here would be written from `init` (main) and from `apply`'s
    /// continuation, and concurrent writes to a Swift dictionary are how `StoryPrefs`' static cache
    /// became a SIGSEGV on every cold start (build 177, a few lines down this same file). NSCache
    /// also gives the memory back under pressure, which for a pair of colours costs a re-sample.
    private final class ColourPair { let top: Color, bottom: Color
        init(_ t: Color, _ b: Color) { top = t; bottom = b } }
    private static let colourCache = NSCache<NSString, ColourPair>()

    private static func cachedColours(_ url: String) -> (top: Color, bottom: Color)? {
        guard let p = colourCache.object(forKey: url as NSString) else { return nil }
        return (p.top, p.bottom)
    }

    @discardableResult
    private static func storeColours(_ url: String, _ pair: (top: Color, bottom: Color))
    -> (top: Color, bottom: Color) {
        colourCache.setObject(ColourPair(pair.top, pair.bottom), forKey: url as NSString)
        return pair
    }

    /// The seeding path, for `init` only: a hit is a cache lookup, and a miss samples once and
    /// remembers. `init` runs on EVERY body evaluation, so a miss must never be the common case —
    /// and it is not, because the same url is sampled once and answered from the cache thereafter.
    private static func colours(of img: UIImage, url: String) -> (top: Color, bottom: Color) {
        if let hit = cachedColours(url) { return hit }
        let c = StoryCanvas.colours(of: img)
        return storeColours(url, (Color(uiColor: c.top), Color(uiColor: c.bottom)))
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
        guard fitCanvas, !fillsScreen(img), canvas == nil else { return }
        if let hit = Self.cachedColours(url) { canvas = hit; return }
        // ⚠️ THE SAMPLING GOES OFF-MAIN, THE CACHE WRITE DOES NOT. `StoryCanvas.colours` is pure —
        // it touches nothing shared — so it is safe anywhere; the dictionary is not, and this
        // function is `@MainActor`, so the store below happens back on the main actor after the
        // await. Writing that dictionary from a detached task is precisely how `StoryPrefs`'
        // static cache was corrupted into a SIGSEGV on every cold start (build 177), a few lines
        // down this same file.
        let sampled = await Task.detached(priority: .userInitiated) { StoryCanvas.colours(of: img) }.value
        canvas = Self.storeColours(url, (Color(uiColor: sampled.top), Color(uiColor: sampled.bottom)))
    }
}

/// THE SHEET'S SIDEWAYS PAGE-DRAG, IN A BOX OF ITS OWN.
///
/// One number, written by a UIKit pan on every frame, read by exactly one SwiftUI view. It lives in
/// an object rather than in the host's `@State` so that writing it invalidates only whoever
/// SUBSCRIBES to it — see the long note on `pageDragBox`. The host holds it with `@State`, which
/// stores the reference without subscribing; `MyStoriesCarousel` declares `@ObservedObject`, and is
/// therefore the only thing a drag re-renders.
@MainActor final class StorySheetPageDrag: ObservableObject {
    /// In CARD UNITS, not points — a fraction of the panel's journey, and one panel journey is one
    /// card. Divided by nothing downstream; see the note at `onPageDrag` in StoryViewersSheetUIKit
    /// for the two builds that got this wrong in each direction.
    @Published var value: CGFloat = 0
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
    /// ⚠️ `mutateOrdered`, NOT `save`. This store was written with the plain append-and-save pair,
    /// which is the shape the seen and liked stores were explicitly moved OFF because they "grew
    /// forever" — see the note above `mutateOrdered`. Every one-time story id ever opened would have
    /// sat in UserDefaults for the life of the install, and UserDefaults is read into memory at
    /// launch, so it becomes a launch cost that only ever grows. Same 1000-id cap as the others.
    static func markOneTimeUsed(_ storyId: String) {
        guard !storyId.isEmpty, !isOneTimeUsed(storyId) else { return }
        mutateOrdered("oneTimeUsed") { $0.append(storyId) }
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

// THE STORIES ROW MOVED TO UIKit — see `StoriesRowUIKit.swift` (owner 2026-08-08: "completely
// change Stories row to UIKit ... do not change the design, appearance, layout, or behavior in any
// way").
//
// What used to be here: `StoriesRow`, `StoryCardDipStyle`, `afterStoryDip` and `StoryFriendCard`.
// The row is a `UIViewRepresentable` of the same name now, with the same arguments in the same
// order, so MainShell's call site did not change. Every measurement, spring, colour and rule that
// lived here went with it, comments included.
//
// STILL HERE AND STILL SwiftUI, because other screens draw them: `StoryRingView` (the chat-list
// avatars), `StoryImage` (the viewer and the carousel), `SkeletonFill`, `UploadingAvatarRing`,
// `StoryPrefs`. The row draws its own UIKit copies of the first four — change one, change the other.


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
    /// ALWAYS LAND ON THE THING THAT WAS TAPPED, even after paging to somebody else.
    ///
    /// The stories row wants the opposite: it pages person to person and each person has their own
    /// card sitting in the same row, so closing on the fourth person should land on the fourth
    /// person's card. Every OTHER door is a single anchor that has no equivalent — a chat row's ring,
    /// a profile avatar — and there is no ring in the chat list for "whoever you paged to", or if
    /// there is, it is somewhere else entirely on a list that has not scrolled.
    ///
    /// Pinning is also exactly what Apple's zoom did at these doors: `viewerSourceID` was captured at
    /// the tap and never moved. So this keeps the behaviour the cover already had, rather than
    /// inventing a new one while moving the door.
    var heroSourcePinned: Bool = false
    /// THE AUTHOR ALREADY DECIDED THIS — set by any door whose stories came from MY TRAY.
    ///
    /// A story only reaches the tray because the query matches me against its `recipientUids`, which
    /// is the author's own audience choice. His 2026-08-07 answer when I put the rule to him was
    /// "already i have system": Everyone / My Friends / a custom list IS the system that says who
    /// receives a story, and testing my chat list a second time is a gate on top of a gate.
    ///
    /// It was also plainly wrong on his own test accounts. They had put him in their audience and he
    /// had never opened a chat with them, so the author said yes and the app said no.
    ///
    /// FALSE for the profile door, which is the case the rule was written for: a story you found by
    /// opening somebody's profile did NOT come with your name on it, and a reply there would be a
    /// direct line to a person who never accepted you.
    var deliveredToMe: Bool = false
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
    ///
    /// ⚠️ HELD IN A BOX, AND `@State` ON THE BOX RATHER THAN ON THE NUMBER, and that is the whole of
    /// his "when I swipe sheet top card images swipes lag".
    ///
    /// This was a plain `@State CGFloat`, written by the sheet's UIKit pan on EVERY FRAME of the
    /// drag. A `@State` write invalidates the body it lives on — and the body it lives on is this
    /// one, the whole story viewer: the pager representable, the sheet representable, the carousel,
    /// every overlay. So dragging the sheet sideways asked SwiftUI to re-evaluate the entire screen
    /// sixty or a hundred and twenty times a second, and `updateUIViewController` ran on both
    /// representables each time. The row was the visible casualty because it is the thing that is
    /// supposed to be moving.
    ///
    /// Telegram does not have this seam to fall down: `StoryItemSetContainerComponent` repositions
    /// its cards and its view list in ONE layout pass driven straight from `scrollViewDidScroll`,
    /// all in UIKit. Ours crosses into SwiftUI, so the fix is to make the crossing narrow: the box
    /// is an `ObservableObject` that ONLY `MyStoriesCarousel` observes, and this view holds it with
    /// `@State`, which stores a reference WITHOUT subscribing to it. Per-frame writes now invalidate
    /// the row and nothing else.
    ///
    /// The three places this view genuinely needs to know about paging want a BOOLEAN, and a boolean
    /// changes twice a drag rather than a hundred times a second — that is `sheetPaging` below.
    @State private var pageDragBox = StorySheetPageDrag()
    /// Is a sheet page-drag in flight? The boolean half of `pageDragBox`, kept as ordinary `@State`
    /// because the host really does have to re-render when it flips — twice per drag, not per frame.
    @State private var sheetPaging = false
    /// Which story the owner footer's viewers belong to, so a story change empties it instead of
    /// leaving the previous one's count and faces up during the fetch. See `loadBarViewers`.
    @State private var lastBarViewersStoryId: String = ""

    /// TRUE while the CAROUSEL'S OWN card owns the slot and the real story card must stand aside.
    ///
    /// Three reasons, and the third is the deferred jump: once the selection has moved away from the
    /// story the player is actually holding, the real card is showing the WRONG story and must not be
    /// the thing on screen. Without it the slot would show the story you paged away from while the
    /// sheet below it listed the viewers of the one you paged to.
    private var carouselOwnsSlot: Bool {
        carouselInteracting || sheetPaging || rowIsOnAnotherStory
    }

    /// Is the card in the centre of the row a DIFFERENT story from the one the player is holding?
    ///
    /// ⚠️ COMPUTED FROM TWO IDS, NOT REMEMBERED IN A FLAG, AND THAT IS THE FIX FOR HIS REPORT.
    ///
    /// This was `!pendingJumpStoryId.isEmpty` — a stored value written by an `onChange` on
    /// `sheetStoryId`. Stored state can be written at the wrong moment, cleared at the wrong moment,
    /// or never written at all, and all three of those happened here:
    ///
    /// · The open writes `sheetStoryId` and `showViewers` in ONE transaction, so the handler stored a
    ///   jump to the story already on screen and jammed the flag TRUE for a whole sheet session.
    /// · `75aa9522` fixed that with `id == targetStoryId`, but `targetStoryId` falls back to
    ///   "first unseen, else first" whenever `currentStoryId` is empty — and `currentStoryId` is
    ///   written by `onItemSeen`, which the library WITHHOLDS while a story is paused, held or
    ///   buffering. So that comparison could answer "not a jump" about the wrong story.
    /// · **The handler's guard requires `currentIsMine`, while the swipe-up that opens the sheet
    ///   accepts `currentIsMine || mineOnly`** — because `currentBucketUid` arrives a beat late on a
    ///   fresh open, which the note at `onSwipeUpChanged` states in as many words. On that beat the
    ///   sheet opens and the handler is silently dead, so the flag is never written for that session
    ///   and the story he pulled up from stays painted in the slot. That is his report exactly: "the
    ///   first story I swipe up from becomes stuck as the background", and it is why paging only
    ///   moved the card and never the thing behind it.
    ///
    /// Asking the two ids has no guard to fail, nothing to clear and nothing to go stale. Both sides
    /// are anchored on the SAME expression the open used (`targetStoryId`), so they agree by
    /// construction on the first pull and can only diverge when the row has genuinely moved. It is
    /// the shape Telegram uses: one authoritative current-item id, everything else derived from it.
    /// ⚠️ `showViewers` FIRST, AND IT IS NOT DECORATION. THIS SHIPPED WITHOUT IT AND BLACKED THE
    /// STORY OUT — my regression in `b87fcfe1`, his report in as many words: "screen story is going
    /// black".
    ///
    /// The stored flag this replaced was WIPED at `closeViewers` and again at `onDisappear`, so it
    /// was structurally incapable of being true outside a sheet session. A computed answer has no
    /// such lifetime, and `sheetStoryId` is never cleared — it just keeps naming the last card the
    /// row was on. So once the sheet had been opened and closed even once, the very next advance
    /// moved `targetStoryId`, the two ids stopped matching, `carouselOwnsSlot` went true with no
    /// sheet on screen, and `setHidden` put the live card at alpha 0 over a black page. Nothing put
    /// it back until another sheet open and close.
    ///
    /// The lesson is the one this whole rebuild is about, arriving from the other side: replacing
    /// stored state with a computed answer removes staleness and ALSO removes the lifetime the
    /// stored version got for free from being cleared. The scope has to be put back explicitly.
    private var rowIsOnAnotherStory: Bool {
        showViewers && !sheetStoryId.isEmpty && sheetStoryId != targetStoryId
    }
    // ⚠️ THERE IS NO COVER DICTIONARY ANY MORE, AND THAT IS DELIBERATE.
    //
    // `frozenCovers` lived here: one bitmap per video story, filled by photographing the live card
    // through a single global pointer at a single player view, at an instant that had to be exactly
    // right. The instant was moved three times (`16ba3c63` on the pull, `13952868` settle-and-verify,
    // `8693f1ee` a sweep beside it) and the picture was still wrong on build 520.
    //
    // Each card asks the frame bank for a picture of its OWN clip at draw time instead — see
    // `cardMedia`. There is no capture site, so there is no moment to get wrong; there is no host
    // state, so it cannot be stale, cannot be cleared at the wrong time and cannot be filed under
    // the wrong story. The bank is written where the story is actually frozen
    // (`StoryCardMorph.bankCurrentFrame`), which is the one place that always knows the answer.
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
        /// HOW MUCH OF THE DIM'S FLOOR IS IN EFFECT, 0…1.
        ///
        /// The backdrop has a floor now (`heroDimFloor`) so it cannot wash out to nothing under a
        /// long pull — his Snapchat note, and the reason ours read lighter than Telegram's. But a
        /// floor that is simply clamped on would still be painted at the two moments the dim MUST be
        /// zero: the first frame of an open, when the card is sitting on the row and nothing should
        /// be darkened yet, and the last frame of a landing, when the screen is removed and a wall
        /// still 36% black is the grey flash this file has warned about since it was written.
        ///
        /// So it is MIXED rather than clamped, and a flight owns the mix: the open fades it in as
        /// the story grows, a committed close fades it out as the card lands, and a drag holds it at
        /// 1. Every crossing is continuous, so there is no frame where the backdrop steps.
        var dimFloor: CGFloat = 0
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
    /// THE SMALLEST THE STORY IS ALLOWED TO GET WHILE THE FINGER IS STILL DOWN, as a fraction of its
    /// own full-screen width.
    ///
    /// 0.34 first, off his Snapchat screenshot. RAISED TO 0.46 on 2026-08-08 against a pair of his
    /// own frames — "reduce the Story scroll-down limit… it should only allow a small amount of
    /// downward movement and must not go beyond that limit" — measured rather than guessed: the
    /// card he called too far is 22% of the screen's width, the one he wants is 46%.
    ///
    /// It bounds the TRAVEL as much as the size, which is why one number answers both halves of his
    /// report: `heroDragCeiling` turns it into a cap on the fraction, `heroDragY` gives the finger
    /// 1:1 only for as long as that cap allows, and the bottom-edge clamp then holds the card well
    /// clear of the tab bar because a bigger card runs out of room sooner.
    private static let heroDragMinScale: CGFloat = 0.46
    /// How much further the card drifts after it has bottomed out, however far the finger keeps
    /// going. Small on purpose: it exists so the gesture still answers at the bottom, not so the card
    /// can keep travelling. Halved with the floor above, same report: 64pt of drift past a limit
    /// reads as the limit not being there.
    private static let heroDragTail: CGFloat = 28
    // (`heroFade`, how much the story itself softened as it was pulled away, is GONE — 2026-08-07.
    // It was 0.22 and it is what he saw as the chat list showing through the story like glass. The
    // background giving way is `heroDimMax`'s job; the picture stays opaque.)
    /// The darkest the chat list gets under a story in flight. Judged against his Snapchat shots,
    /// where the list behind is dimmed well past half but never to black — you can still read it.
    /// THE DARKEST THE LIST GETS ONCE A PULL IS PROPERLY UNDER WAY.
    ///
    /// Set from his 2026-08-07 comparison, with Telegram's own source read for the other end of the
    /// range. Telegram paints a solid black layer at
    /// `max(0.5, 1.0*(1 - dismissFraction) + 0.2*dismissFraction)` — 1.0 at rest, and floored so it
    /// never gets lighter than half while your finger is down. Ours peaked at 0.45 and then decayed
    /// all the way to zero, so our CEILING was below their FLOOR and the gap widened the further he
    /// pulled: at half way we were 0.27 against their 0.60.
    ///
    /// His call: Telegram too dark, ours too light, aim between them and nearer Snapchat. So 0.58
    /// here and a 0.36 floor — the list stays clearly readable, which is the Snapchat look this file
    /// has been judged against from the start, and it never washes out.
    ///
    ///        drag     ours (was)   now    Telegram
    ///          0%        1.00      1.00     1.00
    ///         25%        0.40      0.55     0.80
    ///         50%        0.27      0.48     0.60
    ///         75%        0.13      0.42     0.50
    ///        100%        0.00      0.36     0.50
    private static let heroDimMax: CGFloat = 0.58
    /// The lightest the backdrop is allowed to get while the finger is down. Mixed in through
    /// `hero.dimFloor` rather than clamped, so a flight can still take the dim to a true zero at
    /// either end — see that property for why clamping it would be the grey flash.
    private static let heroDimFloor: CGFloat = 0.36

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
    /// ⚠️ AND THE PLACEHOLDER HAS TO STILL BE IN THE AIR, not merely have been once.
    ///
    /// His 2026-08-10 report: post A and B, let them finish, post C, open the viewer — and the
    /// "Uploading…" bar is on A and B as well. His screenshot is the proof and it is not subtle: an
    /// EIGHTEEN HOUR OLD view-once story wearing the bar and the cancel button.
    ///
    /// `isPending` only asks whether the id carries the placeholder prefix, which stays true for the
    /// rest of the session once the id has been seen, and `uploading` is a single global flag that C
    /// holds up on everyone's behalf. So any id left over from a finished post kept answering yes for
    /// as long as ANY post was running. Asking the service whether this exact placeholder is still
    /// in flight is the question that was meant all along, and `uploadingStories` is the list the
    /// viewer is already drawing them from, so the bar and the item cannot disagree.
    ///
    /// ⚠️ THE OTHER HALF IS NOT FIXED HERE AND MUST NOT BE FORGOTTEN. `currentStoryId` is written by
    /// `onItemSeen`, which is a WATCHED receipt — StoryDetailView withholds it while a story is
    /// paused, held, folding, buffering or behind the keyboard (deliberately: for a view-once story
    /// that receipt SPENDS the view). So the id can lag one or more pages behind the picture, and
    /// while a real post is genuinely in the air the bar can still ride onto a neighbour. Closing
    /// that needs an ungated "which item is on screen" signal from the library beside the receipt,
    /// which is a change to the pager and belongs in its own commit.
    private var isUploadingItem: Bool {
        guard StoriesService.isPending(currentStoryId), uploadSvc.uploading else { return false }
        return uploadSvc.uploadingStories.contains { $0.id == currentStoryId }
    }
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
         heroDismiss: Bool = false, heroSourceKey: String = "", heroSourcePinned: Bool = false,
         deliveredToMe: Bool = false, heroStageOpen: Bool = true,
         onHeroClose: (() -> Void)? = nil,
         onClose: @escaping () -> Void,
         onProfile: @escaping (StoryGroup) -> Void = { _ in },
         onDeletedRemaining: @escaping (StoryGroup) -> Void = { _ in }) {
        self.init(groups: [group], startIndex: 0, ownSwipeDismiss: ownSwipeDismiss,
                  heroDismiss: heroDismiss, heroSourceKey: heroSourceKey,
                  heroSourcePinned: heroSourcePinned, deliveredToMe: deliveredToMe,
                  heroStageOpen: heroStageOpen,
                  onHeroClose: onHeroClose,
                  onClose: onClose, onProfile: onProfile,
                  onDeletedRemaining: onDeletedRemaining)
    }
    init(groups: [StoryGroup], startIndex: Int = 0, ownSwipeDismiss: Bool = false,
         heroDismiss: Bool = false, heroSourceKey: String = "", heroSourcePinned: Bool = false,
         deliveredToMe: Bool = false, heroStageOpen: Bool = true,
         onHeroClose: (() -> Void)? = nil,
         onClose: @escaping () -> Void,
         onProfile: @escaping (StoryGroup) -> Void = { _ in },
         onDeletedRemaining: @escaping (StoryGroup) -> Void = { _ in }) {
        self.groups = groups
        self.startIndex = startIndex
        self.ownSwipeDismiss = ownSwipeDismiss
        self.heroDismiss = heroDismiss
        self.heroSourceKey = heroSourceKey
        self.heroSourcePinned = heroSourcePinned
        self.deliveredToMe = deliveredToMe
        self.heroStageOpen = heroStageOpen
        self.onHeroClose = onHeroClose
        self.onClose = onClose
        self.onProfile = onProfile
        self.onDeletedRemaining = onDeletedRemaining
    }

    /// Every bucket + item id this viewer is currently fed. When it CHANGES while the viewer is
    /// open — an upload landing swaps the placeholder id for the real story's — the fresh buckets
    /// are pushed into the mounted pages in place. See the `.onChange` in the body and
    /// `StoryItemsReconcile` in the library.
    private var reconcileSignature: [String] { groups.flatMap { [$0.id] + $0.stories.map(\.id) } }

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
                        // AND THE ONE THAT CANNOT BE MISSING. `previewUrl` is a promise the viewer
                        // has to go and collect; this is the picture itself. See `Story.blurThumb`.
                        blurThumb: s.blurThumb,
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
                            storyType: g.isMine || !(deliveredToMe || StoryContact.isFriend(g.authorUid))
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
            // zoom by interpolating its FRAME with a StoryImage(fitCanvas:) = image + canvas. No
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
            // ⚠️ EVERY INPUT TO `carouselOwnsSlot` DIES WITH THE SHEET, not just this one.
            //
            // All three of them can only mean anything while there is a sheet, and any one of them
            // left standing afterwards puts the live card at alpha 0 with nothing drawn over it —
            // a black story page, which is what his "screen story is going black" report was. The
            // third input is scoped in `rowIsOnAnotherStory` itself; these two are owned here.
            //
            // `sheetPaging` was the live risk: it is cleared by the sheet's own page commit and by
            // `settleViewers`, and a close arriving mid page-drag reaches neither.
            carouselInteracting = false
            sheetPaging = false
            pageDragBox.value = 0
            // Same rule as driveMorph: a hero flight owns the card and this teardown must not
            // reset it out from under one.
            guard !hero.live else { return }
            // Full-screen, square, unmasked, visible. The sheet can be torn down from several paths
            // (close, dismiss, teardown) and a card left mid-transform would open the NEXT story
            // already shrunken.
            StoryCardMorph.shared.reset()
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
            // ⚠️ NO CAPTURE FROM HERE, AND NO SCHEDULED ONE EITHER. Two versions of this line have
            // shipped: photograph at 0.9 (which is MID-MOTION, so the half-faded caption and its
            // scrim got baked in — his "sometimes appear caption and shadow"), then a 0.35s
            // settle-and-verify that only narrowed the same window.
            //
            // The pull no longer decides what any card shows. Each card reads the frame bank for its
            // own clip when it draws, and the bank was filled at the pause that STARTED this pull.
            // A picture that is fetched cannot be caught at the wrong moment, so there is no moment
            // left to move.
        }
        // The carousel row took over, or gave the centre back — by a finger on the row OR by the
        // sheet being thrown sideways (both slide cards through the slot, both need the copy).
        // See StoryCardMorph.setHidden.
        .onChange(of: carouselOwnsSlot) { _, on in
            // ⚠️ THE TWO CAPTURES THAT USED TO BOOKEND THIS LINE ARE GONE. One fired on the way in
            // ("photograph the story being left, while it is still the live one") and one on the way
            // out. Both existed because the row's cards drew from a dictionary somebody had to fill
            // in time; they draw from the frame bank now and fill themselves.
            //
            // ⚠️ THE HANDOVER STAYS, BUT ITS THIRD INPUT IS NO LONGER A REMEMBERED FLAG.
            //
            // The swap itself was never the wrong idea: the live card sits at the slot centre and
            // cannot slide, so for the length of a swipe the row draws its own card and the real one
            // waits underneath. What broke was the ANSWER to "is the centred card the story the
            // player is holding" — kept in `pendingJumpStoryId`, written by a handler whose guard
            // could be skipped on the very beat the sheet opens. Skipped once, the live card was
            // never told to stand aside for the rest of that session, and it sat there painting
            // story A behind a card showing story B.
            //
            // `rowIsOnAnotherStory` computes that answer from the two ids every time it is asked, so
            // there is no write to miss and nothing to go stale. The two gesture inputs beside it
            // (`carouselInteracting`, `sheetPaging`) were never the problem: both are owned by one
            // writer each and both self-clear.
            StoryCardMorph.shared.setHidden(on)
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
            // (The per-session cover dictionary that used to be emptied here is gone. The frame bank
            // it was built from has always been cleared by the door and the presenter's dismissal
            // belt — `StoryPlaybackResume.clearAll` — which is the same "one viewing session" rule
            // in the one place that owns it.)
            // The sheet state belongs to one session too, and it does NOT die with this overlay
            // (host @State). A viewer torn down mid-pull — the last story deleted under an open
            // sheet, a system-cancelled drag that parked it at a few percent — left `showViewers`
            // true, and the freeze watchdog then strangled every viewer opened after it. Closing
            // time means "no sheet", the same way opening time does.
            progressWatchdog?.cancel(); progressWatchdog = nil
            showViewers = false
            viewersProgress = 0
            // (Nothing to clear for the selection any more. It was a stored `pendingJumpStoryId`
            // that had to be wiped here or it would jump the NEXT viewer to a story nobody chose;
            // the selection is read from `sheetStoryId` at the close instead, and `sheetStoryId` is
            // re-seeded by every open.)
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
            // `currentIsMine`: the viewers sheet only exists over MY OWN story, so a freeze
            // asserted while a friend's story is up can only ever be leaked state — it is what
            // kept re-pausing his freshly opened stories half a second in (2026-08-09).
            if showViewers && currentIsMine && viewersProgress > 0.01 {
                NotificationCenter.default.post(name: .init("pauseStory"), object: nil)
            }
        }
        // NO host pause post during the swipe-DOWN dismiss drag — matching TestFlight build 210,
        // whose scroll-down-to-close the user confirmed as the correct one. The library already
        // pauses on its pan's own .began; this extra post only existed in 211+.
        // A CHANGED FEED RECONCILES THE OPEN VIEWER, it does not rebuild it. The uploading door
        // used to re-key the whole viewer on `svc.uploading` (his 2026-08-09 report: watching story
        // A while C uploads — C landing closed and reopened the viewer around him). The door leaves
        // identity alone now, and this pushes the fresh items into the mounted pages instead.
        .onChange(of: reconcileSignature) { _, _ in
            for m in models {
                NotificationCenter.default.post(name: .storyItemsReconciled,
                                                object: StoryItemsReconcile(bucketId: m.id, stories: m.stories))
            }
        }
        // ⚠️ THE STORY UNDERNEATH DOES NOT MOVE WHILE THE SHEET IS UP. IT MOVES WHEN THE SHEET GOES.
        //
        // This used to post `jumpToStoryItem` the instant the carousel centred a different story,
        // and that single line is his "the real-time cover disappears when I swipe the sheet". The
        // viewer draws ONE story at a time and reuses one `PlayerView`, so jumping tears clip A out
        // of the layer that is on screen and starts loading B — under an open sheet, where the card
        // is a 100pt thumbnail nobody is watching. A had a real paused frame; B has nothing until it
        // downloads. That is the disappear, and the second or two is the download.
        //
        // Telegram does not do this, and reading their source is what settled it.
        // `initializeVideoIfReady` refuses to build a player at all while the progress mode is
        // `.pause`, and opening the views list forces `.pause` on the whole set
        // (`StoryItemSetContainerComponent`). So paging with the list open creates NO player: the
        // story you arrive at shows its still, the story you left keeps its own paused layer and its
        // last decoded frame, and the player for whatever you settled on is built the moment the
        // list is dismissed.
        //
        // We cannot keep a view per story the way they do — one story at a time is this viewer's
        // architecture — but we can keep their RULE, which is the part that shows: nothing loads
        // while the sheet is up. The selection is remembered and spent at the close, so the slot
        // carries stills the whole time and the live clip arrives with the collapse.
        // ⚠️ THE STORY UNDERNEATH MOVES THE INSTANT THE ROW DOES. THIS IS BUILD 516's BEHAVIOUR,
        // PUT BACK, AND IT IS PUT BACK ON HIS BISECTION RATHER THAN ON MY REASONING.
        //
        // He tested it down to the build: **516 correct, 517 wrong**. `fc16da9a` is in 517 and not in
        // 516, and `fc16da9a` is the commit that stopped posting this immediately and started
        // remembering the selection to spend at the close. Everything I changed today was aimed at
        // the flag that deferral needed. The deferral itself was the bug, so none of it moved.
        //
        // WHY DEFERRING SEEMED RIGHT, AND WHY IT NO LONGER APPLIES. `fc16da9a` was fixing a real
        // report: this viewer draws one story at a time through one `PlayerView`, so jumping tore
        // clip A out of the layer on screen and began downloading B under a 100pt thumbnail. A had a
        // paused frame, B had nothing, and the gap was visible — "the real-time cover disappears
        // when I swipe the sheet".
        //
        // The cards no longer depend on the live player for their picture. Each one fetches its own
        // frame from the bank at draw time (`cardMedia`), and the bank is filled when the story
        // freezes (`StoryCardMorph.bankCurrentFrame`). So tearing the player away no longer empties
        // anything the row is drawing. The visible half of that report is answered by the frame bank
        // instead of by the deferral, which is what makes going back to 516's behaviour safe now
        // when it would not have been then.
        //
        // What is NOT yet answered is the invisible half: an immediate jump still starts a download
        // under the sheet. Telegram's answer is `initializeVideoIfReady` refusing to build a player
        // at all while the mode is `.pause`. That is the right fix and it belongs on the LOADING, not
        // on the navigation — a separate change, and deliberately not bundled here.
        .onChange(of: sheetStoryId) { _, id in
            // ⚠️ `mineOnly` TOO, NOT `currentIsMine` ALONE. `currentIsMine` depends on
            // `currentBucketUid`, which only arrives after the library's `onUserChanged`, so on a
            // fresh open it can still be empty — the note at `onSwipeUpChanged` says exactly this,
            // which is why the swipe-up that OPENS this sheet accepts either. This guard demanding
            // the stricter one is how the handler came to be silently skipped for a whole session.
            guard showViewers, currentIsMine || mineOnly, !id.isEmpty else { return }
            NotificationCenter.default.post(name: .init("jumpToStoryItem"), object: id)
            // The anchor moves with it. `currentStoryId` means "the item the library is on", and it
            // is otherwise only written by `onItemSeen`, which the library WITHHOLDS while a story is
            // paused — and the story is paused for the entire time this sheet is up. Left stale,
            // `rowIsOnAnotherStory` would stay true after the jump had already landed and the live
            // card would be held aside for no reason.
            currentStoryId = id
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
                // ⚠️ NOT MY OWN. Tapping the header on my own story opened MY profile over my story,
                // which is a screen nobody navigated towards — his 2026-08-07 report, with the sheet
                // half-raised over his own face. The header is there to say WHO this is, and on my
                // own story I already know; the tap only means something when it is somebody else.
                //
                // Tested against the signed-in uid rather than `g.isMine`, because a mixed feed can
                // page onto my own bucket mid-visit and the tap has to answer for the story that is
                // on screen at that moment, not the one the viewer was opened with.
                guard user.id != AuthService.shared.uid else { return }
                // Open the profile OVER the story (paused) — do NOT close the viewer.
                if let g = groups.first(where: { $0.authorUid == user.id }) { profileSheet = g }
            },
            // Landing on a person no longer greys their whole ring — seen state advances per ITEM
            // below (the standard rule: the ring stays colored until every story is watched).
            // ⚠️ EVERY CHANGE OF PERSON IS PUBLISHED, IMMEDIATELY, AND THIS IS THE ONLY PLACE IT
            // HAPPENS. Forward, back, or a carousel jump all arrive here, so there is one write and
            // nothing to keep in step. See `StoryDoorState.activeSourceKey` for what went wrong when
            // the outside world did not know he had moved.
            onUserChanged: { uid in
                currentBucketUid = uid
                publishActive(uid)
                loadBarViewers()
            },
            onItemSeen: { id in
                currentStoryId = id
                // ⚠️ THE LOOKAHEAD USED TO START HERE AND IT CANNOT. This callback is a SEEN
                // RECEIPT, and the library withholds it while the story is paused, held or
                // buffering — so the next clip's download waited on this clip's download. It now
                // runs off the item CHANGING, inside the viewer, on the same flattened list; see
                // the note at the top of `StoryDetailView.startProgress`.
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
                    // His spec for the pull-up was "keep the exact pre-pull blur, never re-compute
                    // it at the smaller size", and a freeze post went here to obey it. The canvas
                    // obeys it by construction — a gradient has nothing to re-compute at any size —
                    // so the spec is now a property of the backdrop rather than a message about it.
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
            // A FRESH VIEWER HAS NO SHEET, EITHER — and this is the half the resume below could
            // not cover. `showViewers`/`viewersProgress` are HOST state, so they outlive this
            // overlay, and a drag the system cancelled can leave them parked with the sheet at
            // 1-2% — invisible, below the self-heal's floor, below the close guards — while the
            // 0.5s freeze watchdog polices `> 0.01` forever after. That is his 2026-08-09 "opens
            // paused" screenshot on someone ELSE's story: the resume below fired at mount, held
            // for half a second, and then the stale watchdog paused the fresh viewer again, every
            // visit, until the app died. Assert the whole truth of a fresh open, not just the
            // pause half of it.
            progressWatchdog?.cancel(); progressWatchdog = nil
            sheetAnimator.cancel()
            showViewers = false          // its onChange zeroes the progress + resets the card
            viewersProgress = 0          // belt: that onChange is silent if showViewers was already false
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
        // Nil when a reply bar is actually shown, so the pill and the bar can never both appear —
        // they are the same slot. The two reasons are worded differently on purpose: one is the
        // author's choice about their own story, the other is about who you and they are to each
        // other, and telling somebody "they turned replies off" when that is not what happened would
        // be a small lie about a person.
        //
        // Same three conditions the reply bar itself is built from, so the pill appears exactly
        // where a bar would have been and never anywhere else: somebody else's story, somebody you
        // actually have a chat with, and replies refused.
        // ⚠️ BOTH REASONS NOW, NOT JUST ONE. This was gated on `isFriend`, so it only spoke when the
        // AUTHOR had refused replies — and said nothing at all for a stranger, who is the other case
        // the bar is withheld from. The result was a story with no bar and no explanation, which is
        // his 2026-08-07 report: "im not seeing reply bar… show Reply Lock but never hide reply bar".
        //
        // It does NOT undo the L3 privacy rule. That rule is about not handing somebody a direct line
        // to a person who never accepted them, and a sentence saying the line is closed is not a
        // line. What changes is that the closed door is now visible instead of being an empty strip.
        .overlay(alignment: .bottom) {
            if !currentIsMine, let reason = replyLockReason {
                Text(reason)
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

    // ⚠️ `scheduleFrozenCapture` AND `captureFrozenCover` ARE GONE, AND NOTHING REPLACES THEM HERE.
    //
    // Between them they were a 0.35s settle-and-verify timer, a force flag, a url cross-check, a
    // live-card photograph through one global pointer, and a sweep over every other story — all to
    // answer one question: what picture does this card show? A card answers that for itself now, at
    // draw time, from the frame bank keyed by its own clip (`cardMedia`).
    //
    // The reason this could not have been done before today is that the bank was EMPTY at the one
    // moment it mattered. It was written only when a clip changed or stopped, and the viewers sheet
    // does neither — it pauses. `StoryCardMorph.bankCurrentFrame`, called from the pause itself,
    // is what filled that hole, and filling it is what made every line above unnecessary rather
    // than merely badly timed.

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
        // The WORDS come from `storyAudienceTitle`, which the viewers sheet's tab reads too, so the
        // pill on the story and the tab over its viewers can never name the same audience two ways.
        let text = storyAudienceTitle(for: s)
        if s.oneTime { return StoryAudienceBadge(systemImage: "1.circle", text: text) }
        switch s.audienceLabel {
        case "everyone": return StoryAudienceBadge(systemImage: "globe", text: text)
        case "custom":
            // The owner's own folder drawing (2026-08-07). OUTLINE here: this pill is a thin line of
            // white over a photograph, next to a light-weight name, and the filled version reads as a
            // blob at 12pt. The filled one is used where the glyph sits on a solid tinted circle —
            // the same outline-vs-filled split the app's other icon pairs already use.
            return StoryAudienceBadge(systemImage: "person.crop.rectangle.stack",
                                      assetImage: "ic_story_folder",
                                      text: text)
        default: return StoryAudienceBadge(systemImage: "person.2.fill", text: text)
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
                                          // ⚠️ REVERTED 2026-08-09 EVENING, BUILD 512, his second
                                          // corner screenshot: `hero.exiting ? 0 : heroChrome(f)`
                                          // swapped one artifact for a worse one. The mask's
                                          // `outside` is a BLACK PAINT over the notch, NOT a crop —
                                          // the exit-hides-the-surround rule twenty lines down is
                                          // about the SwiftUI furniture, and applying it here
                                          // removed the only thing hiding the card's square
                                          // corners, so the story's own photo showed dimmed in
                                          // every corner for the WHOLE close (his Test Amina
                                          // screenshot, photo-textured wedges). The original black
                                          // notch in the first 18% is the lesser wrong until the
                                          // hole truly CROPS (the parked mask-geometry work).
                                          //
                                          // ⚠️ THAT PARKED WORK HAS SINCE LANDED and the sentence
                                          // above is now history: `applyMask`'s surround is its own
                                          // layer with an even-odd cutout, so `outside` paints only
                                          // BEYOND the hole and never over the notch. Read the note
                                          // there before changing this argument again — the black
                                          // wedges around a circular close were the cutout's shape,
                                          // not this number.
                                          chrome: heroChrome(f),
                                          crop: hero.crop,
                                          // A circular door times its circle differently coming and
                                          // going — see `StoryCardMorph.circleRushSpan`. This is the
                                          // same flag `heroChrome` reads, so the two cannot disagree
                                          // about which direction the flight is travelling.
                                          exiting: hero.exiting)
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
        // ⚠️ A CIRCLE HANDS OVER SOONER, and it has to. The cover is a photograph of the thing that
        // was tapped, and for a circular door that thing is a 49pt avatar — by the point a card's
        // crossfade is still half on, the circle has already grown past 250pt and the cover is a
        // four-times enlargement of a thumbnail lying over a story that is sharp underneath it. His
        // Snapchat reference shows the picture inside the circle almost from the first frame.
        let start: CGFloat = heroLandingIsCircle ? 0.05 : 0.2
        let span: CGFloat = heroLandingIsCircle ? 0.25 : 0.35
        return 1 - max(0, min(1, (t - start) / span))
    }

    /// TRUE when the door this story came out of is a circle (a chat-row ring, a profile avatar)
    /// rather than a card. The same test `StoryCardMorph.applyCore` makes, asked of the same two
    /// numbers, so the cover and the mask cannot disagree about which journey is running.
    private var heroLandingIsCircle: Bool {
        let key = MediaOpenRects.key(.storyRow, heroKeyNow())
        guard let r = MediaOpenRects.liveRect(key), r.width > 1 else { return false }
        return MediaOpenRects.cornerRadius(key) >= min(r.width, r.height) / 2 - 0.5
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
    /// ⚠️ NO PLATEAU. It used to hold a flat `heroDimMax` from f 0.15 all the way to 0.75 and only
    /// let go over the last quarter, which is 60% of the journey during which the backdrop did not
    /// move at all. That is his 2026-08-07 report in as many words: "the dimming level does not feel
    /// fluid or bound to the story frame scale… bind the overlay's opacity directly to the transition
    /// progress". A drag is exactly where a plateau is most visible, because his finger is setting
    /// the fraction by hand and the background is answering with a constant.
    ///
    /// One continuous, monotonic curve now. It is written every frame already (`applyCore` sets the
    /// wall's `backgroundColor` inside the same disabled-actions transaction as the transform), so
    /// binding it to `f` binds it to the finger.
    ///
    /// The two ends are still DIFFERENT and that part must not be "simplified":
    /// * f → 0 (full screen) goes to OPAQUE, not to `heroDimMax`. The wall IS the story screen's
    ///   black above and below the card, so it has to arrive WITH the card. A symmetric curve here
    ///   was his build-487 report, with the white strips circled top and bottom.
    /// * f → 1 (the row) lets go to nothing, so the landing reveals the chat list rather than a grey
    ///   pane sitting over it at the exact moment the cover is lifted.
    private func heroDim(_ f: CGFloat) -> CGFloat {
        let f = max(0, min(1, f))
        // The last stretch into full screen, where the letterbox has to become solid.
        if f < Self.heroDimSolid {
            return 1 - (1 - Self.heroDimMax) * (f / Self.heroDimSolid)
        }
        // Everything else: down towards the FLOOR, proportional to how far the card has travelled.
        // Linear on purpose — "proportional to the user's drag distance" is what he asked for, and an
        // eased curve would put the change somewhere other than where his finger is.
        //
        // ⚠️ THE FLOOR IS MIXED IN, NOT CLAMPED ON. `hero.dimFloor` is 1 while his finger is down and
        // is faded out by a committed landing (and in by an open), so the backdrop stays dark through
        // the whole pull and still reaches exactly zero at both ends of a flight. Clamping instead
        // would paint a 36% wall on the frame the screen is removed, which is the grey flash.
        let travelled = (f - Self.heroDimSolid) / (1 - Self.heroDimSolid)
        let floor = Self.heroDimFloor * max(0, min(1, hero.dimFloor))
        return floor + (Self.heroDimMax - floor) * (1 - travelled)
    }
    /// How much of the journey nearest full screen is spent turning the wall solid.
    private static let heroDimSolid: CGFloat = 0.15

    /// THE CARD THIS STORY BELONGS TO RIGHT NOW, which is not always the one it was opened from.
    ///
    /// A friend's viewer pages from person to person. Closing the fourth person's story back into
    /// the first person's card would be a matched transition that does not match anything — the
    /// picture flying home would land on somebody else's face. So the current bucket's own card is
    /// preferred, and the one it opened from is the fallback for the moment before the first bucket
    /// is reported.
    /// Why the reply bar is not there, or nil when it is. Mirrors the SAME two tests the bar itself
    /// is built from (`storyType` in `libraryStories`), so the pill can never appear next to a bar
    /// or leave the slot empty — those two staying in step is the whole point of reading them here
    /// rather than re-deciding.
    private var replyLockReason: String? {
        guard !currentIsMine else { return nil }          // my own story has the owner bar instead
        guard deliveredToMe || StoryContact.isFriend(currentBucketUid) else {
            return "You can only reply to people you chat with 🔒"
        }
        guard currentStory?.allowsReplies == false else { return nil }   // a real bar is showing
        return "You can't reply to this story 🔒"
    }

    /// Tell the world which person is on screen. Called at the open and on every change of person.
    ///
    /// The row card's key IS the group id, and the row identifies its cards by `authorUid` — both
    /// spellings go out together so the row can scroll to him and the flight can land on him without
    /// either having to derive the other.
    private func publishActive(_ uid: String) {
        guard heroDismiss, !heroSourcePinned else { return }
        guard let g = groups.first(where: { $0.authorUid == uid }) else { return }
        StoryDoorState.shared.setActive(sourceKey: g.id, authorUid: g.authorUid)
        // The hole and the cover move to him too, so the close he gets is the same close the
        // tapped person gets (his 2026-08-08 "different transition after swiping" report). At rest
        // only — a retarget under a live flight would swap the exchange mid-air; the pans are
        // direction-locked so this should never fire then, and if it somehow does, the close falls
        // back to the fade landing rather than glitching.
        guard !hero.live, !hero.committing else { return }
        StoryDoor.retarget(to: g.id)
    }

    /// WHERE THE CLOSE LANDS: the person he is on, never the person he came in through.
    ///
    /// ⚠️ THE OLD FALLBACK WAS THE BUG, NOT A SAFETY NET. This used to test whether the active
    /// person's card was on screen and, if it was not, return `heroSourceKey` — the person the viewer
    /// was opened from. A row that has not scrolled has the fourth person off to the right, so
    /// Abdi → Ali → Salmo → Saki and a pull down flew the story home to ABDI. His report, and his
    /// instruction: no special case for the opener, one live answer instead.
    ///
    /// The on-screen test has gone with it. It was never this function's question — `heroEndpoints`
    /// asks it, which is the place that has to answer "is there anywhere to fly", and it now gets a
    /// yes because `StoriesRow` scrolls the row to whoever is active while the viewer is up.
    private func heroKeyNow() -> String {
        guard heroDismiss else { return "" }
        // A pinned door has one anchor and it does not move — see `heroSourcePinned`.
        guard !heroSourcePinned else { return heroSourceKey }
        if let key = StoryDoorState.shared.activeSourceKey, !key.isEmpty { return key }
        // Only before the library has reported a first person — the same instant `currentBucketUid`
        // is still empty. That IS the opening person, so it is not a special case for him, it is the
        // only thing that is true yet.
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
        // ⚠️ `liveViewRect`, NOT `liveRect`. The difference is the written-down fallback, and for a
        // door that lives in the chat that fallback is a rectangle where the source USED to be —
        // see the note on `liveViewRect`. The doc above already says a written-down rect is only as
        // true as the last layout pass that wrote it; this is the line that finally acts on it.
        //
        // Every story door registers a real anchor (`MediaRectReporter` installs `MediaViewAnchor`
        // alongside the rect), so a door that is genuinely on screen always has one and loses
        // nothing here. A door that is NOT on screen now says so instead of guessing.
        guard !key.isEmpty,
              let r = MediaOpenRects.liveViewRect(MediaOpenRects.key(.storyRow, key)),
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
                         dimFloor: ((CGFloat) -> CGFloat)? = nil,
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
            if let dimFloor { hero.dimFloor = dimFloor(t) }
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
            // ⚠️ EXCEPT OUT OF A CIRCLE, WHICH OPENS AS A CARD LIKE EVERY OTHER DOOR. His
            // 2026-08-08 report: "when I open a story from the chat row it opens as a circle,
            // it should open normally like the other stories".
            //
            // The cover goes with the circle and it has to: a circular door's cover is a photograph
            // of a ROUND avatar, cut to that radius, so its corners are empty. Seat it in a
            // card-shaped hole and those empty corners show the wall behind — a round picture in a
            // square frame, which is worse than the circle he is asking me to remove. Without a
            // cover the seat is the live story from its first frame, growing out of the ring's
            // rectangle exactly as a story grows out of a row card. That is the "no cover" flight
            // this code already supports and calls correct.
            //
            // The CLOSE is untouched and still becomes a circle — see `circleRushSpan`. That half
            // he likes, and it is Snapchat's and WhatsApp's behaviour: out as a card, home as a
            // circle.
            let fromCircle = heroLandingIsCircle
            hero.cover = !fromCircle
            hero.coverAlpha = fromCircle ? 0 : 1
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
            // The floor fades IN as the story grows, so the open's first frame — the card still
            // sitting on the row — darkens nothing, and the list is already dim by the time the card
            // is out in the room. Matching his Snapchat reference, where the page behind the growing
            // circle is clearly dimmed.
            runHero(to: 0, center: rest, alpha: 1, velocity: 0,
                    stiffness: 530, settle: 0.0015,
                    cover: heroCoverOut, crop: heroCoverOut, dimFloor: { $0 }) {
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
    /// The largest `f` a DRAG may reach, so the card stops shrinking at `heroDragMinScale`.
    ///
    /// Derived from the anchor rather than written down, because `f` is a journey between two real
    /// sizes and those are not the same distance apart at every door: a chat-row ring is 49pt and a
    /// story card is about 90, so the same fraction leaves the card at two different sizes. Asking
    /// the geometry keeps one number ("a third of the screen") true everywhere instead of one number
    /// per door, which is how this area accumulates copies that drift.
    private func heroDragCeiling() -> CGFloat {
        guard let rect = StoryCardMorph.shared.flightRestRect, rect.width > 1 else { return 1 }
        let ratio = max(0, min(0.99, hero.anchor.width / rect.width))
        // An anchor already bigger than the floor has nothing to clamp: the whole journey is shorter
        // than the limit, so let it run.
        guard ratio < Self.heroDragMinScale else { return 1 }
        return max(0.05, min(1, (1 - Self.heroDragMinScale) / (1 - ratio)))
    }

    /// Where the card's centre goes for a finger that has travelled `ty` down.
    private func heroDragY(_ ty: CGFloat, ceiling: CGFloat) -> CGFloat {
        // 1:1 for as long as the card is still shrinking — his spec, and the part of this gesture he
        // has always said feels right.
        let free = Self.heroDragSpan * ceiling
        var y = hero.rest.y + (ty <= free
            ? ty
            // Past it: a rubber band onto a fixed tail, asymptotic, so the card never quite reaches
            // the end of it however hard he pulls and the gesture never goes dead under his finger.
            : free + Self.heroDragTail * (1 - 1 / ((ty - free) / Self.heroDragTail + 1)))
        // AND THE BOTTOM EDGE STAYS ON THE DISPLAY. The band alone would still let a card that
        // bottoms out early drift under the tab bar, which is the half of his screenshot the floor
        // does not answer. The card's rendered height at this instant is what decides where that is,
        // so the stop moves with the shrink instead of being a second guess at it.
        if let rect = StoryCardMorph.shared.flightRestRect, rect.width > 1 {
            let scaleNow = 1 + (hero.anchor.width / rect.width - 1) * hero.f
            let floorY = UIScreen.main.bounds.height - rect.height * scaleNow / 2 - 10
            y = min(y, max(hero.rest.y, floorY))
        }
        return y
    }

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
            // AGAINST THE COVER'S OWN KEY, not the opener's: the cover follows the swipe now
            // (`StoryDoor.retarget`), so the question is "is the picture on the cover the card I
            // am landing on", and the presenter is the one who knows what it is wearing.
            hero.cover = StoryZoomPresenter.coverSourceKey == heroKeyNow()
            hero.coverAlpha = 0
            hero.exiting = true        // a pull is an exit: the black page goes now, not over 76pt
            // THE FINGER OWNS THE FLOOR. Held at full for the whole drag, so the backdrop cannot
            // wash out however far he pulls; a committed landing fades it back out. See `dimFloor`.
            hero.dimFloor = 1
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
            // ⚠️ THE PULL HAS A FLOOR NOW, and his 2026-08-07 pair of screenshots is where it comes
            // from. Snapchat's card bottoms out at just under a third of the screen and will not go
            // further however long you keep pulling. Ours had no floor at all: `f` ran to 1, which is
            // the ANCHOR'S own size — a 49pt ring — and once there the card simply kept sliding down
            // at that size until it was sitting under the tab bar. That is his "theres no limit", and
            // his shot of a story the size of a tab-bar icon is what it looks like.
            //
            // Only the part the finger owns is bounded. A committed close still flies all the way to
            // `f = 1` and lands in the slot exactly as before — the landing is not a drag.
            let ceiling = heroDragCeiling()
            hero.f = min(ceiling, ty / Self.heroDragSpan)
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
            // AND THE TRAVEL IS BOUNDED TOO, or the card would go on falling at its floor size —
            // which is the same screenshot from the other direction. 1:1 with the finger for the
            // whole stretch that is still shrinking the card, then a rubber band onto a short tail,
            // then a hard stop that keeps the card's bottom edge on the display.
            hero.center = CGPoint(x: hero.rest.x, y: heroDragY(ty, ceiling: ceiling))
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
            // ⚠️ NOT WHILE THE SCREEN IS STILL UP. This flag means "the card is being moved by
            // something that is not a page swipe", and while it is raised `StoryDetailView` returns
            // a fold angle of ZERO. Clearing it re-enables a fold that derives from the page's
            // GLOBAL minX — and at this exact moment the card is parked on the row card, which is a
            // long way from centre, so the angle it computes is large.
            //
            // On the presenter door the screen does not go away here. `heroClose` reveals the source
            // and tears down 0.03s later, deliberately, so the row card is back underneath before
            // the copy is lifted off it. Those two frames used to run with the fold switched back
            // on over a card that is still displaced: the library's own comment for this flag calls
            // that "a sudden violent 3D fold (flipped/black frames on close)". That is the shape of
            // the post-dismissal flash.
            //
            // The presenter clears it in `tearDown`, when the screen is actually gone, and in
            // `noteDismissed` for any exit we did not drive. The old cover door has no presenter and
            // removes its viewer synchronously right here, so it still clears it itself — there,
            // "landed" and "gone" really are the same instant.
            if !StoryZoomPresenter.isActive { StoryCardMorph.heroDismissActive = false }
        }
        // The cover-and-hole landing belongs to whoever the cover is a PICTURE of. That used to be
        // the tapped person alone, so a close after swiping to somebody else fell back to a fade
        // landing onto their still-visible card — his 2026-08-08 report, "a different transition".
        // The hole and the cover follow the swipe now (`StoryDoor.retarget`), so on the main path
        // this is true for whoever he is on. The fade landing below survives as the fallback for a
        // retarget that could not photograph the card — a wrong-picture cover would be worse than
        // none: solid while it travels (t³), melting into the visible card as it arrives.
        hero.cover = StoryZoomPresenter.coverSourceKey == heroKeyNow()
        if hero.cover {
            // THE WHOLE EXCHANGE HAPPENS HERE, in the snap that follows the release: the flying
            // card cross-fades from the story he was watching into the row card's own picture —
            // avatar ring, border and all — and is finished before it touches down.
            // AND THE FLOOR LEAVES WITH THE CARD. The dim runs to a true zero as the landing
            // completes, so the frame the screen is removed has no wall left on it — the grey-to-
            // white flash this file has warned about since it was written. The floor is the DRAG's,
            // not the landing's.
            runHero(to: 1, center: anchorCentre, alpha: 1, velocity: min(6, max(0, vy) / remaining),
                    cover: heroCoverIn, crop: heroCoverIn, dimFloor: { 1 - $0 }, done: land)
        } else {
            // No cover on this one, but the SHAPE still has to converge: it is landing on somebody
            // else's card and a 9:16 rectangle would overhang their slot top and bottom. Same curve,
            // so it too is the row's shape before it touches down.
            runHero(to: 1, center: anchorCentre, alpha: 0, velocity: min(6, max(0, vy) / remaining),
                    alphaCurve: { $0 * $0 * $0 }, crop: heroCoverIn,
                    dimFloor: { 1 - $0 }, done: land)
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
                              hideActiveContent: !carouselOwnsSlot,
                              onInteracting: { carouselInteracting = $0 },
                              pageDrag: pageDragBox)
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
        // WHICH TABS THIS STORY'S VIEWERS LIST GETS, from the same two functions the story's own
        // audience pill reads. Recomputed here rather than latched, because the sheet pages sideways
        // between stories and `sheetStoryId` moves with it — so the tab follows the story you are
        // looking at rather than the one you opened the sheet on.
        let sheetStory = arr.first { $0.id == sheetStoryId }
        return StoryViewersSheet(activeStoryId: sheetStoryId,
                          audienceTitle: sheetStory.map { storyAudienceTitle(for: $0) } ?? "All Viewers",
                          audienceHasBothTabs: storyAudienceHasBothTabs(sheetStory),
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
                                  // Same rule as the commit below: the flag describes the MOVEMENT,
                                  // so it cannot be dropped on the frame the movement starts.
                                  withAnimation(.easeOut(duration: 0.28)) {
                                      pageDragBox.value = 0
                                  } completion: {
                                      sheetPaging = false
                                  }
                                  return
                              }
                              // The drag zeroes IN THE SAME TRANSACTION as the id flip, on the
                              // panel's own 0.28s return curve — the row glides its remaining
                              // distance while the new sheet slides in, one motion.
                              //
                              // ⚠️ AND THE FLAG OUTLIVES THE GESTURE, BECAUSE THE MOTION DOES.
                              //
                              // `sheetPaging = false` used to run on this line, one frame into a
                              // 0.28s glide the row has not started yet. For the whole glide
                              // `carouselOwnsSlot` was false, so the live story was handed back to
                              // the slot while the row was still two thirds of a card off centre,
                              // and the cards slid straight over the top of it — his overlapping
                              // cards. The gesture is over; the movement it started is not, and this
                              // flag describes the movement.
                              withAnimation(.easeOut(duration: 0.28)) {
                                  sheetStoryId = live[i + d].id
                                  pageDragBox.value = 0
                              } completion: {
                                  sheetPaging = false
                              }
                          },
                          // THE ONLY PER-FRAME WRITE, and it goes to the box. The boolean beside
                          // it changes twice a drag, which is what the host actually needs to know.
                          onPageDrag: { f in
                              // ⚠️ A DRAG THAT IS GIVEN UP DOES NOT TELEPORT THE ROW.
                              //
                              // The sheet answers an abandoned page by calling this with 0 and THEN
                              // springing its panel home over 0.3s. Written straight through, the row
                              // jumped back to centre in one frame while the panel was still
                              // travelling: two halves of one gesture on two different clocks, which
                              // is the other half of his "swipe is not smooth". It now walks home on
                              // the panel's own curve, and `sheetPaging` stays up until it arrives,
                              // for the same reason the commit's does.
                              //
                              // (SwiftUI's `.spring(response:dampingFraction:)` is not arithmetically
                              // identical to UIKit's `usingSpringWithDamping` — see the translation
                              // note in the row's UIKit rewrite — but over 0.3s at 0.9 damping the
                              // two are within a frame of each other, and the alternative is a jump.)
                              guard f != 0 else {
                                  guard pageDragBox.value != 0 else {
                                      if sheetPaging { sheetPaging = false }
                                      return
                                  }
                                  withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
                                      pageDragBox.value = 0
                                  } completion: {
                                      sheetPaging = false
                                  }
                                  return
                              }
                              pageDragBox.value = f
                              if !sheetPaging { sheetPaging = true }
                          },
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
        // > 0.001, NOT > 0.02. The heal's floor must sit BELOW the freeze watchdog's trip line
        // (> 0.01), or there is a band — a cancelled drag parked at 1-2% — that the watchdog
        // polices forever and nobody heals. That band is where his "every story opens paused"
        // state was born. Anything parked above zero is a sheet in a state no finger asked for.
        guard showViewers, p > 0.001, p < 0.995 else { return }
        progressWatchdog = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled, showViewers,
                  viewersProgress > 0.001, viewersProgress < 0.995,
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
        // ⚠️ THE DEFERRED JUMP IS SPENT HERE, at the START of the collapse, which is the same beat
        // Telegram builds the player it refused to build while the list was up. The clip loads
        // behind a card that is already flying back to full screen, so the load is covered by the
        // motion instead of happening under a 100pt thumbnail. Posted before the animator so the
        // library has the whole collapse to get its first frame up.
        // ⚠️ ASKED, NOT REMEMBERED. This used to spend a `pendingJumpStoryId` that an `onChange`
        // handler had written earlier — and when that handler was silently skipped (its guard wanted
        // `currentIsMine`, which arrives a beat after the sheet can open), there was nothing to spend
        // and the close landed back on the story he started from. His report, second half.
        //
        // The row's own centred card is the answer and it is sitting right there. The library's
        // receiver already refuses a jump to the item it is on (`idx != getCurrentIndex()`), so the
        // "already there" case needs no test of ours.
        if rowIsOnAnotherStory {
            let landing = sheetStoryId
            NotificationCenter.default.post(name: .init("jumpToStoryItem"), object: landing)
            // ⚠️ AND THE ANCHOR MOVES WITH IT, IN THE SAME BREATH.
            //
            // `currentStoryId` means "the item the library is on", and we have just told it to be on
            // `landing`. Without this line it keeps naming the old story until `onItemSeen` fires —
            // which the library WITHHOLDS while a story is paused, and the story stays paused until
            // the very end of the collapse. So for the whole of that collapse `rowIsOnAnotherStory`
            // would still answer true, the carousel would still own the slot, and the story would
            // grow back to full screen with the live card standing aside.
            //
            // This is not a second copy of anything: it is the one anchor, updated at the moment the
            // thing it describes actually changed, instead of waiting for a receipt that cannot
            // arrive yet.
            currentStoryId = landing
        }
        sheetAnimator.animate(from: viewersProgress, to: 0, velocity: velocity, write: { viewersProgress = $0 }) {
            // Reaching here means the close actually finished (a re-open cancels this animator).
            showViewers = false
            NotificationCenter.default.post(name: .init("storyChromeHidden"), object: false)   // chrome back
            // Say the resume OUT LOUD. The crossing-based onChange (`viewersProgress > 0.01`)
            // only resumes if the pull ever rose ABOVE its line — but the gesture's entry posted
            // `pauseStory` directly, before any progress existed. A pull parked below 1% and then
            // healed here crossed nothing, and the story stayed paused with no repauser to blame.
            // A fully closed sheet over an open viewer is a moment the story is definitely meant
            // to be running — the same unconditional truth every other resume post leans on.
            NotificationCenter.default.post(name: .init("resumeStory"), object: nil)
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
        // Number + one letter, no "ago" (owner 2026-08-09: "12 Sec ago" → "12s"). A story lives 24h,
        // so h is the ceiling in practice; d/w cover the archive, which formats through this too.
        let s = max(0, Int(Date().timeIntervalSince(d)))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86_400 { return "\(s / 3600)h" }
        if s < 7 * 86_400 { return "\(s / 86_400)d" }
        return "\(s / (7 * 86_400))w"
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
        // ⚠️ CLEARED FIRST, BECAUSE THE OLD ANSWER IS WRONG THE INSTANT THE STORY CHANGES. This only
        // ever ASSIGNED, and only on success — so tapping from a story with 12 views to one with
        // none kept reading "12 Views" with the previous story's avatars for the whole network round
        // trip, then dropped to 0. It leaked the other way too: leave your own bucket for a friend's
        // and come back, and the footer painted with the old bucket's viewers for the first frames.
        // An empty footer for a moment is honest; somebody else's numbers are not.
        guard currentIsMine, !currentStoryId.isEmpty else {
            if !barViewers.isEmpty { barViewers = [] }
            return
        }
        let id = currentStoryId
        if lastBarViewersStoryId != id {
            lastBarViewersStoryId = id
            barViewers = []
        }
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
    /// The uploading card this flew out of, so the close can fly back into it. Empty degrades to the
    /// presenter's drift-away, which is what any door with nowhere to land gets.
    var heroSourceKey: String = ""
    var onHeroClose: (() -> Void)? = nil          // the flight has landed: take the screen away
    var onClose: () -> Void                       // no flight (nowhere to land, or a sheet was up)
    var onProfile: (StoryGroup) -> Void = { _ in }
    @State private var repo = StoriesRepository.shared
    @State private var svc = StoriesService.shared
    /// Is the card flying? While it is, this view's own backdrop steps aside — see `body`.
    @State private var flightActive = false

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
            // ⚠️ CLEAR WHILE THE CARD IS IN THE AIR, and this is the only structural difference
            // between this door and the five that behave correctly.
            //
            // His report: scrolling down out of an UPLOADING story shows black at the top header
            // and along the bottom, which his own story does not do. Every other door presents
            // `StoryViewer` directly. This one wraps it in a full-screen opaque black, and the
            // flight has NO WAY TO CLEAR IT: the pager's own background is managed for exactly this
            // reason (`StoryCardMorph.prepareForHero` sets it clear so the shrinking card reveals
            // the chat list, `restoreAfterHero` puts it back), but that hook owns the pager's view,
            // not a SwiftUI sibling sitting behind it. So this black stayed full-screen behind a
            // card that was shrinking away from it.
            //
            // The reason it exists has narrowed: the viewer used to be RE-CREATED when the upload
            // finished (`.id(svc.uploading)`, since removed — the swap reconciles in place now), and
            // this backdrop stopped that recreation blinking. It stays as the door's opaque ground.
            // It only has to be constant AT REST. `storyFlightActive` is already the app's answer to
            // "is the card in the air" — the same signal the reply bar and the caption leave on —
            // so the backdrop now steps aside for exactly the moments the flight owns the screen.
            Color.black.ignoresSafeArea()
                .opacity(flightActive ? 0 : 1)
                .onReceive(NotificationCenter.default.publisher(for: .init("storyFlightActive"))) { note in
                    let active = (note.object as? Bool) ?? false
                    if active != flightActive { flightActive = active }
                }
            if let g = group {
                // The app's own flight, same as every other story: it grows out of the uploading
                // card and the drag-down flies back into it. `heroSourcePinned` because there is
                // exactly one card in the row for a story that has not finished posting.
                StoryViewer(group: g,
                            heroDismiss: !heroSourceKey.isEmpty,
                            heroSourceKey: heroSourceKey, heroSourcePinned: true,
                            onHeroClose: onHeroClose,
                            onClose: onClose, onProfile: onProfile)
                    // ⚠️ NO `.id(svc.uploading)` — THAT WAS THE CLOSE-AND-REOPEN. Re-keying on the
                    // upload flag destroyed and recreated the WHOLE viewer the moment a background
                    // post landed, whatever story he was watching (his 2026-08-09 report: watching A
                    // while C uploads, C finishes, A closes/reopens). The viewer now stays alive and
                    // the placeholder→real swap flows through `reconcileSignature` in StoryViewer —
                    // Telegram's behaviour: a background post is a data update, never a transition.
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
    /// ⚠️ `@ObservedObject`, SO THIS IS THE ONLY VIEW A PAGE-DRAG RE-RENDERS. It used to be a plain
    /// `CGFloat` copied down from the host's `@State`, which meant every frame of the drag
    /// invalidated the host's whole body — the pager, the sheet, every overlay — to move this row.
    /// See `pageDragBox` on the host.
    @ObservedObject var pageDrag: StorySheetPageDrag

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

    /// A finger or the native glide owns the row — reported by `CarouselScroller`.
    @State private var scrollerBusy = false
    /// OUR OWN spring is carrying the row to a card somebody else chose (`onChange(of: activeId)`).
    /// The scroller knows nothing about this one, which is exactly how the hole below opened.
    @State private var retargeting = false

    /// ⚠️ THE ONE ANSWER TO "IS THE ROW STILL MOVING", and the reason the centre card stopped ending
    /// up UNDERNEATH its neighbours.
    ///
    /// The live story is not drawn by this carousel. It is the real story view, parked at the slot
    /// centre by `driveMorph`, and the host hides it (`StoryCardMorph.setHidden`) from exactly this
    /// signal so the carousel can draw its own centre card while the row slides. The carousel is a
    /// SwiftUI layer ABOVE the story, so the moment this says "at rest" while the row is in fact
    /// off-centre, the story is revealed in the middle and the neighbour cards — which are directly
    /// over it and overlap the slot at any fractional position — cover it. That is his report: the
    /// active centre picture behind the ones that should be behind IT.
    ///
    /// It used to be the scroller's word alone, and the scroller only knows about fingers. A sheet
    /// paged sideways retargets `activeId`, which springs `scroll` for 0.30s with no finger anywhere
    /// — the whole glide ran with the story exposed. `retargeting` closes that path and the
    /// fractional test is the belt for any path neither of them knows about: whatever the reason, a
    /// row that is not sitting on a whole card has not finished moving.
    /// ⚠️ AND THE BELT MUST BE MEASURED ON THE ROW THAT IS ON SCREEN, NOT ON `scroll` ALONE.
    ///
    /// His 2026-08-10 report, "the window cards are overlapping when I swipe the viewers sheet",
    /// MEASURED off the screenshot rather than reasoned: the four row cards were exactly where this
    /// file's own formula puts them at 0.63 of a card past centre, spacing perfect, while the card
    /// filling the slot sat at dead centre wearing the scale of a card 0.37 to the LEFT. Position and
    /// scale disagreeing by exactly the page-drag is the signature of the live story — the one view
    /// that is parked at the slot centre and cannot slide — being on screen during a swipe.
    ///
    /// The row's real position is `scroll - pageDrag.value`, and this line only ever looked at
    /// `scroll`. A sheet page-drag moves the row entirely through `pageDrag`: `scroll` stays on a
    /// whole number for the length of the drag, so the belt answered "landed" while the row was
    /// visibly two thirds of a card away. Both gesture flags can be false there too — the commit
    /// clears `sheetPaging` on the first frame of a 0.28s glide, and a drag abandoned below the
    /// commit threshold clears it with the panel still springing home — which is exactly the "any
    /// path neither of them knows about" this test was written to cover and could not, because it
    /// was reading the wrong number.
    private var rowBusy: Bool {
        let onScreen = scroll - pageDrag.value
        return scrollerBusy || retargeting || abs(onScreen - onScreen.rounded()) > 0.002
    }

    /// The card the carousel considers centred. Derived, never stored: with `scroll` continuous
    /// there is exactly one answer and it cannot drift from what is on screen.
    private var index: Int {
        // `Int(_:)` traps on infinity and NaN rather than clamping. `scroll` is written by a
        // division, and this is read on every layout pass — see the 463 crash for what that costs.
        scroll.isFinite ? max(0, min(max(0, stories.count - 1), Int(scroll.rounded()))) : 0
    }

    init(stories: [Story], activeId: Binding<String>, slotW: CGFloat, slotH: CGFloat, miniH: CGFloat, cropY: CGFloat,
         onActiveTap: @escaping () -> Void = {}, hideActiveContent: Bool = false,
         onInteracting: @escaping (Bool) -> Void = { _ in }, pageDrag: StorySheetPageDrag) {
        self.stories = stories
        self._activeId = activeId
        self.slotW = slotW
        self.slotH = slotH
        self.miniH = miniH
        self.cropY = cropY
        self.onActiveTap = onActiveTap
        self.hideActiveContent = hideActiveContent
        self.onInteracting = onInteracting
        self._pageDrag = ObservedObject(wrappedValue: pageDrag)
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
                        // `pageDrag` IS ALREADY IN CARD UNITS — a fraction of the panel's journey,
                        // and one panel journey is one card. See the long note at `onPageDrag` in
                        // StoryViewersSheetUIKit for why this must not be divided by anything: I
                        // divided it in build 493 and the row froze, then sent points instead and it
                        // overshot fourfold. The commit snaps the row to exactly +1 card, so only a
                        // value that reaches exactly 1.0 over a full panel travel lands where the
                        // snap lands.
                        let cf = CGFloat(i) - (scroll - pageDrag.value)
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
                                 // Into the local flag, not straight out to the host: `rowBusy` is
                                 // what the host hears, and the scroller is only one of its three
                                 // reasons to be true.
                                 onInteracting: { on in scrollerBusy = on },
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
        // External retarget → recentre. The scroller ignores pushed positions while a finger is down
        // (its sync checks isTracking), so this cannot fight a live drag.
        //
        // ⚠️ IT ANNOUNCES ITSELF. This is not rare — every sideways page of the viewers sheet lands
        // here — and for the length of the spring the row is off-centre with no finger on it. Told
        // nothing, the host gave the live story back at the first frame of the glide and the
        // neighbour cards spent 0.30s sliding over the top of it. See `rowBusy`.
        .onChange(of: activeId) { _, v in
            guard let ni = stories.firstIndex(where: { $0.id == v }), ni != index else { return }
            retargeting = true
            withAnimation(.interactiveSpring(response: 0.30, dampingFraction: 0.82)) {
                scroll = CGFloat(ni)
            } completion: {
                retargeting = false
            }
        }
        // ONE writer to the host. A finger, our own spring and the belt all speak through here, so
        // the live story is hidden for as long as any of them says the row has not landed.
        .onChange(of: rowBusy) { _, on in onInteracting(on) }
        // Re-seed from the opened-on story in case `stories` was still loading at init.
        .onAppear {
            if let ni = stories.firstIndex(where: { $0.id == activeId }), ni != index { scroll = CGFloat(ni) }
        }
        // ⚠️ KEYED ON THE STORIES. A bare `.task` runs once per MOUNT and never again, so the counts
        // were fetched once and a story that landed while the sheet was open kept "0" for the rest
        // of the session no matter how many people watched it. `id:` re-runs it when the set
        // changes, which is exactly when the answer it cached stopped being complete.
        .task(id: stories.map(\.id)) { await loadAll() }
    }

    /// The picture on a carousel card: the frame photographed off the live story if there is one,
    /// otherwise the poster the way it has always been.
    ///
    /// The fill lives INSIDE an overlay of `Color.clear` for the same reason every other fill in this
    /// file does: a bare `scaledToFill` reports its own oversized layout and the ZStack adopts it.
    @ViewBuilder private func cardMedia(_ s: Story) -> some View {
        // ⚠️ ASKED FOR BY STORY, AT DRAW TIME. There is no capture here, no timing and no moment to
        // get right — this card asks the frame bank for a picture of ITS OWN clip, and the bank was
        // written when that clip was frozen (see `StoryCardMorph.bankCurrentFrame`).
        //
        // What this replaces is the whole reason this area kept breaking: a dictionary the host
        // filled by PHOTOGRAPHING the live card through one global pointer at one player, at an
        // instant that was moved three times (`16ba3c63`, `13952868`, `8693f1ee`) and was still
        // wrong on build 520. A card that fetches its own picture cannot be handed the wrong story's
        // frame, cannot be left holding a stale one, and cannot miss its turn.
        //
        // Nil is the normal answer for a photo (nothing is ever banked for one, and a photo's poster
        // IS the photo) and for a video nobody has watched this session. Both fall through to the
        // poster below, which is exactly what they had before.
        if s.isVideo, let u = URL(string: s.mediaUrl),
           let shot = StoryPlaybackResume.cardFrame(u, width: slotW) {
            // ⚠️ PINNED TO THE SLOT, exactly like the branch below. `Color.clear` is size-NEUTRAL: it
            // accepts whatever size it is proposed, and inside the cover-flow `ZStack` that proposal
            // is not the card, it is the container. The poster branch cannot drift that way because
            // `StoryImage` carries its own sizing, so before the frozen covers were swept onto every
            // video story only the CENTRED card ever took this path and the difference never showed.
            // Once every card could take it, the cards stopped agreeing about how wide they were and
            // grew into each other — his overlapping window cards.
            Color.clear
                .frame(width: slotW, height: slotH)
                .overlay(Image(uiImage: shot).resizable().scaledToFill())
                .clipped()
        } else {
            // His 2026-08-08 report was: "non-centered cards lose their blur effect or show weak
            // blur. The blur only appears when the card is centered." That was a `UIVisualEffectView`
            // DROPPING ITS BLUR when composited at fractional opacity — which is exactly what the
            // cover-flow does to every card that is not centred (`.opacity(1 - 0.20 * scaleFraction)`
            // in the body above, on top of a `.scaleEffect`). The centre card was the only one drawn
            // at opacity 1, so it was the only one whose blur survived.
            //
            // It was patched with a pre-baked imitation of the material. The canvas ends the
            // question instead: a gradient at 80% opacity is the same gradient, 20% weaker, in every
            // card at once — there is no state in which it can be present for one card and absent
            // for its neighbour.
            StoryImage(url: s.previewUrl, fitCanvas: true, cardFillThreshold: slotH / slotW)
        }
    }

    private func card(_ s: Story) -> some View {
        let vs = byStory[s.id] ?? []
        let reacts = vs.filter { !($0.reaction ?? "").isEmpty }.count
        // IMAGE + CANVAS (build 213, user: keep both): the card is a live StoryImage(fitCanvas:) —
        // the whole image over its own canvas — exactly what the morph card shows, so the
        // morph→carousel hand-off at full-open is seamless (same view, same size). `fitCanvas` keeps
        // the story framed exactly as it is full-screen (user rule: keep image + backdrop if it has
        // one; fill with none if it doesn't). A story with a frozen cover draws that — see cardMedia.
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

// MARK: - Naming a story's audience, once

/// THE ONE PLACE THAT PUTS A NAME TO A STORY'S AUDIENCE.
///
/// Two screens say it: the pill under the author's own name on the story, and the tab over the
/// viewers list. They used to be unrelated, and the tab did not say it at all — it offered "All
/// Viewers" and "Friends" whatever the story had been posted to. Splitting the list that way only
/// means something when the audience could hold both kinds of person, which is a story posted to
/// Everyone; for My Friends, a custom list or View Once, every name in the list is already inside
/// that audience by definition, so the second tab is either the same list again or a shorter one for
/// no reason the reader asked for (his 2026-08-08 report).
///
/// ⚠️ THE NAME OF A CUSTOM LIST IS THE AUTHOR'S ALONE, and this function is only ever called for the
/// author's own story. The name is not in the story document; it lives on this device
/// (`StoryPrefs.audienceName`), so there is nothing here for anybody else to read even by mistake.
///
/// `oneTime` is tested FIRST because a View Once story carries the audience it was posted to AND its
/// own rule, and the rule is the narrower of the two.
func storyAudienceTitle(for s: Story) -> String {
    if s.oneTime { return "View once" }
    switch s.audienceLabel {
    case "everyone": return "Everyone"
    case "custom":
        // The author's private name for the list. A name this device happens not to have (posted
        // from another phone, or reinstalled) falls through to the plain type, which is the safe way
        // round to be wrong. The story still UPLOADING has no document id to file a name under, so it
        // reads the one the post in flight was given.
        let name = StoriesService.isPending(s.id)
            ? StoriesService.shared.uploadingAudienceName(for: s.id)
            : (StoryPrefs.audienceName(storyId: s.id) ?? "")
        return name.isEmpty ? "Custom" : name
    default: return "My Friends"
    }
}

/// Does this story's audience make a SECOND tab mean anything? Only Everyone does. See above.
func storyAudienceHasBothTabs(_ s: Story?) -> Bool {
    guard let s else { return false }
    return s.audienceLabel == "everyone" && !s.oneTime
}
