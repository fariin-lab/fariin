import SwiftUI
import PhotosUI
import Photos
import UIKit
import CoreImage
import StoryUI

// ⛔ TWENTY ARCS, AND NOT ONE MORE — and the reason a 29-story ring vanished entirely.
///
/// The gap between arcs was a fixed 2·lineWidth of circumference and the arc was whatever the
/// segment had left after taking it. The card ring is 37pt across, so 116pt of circumference: at 29
/// stories each segment is 116/29 = 4.005pt and the gap IS the segment, leaving eight thousandths
/// of a point of arc. At 30 the gap is wider than the segment, `to` lands before `from`, the
/// `to > from` guard skips every segment and the ring is not drawn at all.
///
/// 28 only "worked" because of the round line cap, which extends a stroke half its width past each
/// end: 28 dots of pure cap with no arc between them. That is the cliff he found — 28 draws, 29 is
/// invisible, 30 is gone.
///
/// ⚠️ THE LIMIT IS THE RING'S ALONE. It shows the twenty most recent stories; it does not group
/// them, does not stand for the ones it leaves out, and changes nothing about what is stored or what
/// opens. Tap a ring showing twenty arcs on an author with thirty stories and all thirty play, in
/// order, exactly as before (owner, 2026-08-20: "it should not limit or remove any stories
/// internally … all 30 stories must still exist and remain accessible").
enum StoryRingGeometry {
    /// His number. Twenty arcs on the 37pt card ring is 5.8pt of circumference each — a 2pt gap and
    /// an arc either side of it. Twenty-one is where they start becoming dots.
    static let maxSegments = 20

    /// One entry per arc, newest last, as the ring is drawn. Over the limit this is the LAST twenty
    /// — the most recent stories, one arc each, no grouping and no averaging.
    static func condensed(_ seen: [Bool]) -> [Bool] {
        seen.count > maxSegments ? Array(seen.suffix(maxSegments)) : seen
    }

    /// The gap, as a fraction of a turn: the same absolute 2·w it has always been, since that is
    /// what leaves a visible w once the round caps have eaten half of it at each end.
    ///
    /// The ceiling is a backstop and nothing more. At twenty arcs on any ring this app draws the
    /// absolute gap fits with arc to spare, so it cannot bind — tightening it below that would close
    /// the gaps rather than protect them and the ring would come out solid. It exists so that a ring
    /// too small for twenty arcs still draws twenty short ones instead of nothing at all.
    static func gap(count n: Int, diameter d: CGFloat, lineWidth w: CGFloat) -> CGFloat {
        guard n > 1, d > 0 else { return 0 }
        return min((w * 2) / (.pi * d), (1 / CGFloat(n)) * 0.7)
    }
}

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
            let activeW = lineWidth
            // The twenty most recent, if there are more than twenty — see StoryRingGeometry.
            let arcs = StoryRingGeometry.condensed(seen)
            let n = max(1, arcs.count)
            let seenW = max(1, lineWidth * 0.66)                       // inactiveLineWidth
            let gradient = AnyShapeStyle(LinearGradient(colors: [Color(hex: 0x34C76F), Color(hex: 0x3DA1FD)],
                                                        startPoint: .top, endPoint: .bottom))
            let grey = AnyShapeStyle(seenColor)
            let gap = StoryRingGeometry.gap(count: n, diameter: d, lineWidth: activeW)
            let seg = 1.0 / CGFloat(n)
            ZStack {
                ForEach(0..<n, id: \.self) { i in
                    let isSeen = i < arcs.count ? arcs[i] : false
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
// here. Both are gone. What replaced them is `StoryCanvas` in StoryUI — the reference app's two-colour
// gradient — and the reason the imitation existed at all is the reason the whole system had to go:
// a material cannot be composited at fractional opacity, cannot be scaled by a gesture, and cannot
// be snapshotted, so every surface that did one of those needed its own copy of the look. A gradient
// needs none, and the at-rest look and the mid-transition look are now the same object rather than
// two things calibrated against each other.

struct StoryImage: View {
    let url: String
    // fitCanvas = show the WHOLE image (aspect-fit) over the reference app's canvas — the same treatment the
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
                    //  • shorter images aspect-FIT over the reference app's canvas, the same gradient the
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

    /// THE ROW'S CONTROLLER, REACHED WITHOUT GOING THROUGH SWIFTUI TO GET THERE.
    ///
    /// ⚠️ THIS IS THE WHOLE OF HIS "the top preview thumbnails are not following in realtime", AND
    /// IT IS AN ARCHITECTURE GAP RATHER THAN A NUMBER.
    ///
    /// In the reference app the sideways pan handler writes its fraction and calls
    /// `self.state?.updated(transition: .immediate)`, which runs `updateScrolling` — the function
    /// that positions the row's cards — SYNCHRONOUSLY, inside the same gesture callback. There is
    /// one hop from finger to card.
    ///
    /// Ours had three: the pan wrote `value`, `@Published` invalidated `MyStoriesCarousel`, SwiftUI
    /// scheduled an update, and the cards only moved when `StoryRowPositionReporter.body` ran inside
    /// it. The panel under the finger is moved by the pan handler directly and is therefore instant;
    /// the row waited for a SwiftUI pass that also rebuilds `StoryRow` and re-runs `apply` on the
    /// way. The two halves of one gesture were on two clocks, and the row is the slow one.
    ///
    /// `StoryRowLink` already existed for exactly this — its own note says "so a per-frame value can
    /// be handed to UIKit without a SwiftUI update in between" — but its only caller was inside a
    /// SwiftUI body, which is the update it was written to avoid. Holding it here lets the drag take
    /// their one hop. Weak: the row owns it, and a sheet that has gone away has no row.
    weak var rowLink: StoryRowLink?

    /// One frame of the sheet's sideways drag. The row is moved FIRST and directly, then the value is
    /// published for the things that genuinely need a SwiftUI pass. The live story rides the first
    /// half for free: moving the row lays the live story out, because it is one of the row's items.
    func deliver(_ v: CGFloat, settle: StoryRowSettle = .commit) {
        guard v.isFinite else { return }
        rowLink?.setPageDrag(v, settle: settle)
        if value != v { value = v }
    }

    /// THE SHEET PAGED AND THE ROW MOVES ONCE — see `StoryRowController.commitPage`. The published
    /// value is written directly rather than through `deliver`, because the row has already been
    /// told; going through `deliver` would hand it a second, unanimated zero on top of the spring it
    /// just started.
    func commitPage(toStoryId id: String) {
        rowLink?.commitPage(toStoryId: id)
        if value != 0 { value = 0 }
    }

    /// A TAP ON A SIDE CARD, ON ITS WAY TO THE SHEET — one-shot, direction only (+1 next, -1
    /// previous). The reference app pages its viewers list to the tapped story's list on the same
    /// transition the row springs on; ours needs the sheet to know the change of `sheetStoryId` it
    /// is about to see came from a TAP rather than a scroll of the row, because a scroll swaps the
    /// list in place (theirs too) and must not slide. Written by the carousel's `onIndexChanged`
    /// in the same transaction as the id, consumed by the sheet's next `sync` — a class property
    /// rather than `@State`, so the hand-off costs no extra SwiftUI pass and cannot arrive late.
    var pendingSheetSlide: Int?
    func takePendingSheetSlide() -> Int? {
        defer { pendingSheetSlide = nil }
        return pendingSheetSlide
    }

    // ⚠️ `rowScroll` / `setRowScroll` / `forgetRowScroll` ARE DELETED — 2026-08-13.
    //
    // The row published its scroller position here so the HOST could rebuild the live story's frame
    // from it on every frame of a pull. That reader is gone: the row places the live story itself,
    // in its own loop, where the scroller position is a local (`StoryRowController.scroll`) and
    // cannot be stale, cannot be nil, and cannot default to a number that means "the first story".
    //
    // The bug this field's optionality was fixing is therefore not fixed here any more — it is
    // absent. Nothing outside the row asks where the row is.
}

/// EVERY FRAME OF THE ROW'S MOVEMENT, INCLUDING THE FRAMES SWIFTUI DRAWS BY ITSELF.
///
/// ⚠️ READ THIS BEFORE REPLACING IT WITH AN `.onChange`. I wrote it as one first and it is wrong in
/// a way that only shows up on two of the four ways the row can move.
///
/// `withAnimation { scroll = 3 }` does not walk `scroll` from 2 to 3. It sets it to 3 at once and
/// then INTERPOLATES THE RENDERED ATTRIBUTES — the position, the scale, the opacity — over the next
/// 0.3 seconds. So `.onChange(of: scroll)` fires exactly once, with the destination, on the first
/// frame. A finger on the row is fine (the scroller writes a fresh value per frame and there is no
/// animation involved), and so is a sheet page-drag; but the retarget spring and the page commit
/// are pure SwiftUI animations, and on those two the cards would glide across while the live story
/// teleported to the end. That is the position-and-scale disagreement he photographed, rebuilt from
/// the other direction by the very thing meant to remove it.
///
/// `Animatable` is the seam SwiftUI provides for exactly this: declare the row's position as the
/// animatable data and SwiftUI writes the INTERPOLATED value into this modifier once per frame,
/// which is the same number the cards are being drawn from on that frame. There is no second clock,
/// no duration copied from anywhere, and no curve to keep in step — it is not a parallel animation
/// of the story, it is a readout of the row's real one.
///
/// The report happens in `body`, which is a side effect during a view update. That is only safe
/// because of what it does: it writes a plain (non-`@Published`) property and moves a UIKit
/// transform, so nothing it touches can invalidate a SwiftUI view and re-enter the update it was
/// called from.
/// ⚠️ TWO NUMBERS, NOT THEIR SUM, AND THE PAIR IS LOAD-BEARING.
///
/// The row is moved by two independent things — the scroller and the sheet's sideways throw — and
/// BOTH can be animated by SwiftUI. An earlier version animated `scroll - pageDrag` as a single
/// value, which is correct only where the layout treats them as interchangeable. It does not: the
/// scroller's position is blended against the central item by the pull fraction while the drag is
/// added on afterwards, so the two have to arrive separately to be recombined correctly.
///
/// ⚠️ ONE VALUE NOW, NOT TWO, BECAUSE ONLY ONE OF THEM STILL LIVES IN SWIFTUI.
///
/// It used to carry the scroller's position as well. The row's position is owned by the row's own
/// scroll view now (see `StoryRowController`), and a scroll view is never animated by SwiftUI — so
/// the only value left that SwiftUI interpolates behind the row's back is the sheet's sideways
/// throw, which is written straight by a UIKit pan while a finger is down and animated to zero by
/// `withAnimation` on the commit and on the spring home.
struct StoryRowPositionReporter: ViewModifier, Animatable {
    var pageDrag: CGFloat
    let report: (CGFloat) -> Void

    var animatableData: CGFloat {
        get { pageDrag }
        set { pageDrag = newValue }
    }

    func body(content: Content) -> some View {
        report(pageDrag)
        return content
    }
}

/// THE ROW'S LAYOUT, IN ONE PLACE, because two things now have to agree about it to the pixel: the
/// carousel, which draws the cards, and the live story, which is one of them.
///
/// Every number here is the reference container's, and they were already in this file — they just
/// lived privately inside `MyStoriesCarousel`, where the live story could not reach them. That was
/// tolerable while the live story was pinned to the centre and never had to know where a card was;
/// it stopped being tolerable the moment it had to slide to the same places the cards slide to.
///
/// ⚠️ The alternative — a second copy of the same five formulas on the host side — is exactly what
/// `402ec4d` was: duplicated geometry that has to agree, drifting by a fraction, and the picture
/// jumping inside its own frame.
struct StoryRowGeometry: Equatable {
    let slotW: CGFloat          // the centred card at full pull — their `centralVisibleItemWidth`
    let slotH: CGFloat
    let centerY: CGFloat        // the card block's centre line on screen
    /// The FULL-SCREEN story width — their `contentFrame.width`. Every one of their formulas is
    /// written against this and not against the card, which is the reason two of ours were wrong.
    let fullW: CGFloat
    /// HOW FAR THE SHEET IS UP: 0 full screen, 1 fully shrunk. Their `contentScaleFraction`.
    ///
    /// ⚠️ IT BELONGS IN THE GEOMETRY, NOT AT THE CALL SITES. Half the numbers below change with it —
    /// the spacing, the scale, and the row's own resting position — and every one of those was
    /// computed at fraction 1 and then used at every fraction.
    let fraction: CGFloat

    /// The same slot at a different point in the pull.
    ///
    /// The row is handed its geometry through SwiftUI, which is a frame behind a finger on the
    /// sheet; the sheet's pan hands it the fraction directly through `StoryRowLink` so the story it
    /// is shrinking does not lag the finger shrinking it. Both write the same number — both compute
    /// `sheetSizeFraction` from the same `viewersProgress` — so the later writer is simply the
    /// fresher one and there is nothing for them to disagree about.
    func withFraction(_ f: CGFloat) -> StoryRowGeometry {
        StoryRowGeometry(slotW: slotW, slotH: slotH, centerY: centerY, fullW: fullW,
                         fraction: max(0, min(1, f)))
    }

    var itemSpacing: CGFloat { 12 }
    /// `contentMinScale`: the card's width as a fraction of the full-screen story.
    var contentMinScale: CGFloat { fullW > 0 ? slotW / fullW : 1 }
    /// A FIXED 54pt narrower than the centre card, not a ratio.
    var sideW: CGFloat { max(1, slotW - 54) }
    /// FLOORED, because `scroll` is computed by dividing by this and then fed to `Int()`. A zero or
    /// negative divisor gives infinity or NaN, and `Int(_:)` on either is a runtime trap rather than
    /// a wrong number — the shape of the crash in build 463.
    var fullDist: CGFloat { max(1, slotW * 0.5 + itemSpacing + sideW * 0.5) }
    var halfDist: CGFloat { max(1, sideW * 0.5 + itemSpacing + sideW * 0.5) }
    var sideRelScale: CGFloat { slotW > 0 ? sideW / slotW : 1 }

    // MARK: The SCALED distances — the half of their layout I did not have
    //
    // ⚠️ THEY COMPUTE TWO SETS OF DISTANCES AND USE EACH FOR A DIFFERENT JOB (`:1505-1512`). The
    // ones above are LOGICAL: fixed, measured on the fully-shrunk card, and used for the scroll
    // arithmetic and the visibility window. The ones below are SCALED by how far the sheet is up,
    // and they are the ones that POSITION anything.
    //
    // Mine used the logical set for positions at every fraction. At half a pull the items are still
    // nearly full-screen wide, so they must be ~250pt apart; the logical set puts them ~50pt apart,
    // which means they sit on top of each other. That is his "overlapping between the preview
    // cards", and it is also why the live card and the row cards appeared to move in two steps —
    // the row was drawing at final spacing while the live card was drawing at a fraction of it.
    var currentContentScale: CGFloat { contentMinScale * fraction + 1.0 * (1 - fraction) }
    var scaledCentralW: CGFloat { fullW * currentContentScale }
    /// ⚠️ The 54 is scaled by the fraction too — `scaledCentralVisibleItemWidth - 54.0 * f`.
    var scaledSideW: CGFloat { max(1, scaledCentralW - 54 * fraction) }
    var scaledFullDist: CGFloat { max(1, scaledCentralW * 0.5 + itemSpacing + scaledSideW * 0.5) }
    var scaledHalfDist: CGFloat { max(1, scaledSideW * 0.5 + itemSpacing + scaledSideW * 0.5) }

    /// WHERE THE ROW IS SITTING, IN CARD UNITS — and it is DERIVED, never pushed.
    ///
    /// ⚠️ THIS IS THE BUG HE PHOTOGRAPHED, AND THIS LINE IS THE WHOLE OF THE FIX.
    ///
    /// Their `:1512-1513`, in card units rather than points:
    ///
    ///     centralItemOffset       = fullItemScrollDistance * centralIndex
    ///     effectiveScrollingOffsetX = scroller.contentOffset.x * contentScaleFraction
    ///                               + centralItemOffset * (1 - contentScaleFraction)
    ///
    /// The part that matters is the SECOND term. With the sheet down, the row's position is not the
    /// scroller's and it is certainly not zero — it is **the central item's own index**, and it
    /// blends into the scroller's position as the sheet comes up. So there is never a moment when
    /// the layout has to be told where the row is; it can always work it out from the item the
    /// viewer is on.
    ///
    /// Mine read a number the row pushed into a shared box, which is 0 until the row has drawn at
    /// least once. Story 1 is index 0, so `0 - 0` is centred BY ACCIDENT; story 2 landed one whole
    /// slot to the right and story 3 two slots, which is exactly what he measured out for me.
    ///
    /// `pageDrag` is their `viewListPanState.fraction`, added on `:1519` — the sheet's own sideways
    /// throw moves the row.
    func rowPosition(scroll: CGFloat, centralIndex: Int, pageDrag: CGFloat) -> CGFloat {
        let base = scroll * fraction + CGFloat(centralIndex) * (1 - fraction)
        return base - pageDrag
    }

    /// How far item `index` is from the centre, in card units, given where the row is sitting.
    func combinedFraction(index: Int, rowPosition: CGFloat) -> CGFloat {
        CGFloat(index) - rowPosition
    }

    /// THE TWO-SLOPE RULE, on the SCALED distances. The first card's worth of distance moves by the
    /// FULL scroll distance and everything past it by the HALF distance, which is why the neighbours
    /// bunch up at the edges instead of marching off the screen evenly spaced.
    func offsetX(combinedFraction cf: CGFloat) -> CGFloat {
        let sign: CGFloat = cf < 0 ? -1 : 1
        let acf = abs(cf)
        return min(1, acf) * sign * scaledFullDist + max(0, acf - 1) * sign * scaledHalfDist
    }

    /// THE SAME TWO-SLOPE RULE ON THE LOGICAL DISTANCES — their `logicalItemPositionX`.
    ///
    /// ⚠️ IT IS NOT A DUPLICATE OF `offsetX`, AND THE DIFFERENCE IS THE POINT. They compute the item's
    /// position twice per pass from the same combined fraction: once on the SCALED distances, which is
    /// what actually moves a view, and once on the LOGICAL ones, which is what the visibility window
    /// is measured against. The logical set is fixed — it does not grow as the sheet rises — so an
    /// item's membership of the window cannot change just because the sheet is being pulled.
    func logicalOffsetX(combinedFraction cf: CGFloat) -> CGFloat {
        let sign: CGFloat = cf < 0 ? -1 : 1
        let acf = abs(cf)
        return min(1, acf) * sign * fullDist + max(0, acf - 1) * sign * halfDist
    }

    /// IS THIS ITEM WORTH HAVING A VIEW FOR — their `itemVisible` (`:1541-1546`):
    ///
    ///     let itemLeftEdge = logicalItemPositionX - itemLayout.fullItemScrollDistance * 0.5
    ///     let itemRightEdge = logicalItemPositionX + itemLayout.fullItemScrollDistance * 0.5
    ///     if itemRightEdge >= -itemLayout.containerSize.width
    ///        && itemLeftEdge < itemLayout.containerSize.width * 2.0 { itemVisible = true }
    ///
    /// A full container width of slack either side, which is generous on purpose: the window is there
    /// to stop an author with fifty stories building fifty cards, not to shave the neighbours. Ours
    /// had no window at all — every story in the row was built, positioned and drawn on every frame
    /// however far off the screen it was.
    func isVisible(combinedFraction cf: CGFloat, containerWidth w: CGFloat) -> Bool {
        let x = w / 2 + logicalOffsetX(combinedFraction: cf)
        return (x + fullDist * 0.5) >= -w && (x - fullDist * 0.5) < w * 2
    }

    /// THE CARD-RELATIVE SCALE: 1 at the centre, `sideRelScale` a full card out.
    ///
    /// This stays fraction-free on purpose, and the arithmetic is worth writing down because it
    /// looks like it should carry the fraction the way everything else here does.
    ///
    /// Theirs is `itemScale = f * minItemScale + (1 - f) * 1.0`, measured against the FULL-SCREEN
    /// width. Ours is measured against the CARD, and the morph's own `applyCore` already lerps
    /// rest → target by `f`. Substituting their `minItemScale` into that lerp, the `f` cancels
    /// exactly and leaves `slot * itemScale(cf)` — independent of the fraction. So the size half of
    /// this was already right, and forcing a second `f` into it would apply the same shrink twice.
    func itemScale(combinedFraction cf: CGFloat) -> CGFloat {
        let scaleFraction = min(1, abs(cf))
        return 1.0 * (1 - scaleFraction) + sideRelScale * scaleFraction
    }

    /// The dim the cover-flow puts on a card as it leaves the centre.
    /// THE COVER-FLOW DIM, THEIRS VERBATIM.
    ///
    ///     let countedFractionDistanceToCenter = max(0.0, min(1.0, unboundFractionDistanceToCenter / 3.0))
    ///     var itemAlpha = 1.0 * (1.0 - countedFractionDistanceToCenter) + 0.0 * countedFractionDistanceToCenter
    ///     itemTransition.setAlpha(layer: visibleItem.contentTintLayer, alpha: 1.0 - itemAlpha)
    ///
    /// where `unboundFractionDistanceToCenter` is `abs(combinedFraction)` — distance from the centre
    /// in CARD UNITS, not swipe progress and not screen position. That distinction is what makes the
    /// dim continuous: one number drives position, scale and brightness, and it already carries the
    /// pan, so a finger on the thumbnails and a finger on the sheet move all three together.
    ///
    /// ⚠️ WAS `1 - 0.20 * min(1, |cf|)`, AND BOTH HALVES OF THAT WERE WRONG.
    ///
    /// The DEPTH: 0.20 against their 0.333 is a 20% step between the centre card and its neighbour,
    /// which is not the hierarchy he described and is only 0.20 of brightness to spend across a whole
    /// card of travel. The change was happening; there was too little of it to read as happening.
    ///
    /// The CLAMP: `min(1, |cf|)` flattens everything past one card, so the second and third cards
    /// were exactly as bright as the first neighbour. Theirs clamps at THREE, so the row keeps
    /// falling away toward black and the centre is the only thing at full brightness.
    ///
    /// ⚠️ IT IS A TINT LAYER'S ALPHA NOW, NOT A VIEW'S OPACITY, AND THAT IS THE OTHER HALF OF THE
    /// 2026-08-13 RULING.
    ///
    /// It used to be `1 - this`, written onto `item.alpha` for a row card and onto `card.alpha`
    /// inside the morph for the live story: two owners, two call paths, two view hierarchies,
    /// trading hands at the half-card. Theirs is one black sibling layer per item, positioned by the
    /// same layout pass that positions the item
    /// (`itemsContainerView.layer.addSublayer(visibleItem.contentTintLayer)`), which is how their
    /// CENTRAL, playing item gets dimmed by the identical code path as a thumbnail — the tint never
    /// has to know what kind of view it covers. Ours is that now, so the live story is dimmed by the
    /// row like every other card and there is nothing to hand over.
    ///
    /// It also stops the dim from fading things that are not the picture: view alpha took the card's
    /// shadow and its count badge with it, and would have broken outright behind any non-black
    /// backdrop.
    ///
    /// The divisor is the one knob: 3 is theirs, and a larger number is a lighter dim.
    /// ⚠️ AND THE SECOND TERM IS THE PULL'S, WHICH WE DID NOT HAVE AT ALL.
    ///
    /// Theirs is not one expression, it is two, and only the first was ported:
    ///
    ///     let collapsedAlpha = itemAlpha * contentScaleFraction + 0.0 * (1.0 - contentScaleFraction)
    ///     itemAlpha = (1.0 - fractionDistanceToCenter) * itemAlpha + fractionDistanceToCenter * collapsedAlpha
    ///
    /// with `fractionDistanceToCenter = min(1.0, abs(combinedFraction))`. Multiplied out that is
    /// `itemAlpha * (1 - fdc * (1 - contentScaleFraction))`, and what it says is: **a story that is
    /// not the centre one is BLACK while the sheet is down, and brightens into the cover-flow dim as
    /// the sheet rises.** With the sheet fully up the factor is exactly 1, so the row at rest is
    /// unchanged — this only ever moves during the pull.
    ///
    /// Ours had the cover-flow dim alone, at every pull position. So while the sheet was down and a
    /// sideways page was in flight, the story arriving was drawn at two thirds brightness beside the
    /// one leaving instead of out of sight — two stories on the screen at once, which is what the
    /// owner photographed and called the transition being "not synchronized". The neighbour is not
    /// meant to be dim there. It is meant to be invisible.
    ///
    /// Their third term, `itemAlpha *= (1.0 - contentOverflowFraction)`, is deliberately NOT ported:
    /// it fades the row when their sheet is dragged BEYOND its detent, and our pull is clamped so
    /// there is no overflow state to fade. Porting a term whose input is always zero would just be a
    /// line waiting to be wrong.
    func dim(combinedFraction cf: CGFloat) -> CGFloat {
        let counted = min(1, abs(cf) / 3)
        let distance = min(1, abs(cf))
        let alpha = (1 - counted) * (1 - distance * (1 - fraction))
        return 1 - alpha
    }

    /// WHERE ONE STORY SITS THIS FRAME — the whole of the row's layout, for EVERY story in it.
    ///
    /// ⚠️ THIS REPLACES `placeLiveStory`, AND THE DELETION IS THE RULING OF 2026-08-13.
    ///
    /// There used to be two ways out of this type: the cards read `offsetX`, `itemScale` and the
    /// dim separately inside the row's loop, and the live story went through a
    /// `placeLiveStory` that reassembled the same three numbers, added a division to cancel a lerp
    /// on the far side, and posted them to the morph. Same inputs, two assemblies, one of which had
    /// to know what the OTHER side would do with its answer. Every story bug of that week lived on
    /// that seam.
    ///
    /// One function, one answer, one caller. What differs between a side card and the live story is
    /// no longer the arithmetic — it is only which surface the answer is written onto, and the row
    /// decides that in one place.
    ///
    /// - Parameters:
    ///   - cf: how far this story is from the centre, in card units (`combinedFraction`).
    ///   - rest: what this item is at fraction 0 — the story CONTENT's rectangle, full screen. Every
    ///     item interpolates from it, so the live story's journey and its neighbours' are the same
    ///     journey. (The neighbours only become visible at fraction 1, where the interpolation has
    ///     landed and their size is exactly `slot × itemScale` — the number they have always had.)
    ///   - containerMidX: the row's centre line, in WINDOW coordinates — the same space `rest` and
    ///     `centerY` are in. Everything here is computed in one space, because the cards being
    ///     measured against the row's origin while the live story was measured against the screen's
    ///     is how two numbers that had to agree were not even taken from the same place.
    func placement(combinedFraction cf: CGFloat, rest: CGRect, containerMidX: CGFloat) -> StoryRowPlacement {
        let scale = itemScale(combinedFraction: cf)
        // ⚠️ THE SLOT IS SCALED, NOT THE FRACTION. The way to land on a side card's size is to
        // interpolate toward the side card's size. Scaling the fraction instead would walk the card
        // toward the slot along the PULL's path, which is a different journey with a different crop.
        // (See `itemScale`: their fraction blend and this lerp are the same lerp, so it cancels and
        // the resting size is fraction-free.)
        let targetW = slotW * scale, targetH = slotH * scale
        let w = rest.width + (targetW - rest.width) * fraction
        let h = rest.height + (targetH - rest.height) * fraction
        // ⚠️ THE X IS ABSOLUTE AND IS NOT INTERPOLATED BY ANYBODY. `offsetX` is computed from the
        // SCALED distances, which already carry the fraction — `scaledFullDist` grows as the sheet
        // rises — so the fraction is in this number once, which is once more than it used to be and
        // once less than the pre-division existed to correct.
        let x = containerMidX + offsetX(combinedFraction: cf)
        // The Y is the one part of the journey the PULL owns rather than the row: a story rises from
        // where it rests to the card block's centre line, and no scroll ever changes that.
        let y = rest.midY + (centerY - rest.midY) * fraction
        return StoryRowPlacement(center: CGPoint(x: x, y: y),
                                 size: CGSize(width: max(1, w), height: max(1, h)),
                                 // His ruling, twice: 24, scaling with the card.
                                 cornerRadius: 24 * scale,
                                 dim: dim(combinedFraction: cf))
    }
}

/// WHERE ONE STORY SITS THIS FRAME. The output of the row's one loop, and the only thing that
/// stands between `StoryRowGeometry` and a pixel.
///
/// It is a value rather than four writes because two different surfaces consume it — a card view the
/// row owns, and the live story the library owns — and the whole point of the 2026-08-13 rewrite is
/// that those two are handed the SAME numbers rather than each computing their own.
struct StoryRowPlacement: Equatable {
    /// In WINDOW coordinates. The live story wants them as they are; a card view converts into the
    /// row on the way out.
    let center: CGPoint
    /// What the card RENDERS as, not what its bounds are.
    let size: CGSize
    /// On screen, at this size — already multiplied by the item's scale.
    let cornerRadius: CGFloat
    /// How black the tint over this card is, 0…1. Their `contentTintLayer`'s alpha.
    ///
    /// ⚠️ THE ONLY BRIGHTNESS OWNER IN THE ROW, AND THAT IS THE POINT OF IT BEING HERE. It is one
    /// number, computed once per story per frame from the same `combinedFraction` that decides where
    /// that story sits, so a card's brightness cannot be a frame out of step with its position.
    let dim: CGFloat

    // ⚠️ `zPosition` IS DELETED FROM THIS TYPE — 2026-08-13. It carried the old `zIndex(2 - |cf|)`,
    // written onto layers every frame, and `zPosition` is implicitly animated: what the compositor
    // sorted by was therefore a lagging value, which is survivable while it only decides which of
    // two non-overlapping cards is in front and fatal once layer order is what makes the tint
    // visible. The reference app does not set `zPosition` anywhere; order is insertion order.
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
    static func isOneTimeUsed(_ storyId: String) -> Bool { stampedIds("oneTimeUsed").contains(storyId) }
    /// ⚠️ `mutateStamped`, NOT `save`. This store was written with the plain append-and-save pair,
    /// which is the shape the seen and liked stores were explicitly moved OFF because they "grew
    /// forever". Every one-time story id ever opened would have sat in UserDefaults for the life of
    /// the install, and UserDefaults is read into memory at launch, so it becomes a launch cost that
    /// only ever grows. Pruned by AGE with the other two now — see `mutateStamped`.
    static func markOneTimeUsed(_ storyId: String) {
        guard !storyId.isEmpty, !isOneTimeUsed(storyId) else { return }
        mutateStamped("oneTimeUsed") { $0[storyId] = Date().timeIntervalSince1970 }
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
    /// ⛔ SEEN, LIKED AND BURNED ARE PRUNED BY AGE NOW, NOT BY COUNT — and the count was quietly
    /// forgetting stories that were still on screen.
    ///
    /// They used to be ordered arrays with the oldest 500 dropped once past 1000 ids. Two things were
    /// wrong with that. A heavy user passes a thousand story ids in a fortnight, so the cap is
    /// reached in ordinary use; and what came off the front was not "old enough to forget", it was
    /// "written longest ago", which on a busy account still includes stories that are live. A ring
    /// he had watched turned unseen again by itself, and a heart he had set came back empty.
    ///
    /// A story is dead in 24 hours, so nothing in these three stores is worth keeping past that. Each
    /// id now carries the moment it was written and anything past two days goes on the next touch.
    /// The store then has a natural ceiling — two days of stories — and no cap has to guess at it.
    ///
    /// ⚠️ THE OLD FORMAT IS MIGRATED, NOT DROPPED. The ids already on disk have no stamps; they are
    /// given the moment of the migration rather than thrown away, because forgetting a story
    /// somebody has just watched is the exact fault being fixed. The legacy string is removed once
    /// its contents have been carried across.
    private static let stampedLifetime: TimeInterval = 48 * 3600
    /// Where the stamped form lives, beside the legacy key rather than on top of it — an old build
    /// reading this device would find its own key untouched rather than a dictionary it cannot parse.
    static func stampedKey(_ key: String) -> String { key + ".at" }
    /// ⚠️ CALLED WITH THE LOCK ALREADY HELD. It takes none of its own.
    private static func stampedLocked(_ key: String) -> [String: Double] {
        if let d = UserDefaults.standard.dictionary(forKey: stampedKey(key)) as? [String: Double] { return d }
        let legacy = (UserDefaults.standard.string(forKey: key) ?? "")
            .split(separator: " ").map(String.init)
        guard !legacy.isEmpty else { return [:] }
        let now = Date().timeIntervalSince1970
        return Dictionary(legacy.map { ($0, now) }, uniquingKeysWith: { a, _ in a })
    }
    private static func stampedIds(_ key: String) -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        if let c = cache[key] { return c }
        let s = Set(stampedLocked(key).keys)
        cache[key] = s
        return s
    }
    private static func mutateStamped(_ key: String, _ change: (inout [String: Double]) -> Void) {
        lock.lock()
        var d = stampedLocked(key)
        change(&d)
        let cutoff = Date().timeIntervalSince1970 - stampedLifetime
        d = d.filter { $0.value > cutoff }
        cache[key] = Set(d.keys)   // update cache synchronously → instant reads
        lock.unlock()
        UserDefaults.standard.set(d, forKey: stampedKey(key))
        UserDefaults.standard.removeObject(forKey: key)   // the legacy string is spent
    }
    // Per-STORY-ITEM seen state (drives the segmented ring: each arc greys as you view that story).
    static func isStorySeen(_ id: String) -> Bool { stampedIds("seenStoryItems").contains(id) }
    static func markStorySeen(_ id: String) {
        guard !id.isEmpty, !isStorySeen(id) else { return }
        mutateStamped("seenStoryItems") { $0[id] = Date().timeIntervalSince1970 }
    }
    // My own ❤️ on a story — persists so the heart is still red on reopen.
    static func isStoryLiked(_ id: String) -> Bool { stampedIds("likedStories").contains(id) }
    static func setStoryLiked(_ id: String, _ liked: Bool) {
        guard !id.isEmpty else { return }
        mutateStamped("likedStories") { d in
            if liked { d[id] = Date().timeIntervalSince1970 } else { d[id] = nil }
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
    /// The audience pill for a story edited from the sheet over this viewer, until this sitting ends.
    /// See `audienceBadge` for why the snapshot cannot answer this and the reconcile does not fire.
    @State private var audienceOverride: [String: StoryAudienceBadge] = [:]
    /// The footer's numbers for the story on screen. Nil until this story's own answer lands — see
    /// `loadBarViewers`, which is careful never to paint one story's numbers under another.
    @State private var barViewers: StoryViewSummary?
    /// One number that moves every time a view counter answers, so anything drawing those counts can
    /// key a refresh on it. See `MyStoriesCarousel.countsTick`.
    @State private var countsTick = 0
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
        /// The sheet keeps 340 and its tight finish: it was tuned against the reference app's and he signed it
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
        /// restarting from rest. (The reference app animates with a fixed 0.4s ease-out and hides the
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

        /// IS A SPRING ACTUALLY RUNNING RIGHT NOW.
        ///
        /// ⚠️ IT EXISTS BECAUSE `cancel()` THROWS THE COMPLETION AWAY, and the completion is where
        /// every run puts its cleanup. A cancelled flight therefore never lowers the flags it
        /// raised — `hero.live` and `StoryCardMorph.heroDismissActive` are both cleared inside the
        /// hero's completion and nowhere else on that path — so they outlive the flight and go on
        /// claiming the card forever. Anything that gates on those flags has to be able to ask
        /// whether the thing they describe is still happening.
        var isRunning: Bool { link != nil }
        @objc private func tick(_ l: CADisplayLink) {
            let dt = CGFloat(min(l.targetTimestamp - l.timestamp, 1.0 / 30.0))
            // Critically damped, so it arrives without overshooting. `k` is per animator now — see
            // the property. 340 is interactiveSpring(response: ~0.34); 631 is another mainstream
            // messenger's own story transition spring, `response: 0.25, damping: 1`, which expands to stiffness (2π/0.25)².
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
    /// The story whose viewers are being changed — "…" → Edit viewers. It is the story itself
    /// rather than a flag because the sheet edits THAT story: same id, same posting time, same
    /// media. See `ShareStorySheet.editing`.
    @State private var editViewers: Story?
    @State private var profileSheet: StoryGroup?        // tap the header → profile sheet OVER the story (paused)
    @State private var toastText = "Sent"               // reused for "Sent" (reply) and "Saved"
    @State private var dragDown: CGFloat = 0            // swipe-down amount → fade my overlays with the card
    // ⚠️ `carouselInteracting` IS DELETED. It said "a swipe is in flight, so stand the real story
    // aside and let the row draw a copy of it" — one of the three inputs to a handover that no
    // longer happens. The real story slides with the row now; a swipe being in flight is not a
    // thing anything needs to be told about.
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
    /// The reference app does not have this seam to fall down: its own container repositions
    /// its cards and its view list in ONE layout pass driven straight from `scrollViewDidScroll`,
    /// all in UIKit. Ours crosses into SwiftUI, so the fix is to make the crossing narrow: the box
    /// is an `ObservableObject` that ONLY `MyStoriesCarousel` observes, and this view holds it with
    /// `@State`, which stores a reference WITHOUT subscribing to it. Per-frame writes now invalidate
    /// the row and nothing else.
    ///
    /// ⚠️ AND THE HOST NO LONGER NEEDS TO KNOW ABOUT PAGING AT ALL. `sheetPaging`, the boolean half
    /// of this, is deleted: it existed so the host could re-render twice a drag and decide which of
    /// two pictures of the active story to show. There is one picture now. The box carries the
    /// drag's own value for the row, and the row's position for the live story, and neither of those
    /// is a reason to re-render anything.
    @State private var pageDragBox = StorySheetPageDrag()
    /// The freeze re-assert's clock, made ONCE. See the note at its `onReceive`.
    @State private var pausePulse = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()
    /// Which story the owner footer's viewers belong to, so a story change empties it instead of
    /// leaving the previous one's count and faces up during the fetch. See `loadBarViewers`.
    @State private var lastBarViewersStoryId: String = ""
    /// What the last fetch said about each of MY stories, for the length of this viewer session.
    ///
    /// The footer used to blank on every item change and wait out a Firestore round trip, so tapping
    /// back and forth repainted "0 Views" each way — half of his "the count comes late". Keyed by
    /// story id, which is the whole safety argument: an entry can only ever be shown for the story it
    /// was fetched for. Dies with the viewer, so a count is never older than this sitting.
    @State private var viewersByStory: [String: StoryViewSummary] = [:]
    /// Whether `prefetchMyStoryCounts` has already swept this viewing.
    @State private var prefetchedCounts = false

    // ⚠️ `carouselOwnsSlot` IS DELETED. It meant "the row's own card owns the slot and the real
    // story must stand aside", which was the copy-swap's on switch. Its three inputs are down to
    // one, and that one — `rowIsOnAnotherStory` — survives for a completely different job: telling
    // the close which story to land on. Read it as the deferred jump, not as a handover.

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
    ///   "first unseen, else first" whenever `currentStoryId` is empty — and `currentStoryId` was
    ///   written by `onItemSeen`, which the library WITHHOLDS while a story is paused, held or
    ///   buffering. So that comparison could answer "not a jump" about the wrong story. (It is
    ///   written by the ungated `onItemChanged` now — see `isUploadingItem` — so the empty window is
    ///   one 20fps tick rather than the whole time a story sits paused.)
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
    /// the shape the reference app uses: one authoritative current-item id, everything else derived from it.
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
    // Each card asks for a picture of its OWN clip at draw time instead — see `cardMedia`. There is
    // no capture site, so there is no moment to get wrong; there is no host state, so it cannot be
    // stale, cannot be cleared at the wrong time and cannot be filed under the wrong story. The
    // answer is generated from the clip's own file at the second its own player is paused on
    // (`StoryVideoFrames`), and that player is still alive because an item owns its player now.
    /// The morph has no card to move. Only ever true when something upstream has gone wrong; it makes
    /// the story fade rather than sit there at full size under the sheet. See `driveMorph`.
    @State private var morphUnavailable = false

    /// THE STORY'S CONTENT RECTANGLE, CAPTURED ONCE PER PULL AND HELD FOR IT.
    ///
    /// ⚠️ IT IS LATCHED BECAUSE A SLOT MUST NOT MOVE WHILE SOMETHING IS SHRINKING INTO IT.
    ///
    /// `cardSlot` sizes the card against this. Read live from the morph it is not a constant: the
    /// library reports its metrics part way through the pull, so the first frames were measured
    /// against a full-screen height and the rest against the real content height. The card therefore
    /// changed size in mid-flight, which is his "sometimes too tall, sometimes too short" — and it
    /// was my own regression from the black-band fix, which replaced a stable wrong number with an
    /// accurate moving one. It needs to be accurate AND stable, which is what a latch buys.
    ///
    /// Nil means "not known yet"; `cardSlot` then uses its screen-derived estimate, which is stable
    /// for the same reason. Cleared when the sheet goes, so the next sitting measures afresh rather
    /// than inheriting a rectangle from a story with a different footer.
    @State private var latchedContent: CGSize?

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
        /// long pull — his note, and the reason ours read lighter than the reference app's. But a
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
    /// spring the sheet uses, on ANOTHER MAINSTREAM MESSENGER'S numbers rather than the sheet's: `response 0.25, damping 1`
    /// is stiffness (2π/0.25)² = 631, and it stops at a distance nobody can see. Together those take
    /// the flight from the 0.51s he measured to about 0.3s, which is what another mainstream messenger's own story
    /// transition costs (0.2s grow + 0.1s cross fade).
    @State private var heroAnimator = SheetProgressAnimator(stiffness: 631, settleEpsilon: 0.004)
    /// How far the finger has to travel for the card to be fully seated in the row card. Generous on
    /// purpose: the shrink has to read as gradual under a slow drag, and the close commits long
    /// before this is reached.
    private static let heroDragSpan: CGFloat = 420
    /// THE SMALLEST THE STORY IS ALLOWED TO GET WHILE THE FINGER IS STILL DOWN, as a fraction of its
    /// own full-screen width.
    ///
    /// 0.34 first, off his screenshot. RAISED TO 0.46 on 2026-08-08 against a pair of his
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
    /// The darkest the chat list gets under a story in flight. Judged against his reference shots,
    /// where the list behind is dimmed well past half but never to black — you can still read it.
    /// THE DARKEST THE LIST GETS ONCE A PULL IS PROPERLY UNDER WAY.
    ///
    /// Set from his 2026-08-07 comparison, with the reference app's own source read for the other end of the
    /// range. The reference app paints a solid black layer at
    /// `max(0.5, 1.0*(1 - dismissFraction) + 0.2*dismissFraction)` — 1.0 at rest, and floored so it
    /// never gets lighter than half while your finger is down. Ours peaked at 0.45 and then decayed
    /// all the way to zero, so our CEILING was below their FLOOR and the gap widened the further he
    /// pulled: at half way we were 0.27 against their 0.60.
    ///
    /// His call: the reference app too dark, ours too light, aim between them and nearer the other app.
    /// So 0.58 here and a 0.36 floor — the list stays clearly readable, which is the look this file
    /// has been judged against from the start, and it never washes out.
    ///
    ///        drag     ours (was)   now    reference
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
    // ⚠️ `mineOnly` IS DELETED, AND IT IS NOT COMING BACK. It was
    // `groups.count == 1 && (groups.first?.isMine ?? false)` — "my story is alone in this viewer" —
    // and every reader of it actually wanted one of two other things: "this sitting is about me"
    // (now `showingMine`) or "the page in front of me is mine" (now `currentIsMine`). Routing my
    // bucket into the paged set makes it permanently FALSE for my own story, so anything still
    // asking it would silently take the friend's-story branch on my own story. Leaving it defined
    // is the trap; the substitution is recorded at each site.

    /// ⚠️ "THE STORY ON SCREEN RIGHT NOW IS MINE", SAFE ON THE FIRST FRAME.
    ///
    /// `mineOnly` used to answer two different questions and only one of them survives my bucket
    /// becoming one page among several (`MainShell.openStoryFromRow`). The two are:
    ///
    /// · "is this viewing session about me" — which is what the sheet-opening guards wanted, and
    ///   which `mineOnly` answered correctly only because my story was always alone in its viewer.
    /// · "is the page in front of me mine" — which is what the layout wanted, and which is
    ///   `currentIsMine`.
    ///
    /// `currentIsMine` is NOT a safe substitute for the first on its own, and this is documented at
    /// `onSwipeUpChanged` in as many words: it reads `currentBucketUid`, which the library writes on
    /// `onUserChanged`, a beat AFTER the viewer is on screen. A swipe up inside that window would
    /// find it false and open the REPLY KEYBOARD instead of the viewers sheet. That guard has already
    /// shipped silently dead once (`:1406`), so the trap is real and not theoretical.
    ///
    /// So the empty window falls back to the bucket the viewer was actually OPENED on, which the door
    /// records. ⚠️ Not `groups.first` — `StoryDoor.viewer` passes a `startIndex`, so the opened bucket
    /// is not necessarily the first one in the list.
    private var showingMine: Bool {
        currentIsMine || (currentBucketUid.isEmpty && (StoryDoorState.shared.openGroup?.isMine ?? false))
    }
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
    /// ⚠️ AND THE OTHER HALF IS CLOSED NOW TOO — `currentStoryId` NO LONGER COMES FROM A RECEIPT.
    ///
    /// It used to be written by `onItemSeen`, which is a WATCHED receipt: StoryDetailView withholds
    /// it while a story is paused, held, folding, buffering or behind the keyboard (deliberately —
    /// for a view-once story delivering it SPENDS the view). The viewers sheet pauses the story for
    /// its entire life, so under the sheet the id could stop moving altogether and the bar rode onto
    /// whatever was last WATCHED. That is why he reported this a second time on 2026-08-10 with a
    /// screenshot of an EIGHTEEN HOUR OLD view-once story wearing the bar.
    ///
    /// The library now publishes `onItemChanged` beside the receipt — the item changing, no gate,
    /// within one 20fps tick — and that is what writes this id. Both halves of the answer are
    /// current: which item is on screen, and whether that exact placeholder is still in flight.
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
    private var sheetUp: Bool { shareImg != nil || forwardImg != nil || confirmDelete || profileSheet != nil || editViewers != nil }

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
                // The tick travels as a plain answer — see `StoryUIUser.isVerified`. Asked from the
                // same index every other screen asks (`VerificationIndex`, warmed by every profile
                // the app reads), so the story header cannot disagree with the chat list about who
                // is verified.
                user: StoryUIUser(id: g.authorUid, name: g.name, image: g.photoUrl ?? "",
                                  isVerified: VerificationIndex.isVerified(g.authorUid)),
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
                        // What the uploader worked out is worth fetching before this clip is
                        // watched. Zero for anything posted before the field existed, which the
                        // lookahead reads as "use your own default". See `Story.preloadPrefix`.
                        preloadPrefix: s.preloadPrefix,
                        // The Link and Location stickers on this story. The library is handed only
                        // where they are and what they open — the drawing of them is already in the
                        // media it is about to show. See `StoryTapTarget` and `StoryTapArea`.
                        taps: s.stickers.compactMap { t in
                            guard let u = URL(string: t.url) else { return nil }
                            return StoryUI.StoryTapArea(x: t.x, y: t.y, w: t.w, h: t.h,
                                                        rotation: t.rotation, url: u)
                        },
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
                        // ⛔ THE AUTHOR'S "do not copy this" SWITCH, carried per item rather than per
                        // person: a tray holds several stories and only some of them may be
                        // protected. See `CaptureShield` for what the viewer can actually enforce.
                        isCaptureProtected: s.captureProtected,
                        // WHO CAN SEE IT MAY BE CHANGED AFTER POSTING, on my own story only — and
                        // not on a one-time story, whose audience is spent as it is watched, nor on
                        // one still uploading, which has no document to write to yet. See
                        // `Story.canEditAudience` and `StoriesService.updateStoryAudience`.
                        canEditAudience: g.isMine && !s.oneTime && !StoriesService.isPending(s.id),
                        // WAS IT POSTED TO EVERYONE. Only the Share entry reads it, and only on my
                        // own story — see `Story.isPublicStory`. A one-time story is never public
                        // whatever its label says, so it is excluded here rather than in the menu.
                        isPublicStory: s.audienceLabel == "everyone" && !s.oneTime,
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
        // EDIT VIEWERS. The audience sheet exactly as it is drawn for a post — his condition — with
        // Update in place of Post Story and no way to make a new audience from here. It dismisses
        // itself once the write lands; this only says so.
        .sheet(item: $editViewers) { s in
            ShareStorySheet(editing: s, onPosted: { flashSentToast("Viewers updated") })
        }
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
            // ⚠️ WAS IT THE LAST ONE — ASKED BEFORE, NOT AFTER. This used to force a reload and then
            // read `mine`, which is a race against the server: if the delete had not propagated when
            // the reload answered, the story came back, the test said "more remain", and the viewer
            // sat open on a story that no longer exists. The bucket in hand already knows, and the
            // count cannot change under a modal viewer.
            let wasLast = (StoriesRepository.shared.mine?.stories.count ?? 0) <= 1
            Task {
                let gone = await StoriesService.shared.deleteStory(id)
                guard gone else {
                    // ⚠️ THE STORY IS STILL THERE, SO SAY SO AND PUT IT BACK. The viewer has already
                    // slid it out of the bucket (that is what makes the delete look seamless), and
                    // the repository still holds it — a reload restores the item, and the toast is
                    // the only thing that tells him the delete did not happen. Silently leaving it
                    // deleted-looking is how an offline delete came back by itself hours later.
                    await StoriesRepository.shared.load(force: true)
                    await MainActor.run { flashSentToast("Couldn't delete — check your connection") }
                    return
                }
                await StoriesRepository.shared.load(force: true)
                if wasLast { onClose() }
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
        // "…" → Edit viewers: the SAME audience sheet the posting flow uses, in edit mode. It
        // writes to the story that is already up — no upload, no second story, no new id. The same
        // three guards the library's own flag carries, re-asserted on LIVE state here because the
        // menu is the part a modified client replaces.
        .onReceive(NotificationCenter.default.publisher(for: .init("storyActionEditViewers"))) { _ in
            guard currentIsMine, let s = currentStory,
                  !s.oneTime, !StoriesService.isPending(s.id) else { return }
            editViewers = s
        }
        // "…" → Edit viewers → Update. The pill changes on the tap rather than on the round trip;
        // see `audienceBadge`. The glyph is picked by the same rule that file uses for a fetched
        // story, so an edited label and a loaded one cannot draw two different icons.
        .onReceive(NotificationCenter.default.publisher(for: .init("storyAudienceUpdatedLocally"))) { note in
            guard let info = note.userInfo,
                  let id = info["id"] as? String,
                  let label = info["label"] as? String,
                  let title = info["title"] as? String else { return }
            switch label {
            case "everyone":
                audienceOverride[id] = StoryAudienceBadge(systemImage: "globe", text: title)
            case "custom":
                audienceOverride[id] = StoryAudienceBadge(systemImage: "person.crop.rectangle.stack",
                                                          assetImage: "ic_story_folder", text: title)
            default:
                audienceOverride[id] = StoryAudienceBadge(systemImage: "person.2.fill", text: title)
            }
        }
        // ⚠️ AND THE OVERRIDE COMES OFF WHEN THE WRITE DID NOT LAND. Leaving it would show him an
        // audience the story is not actually on, which is worse than the delay it replaces — the
        // reload the sheet already ran has put the true label back underneath by now.
        .onReceive(NotificationCenter.default.publisher(for: .init("storyAudienceUpdateFailed"))) { note in
            guard let info = note.userInfo, let id = info["id"] as? String else { return }
            audienceOverride.removeValue(forKey: id)
            flashSentToast((info["message"] as? String) ?? "Couldn't update who can see this")
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
            // This used to be load-bearing for a different reason: any input to `carouselOwnsSlot`
            // left standing after the sheet went put the live card at alpha 0 with nothing drawn
            // over it — his "screen story is going black". Nothing hides the card any more, so a
            // stale value can no longer black the screen out; it is still cleared here because the
            // row's position has to start from a known place on the next open.
            pageDragBox.value = 0
            // The measured rectangle belongs to the sitting that just ended. A story with an owner
            // footer and one without do not share a content height, so carrying it into the next
            // open would size the card against the wrong story.
            latchedContent = nil
            // The scroller position used to be forgotten here as well. It is not published outside
            // the row any more (see `StorySheetPageDrag`), and the row's own scroller re-seats itself
            // on the central item the moment the next sitting opens — `pinToCentralWhileCollapsed`.
            // Same rule as driveMorph: a hero flight owns the card and this teardown must not
            // reset it out from under one.
            guard !hero.live else { return }
            // Full-screen, square, unmasked, visible. The sheet can be torn down from several paths
            // (close, dismiss, teardown) and a card left mid-transform would open the NEXT story
            // already shrunken.
            StoryCardMorph.shared.reset()
        }
        // ⚠️ NAVIGATE THE MOMENT THE CENTRED CARD CHANGES. THE JUMP IS NOT DEFERRED ANY MORE.
        //
        // Read from their `scrollViewDidScroll` (`:1372-1387`), which is the rule this viewer never
        // had:
        //
        //     if contentScaleFraction >= 1.0 - 0.0001 {
        //         var index = Int(round(contentOffset.x / fullItemScrollDistance))
        //         if index != currentIndex { component.navigate(.id(nextId)) }
        //     }
        //
        // They move the story WHILE the row scrolls, as soon as the rounded index changes. The
        // consequence is the invariant this area has been missing: the centred card and the story
        // the viewer is on are never different things, so nothing ever has to be positioned as
        // though they were. Their `:5236-5240` closes the other side of it — with the sheet down the
        // scroller is FORCED onto the central item rather than left wherever it was.
        //
        // Ours deferred the jump to the sheet's close (`rowIsOnAnotherStory`, spent in
        // `settleViewers`). That was survivable while the live card was pinned to the centre and
        // hidden behind a copy during a swipe; it stopped being survivable when the live card
        // started being laid out by the row, because a deliberate disagreement between the row and
        // the central item becomes a card sitting one or two whole slots off centre. That is his
        // report, and this is its cause rather than its symptom.
        //
        // ⚠️ THIS CANNOT MAKE THE LIVE LAYER TELEPORT, and the arithmetic is worth stating. At full
        // pull `rowPosition` is `scroll - pageDrag` and the central index drops out of it entirely
        // (their `effectiveScrollingOffsetX` reduces to the scroller's own offset at fraction 1). So
        // when the live story flips from index 1 to index 2 half way through a swipe, story 1 keeps
        // the place it already had — drawn by the row now instead of by the live layer — and story 2
        // appears where it already was, drawn by the live layer instead of by the row. Identical
        // geometry on both sides of the swap, which is the whole one-picture-per-story property.
        //
        // The row only reports a change on a ROUNDED index (`onChange(of: index)`), so this fires
        // once per card crossed rather than once per frame, exactly as theirs does. And the story is
        // paused for the whole life of the sheet, so moving through items here spends no views —
        // see the note on `onItemChanged` versus the seen receipt.
        .onChange(of: sheetStoryId) { _, id in
            guard showViewers, !id.isEmpty, id != currentStoryId else { return }
            // ⚠️ NOT WHILE THE ROW IS MOVING — the crossing is a report, not a destination. The
            // viewers list and the count row follow this id mid-drag exactly as before; what waits
            // is the PAGER, because swapping the full-screen story on every crossing of a fling is
            // work the live layer draws in the wrong slot while it loads (his double-brightness at
            // the half-card and the wrong-cover flash are that window, photographed). The reference
            // app can navigate mid-scroll because its navigation redraws nothing in the row. The
            // row's `onIndexSettled` posts this jump once, at rest — see `MyStoriesCarousel`.
            guard pageDragBox.rowLink?.isRowMoving != true else { return }
            NotificationCenter.default.post(name: .init("jumpToStoryItem"), object: id)
            // ⚠️ THE ANCHOR IS NOT WRITTEN HERE ANY MORE, AND THAT DELETION IS THE TAP FIX.
            //
            // It was written here because `currentStoryId` used to be fed by the WATCHED receipt,
            // which the library withholds while a story is paused — and the sheet pauses the story
            // for its whole life, so waiting for it would have waited for ever. That is no longer
            // true: the ungated `onItemChanged` owns this value now, and the jump handler reports
            // from the statement that swaps the item, so the answer arrives on the same runloop turn
            // as the picture.
            //
            // Writing it here made it a SECOND writer, and an early one: it claimed the story was B
            // before the library had drawn B. The row keys its whole animated pass off that claim, so
            // it teleported the scroller and sprang the cards toward B while the live layer was still
            // showing A — the old story sitting in the middle for a few frames, the brightness
            // stepping at the wrong moment, and the card arriving before the story. One writer, and
            // it tells the truth.
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
        // ⚠️ THE HANDOVER IS GONE. There is no `.onChange(of: carouselOwnsSlot)` any more and no
        // `setHidden` on this path at all.
        //
        // The swap was never a bad idea given its premise: the live card sat at the slot centre and
        // could not slide, so for the length of a swipe the row drew its own card and the real one
        // waited underneath at alpha 0. Every bug in this area came out of that premise rather than
        // out of the swap — two renderers for one story, and a question ("is the centred card the
        // story the player is holding?") that had to be answered at exactly the right instant, three
        // times over, by three signals that each had a path around them. It was wrong on device
        // twice after being fixed twice.
        //
        // The premise is what changed. The live card is laid out by the row's own geometry now, so
        // it slides where its card would slide and there is never a moment when something else has
        // to stand in for it. No hide, no copy, no instant to get right.
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
            // ⚠️ AND `storyChromeHidden: false` IS ALSO WHAT DROPS THE RETAINED ITEM VIEWS. The
            // library reads that flag as "the sheet is collapsed over the story" and keeps a small
            // window of item views alive while it is true, each holding a live paused `AVPlayer`
            // (see `StoryItemViewStore`). Posting it here is what makes a viewer torn down WITH the
            // sheet still up let go of them; the door and the presenter also call
            // `StoryVideoHost.viewerClosed()` outright, so this is one of three ways home.
            //
            // (The per-session cover dictionary that used to be emptied here went with the frame
            // bank itself — there is no bank any more, only frames generated on demand from the
            // clip's own file, and `StoryVideoHost.viewerClosed()` clears those with the viewer.)
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
        // ⚠️ THE PUBLISHER IS `@State`, NOT BUILT INLINE. `Timer.publish(...).autoconnect()` written
        // in the body makes a NEW timer object on every evaluation of this view, and this body is
        // evaluated on every frame of a pull; `onReceive` then tears down its subscription and
        // subscribes to the new one each time. Held in state it is made once and outlives the
        // evaluations. Same tick, same guard, none of the churn.
        .onReceive(pausePulse) { _ in
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
        // ⚠️ THE STORY UNDERNEATH MOVES THE INSTANT THE ROW DOES, AND BOTH HALVES OF WHY THAT WAS
        // EVER A PROBLEM ARE NOW GONE.
        //
        // He bisected the first half himself: 516 correct, 517 wrong, and `fc16da9a` is the commit
        // in 517 that stopped posting this immediately and started remembering the selection to
        // spend at the close. The deferral WAS the bug, and it was put back to 516's behaviour.
        //
        // It had been added for a real report — "the real-time cover disappears when I swipe the
        // sheet" — which was true of an architecture where one player served every story: jumping
        // tore clip A out of the layer on screen and began downloading B under a 100pt thumbnail.
        //
        // Neither half survives the item-owned player. Clip A is not torn out of anything, because A
        // has its own view and its own player and the store keeps both alive for as long as this
        // sheet is up; swiping back hands A's own paused player straight back, still on its own
        // frame. And B does not start under the sheet either, because a paused item never builds a
        // player at all — the reference app's `initializeVideoIfReady` rule, which the note that used
        // to sit here called the right fix and left for a separate change. This is that change,
        // already made: see `StoryItemVideoView.initializeVideoIfReady` and `StoryItemViewStore`.
        .onChange(of: sheetStoryId) { _, id in
            // ⚠️ `showingMine`, NOT `currentIsMine` ALONE. `currentIsMine` depends on
            // `currentBucketUid`, which only arrives after the library's `onUserChanged`, so on a
            // fresh open it can still be empty — the note at `onSwipeUpChanged` says exactly this,
            // which is why the swipe-up that OPENS this sheet accepts either. This guard demanding
            // the stricter one is how the handler came to be silently skipped for a whole session.
            // (Was `currentIsMine || mineOnly`. `mineOnly` stopped being true for my own story the
            // moment my bucket joined the paged set, so it had to become the first-frame fallback
            // rather than a second reading of the same thing — see `showingMine`.)
            guard showViewers, showingMine, !id.isEmpty else { return }
            // Same deferral as the first handler — a crossing mid-movement is not a destination.
            guard pageDragBox.rowLink?.isRowMoving != true else { return }
            NotificationCenter.default.post(name: .init("jumpToStoryItem"), object: id)
            // ⚠️ THE ANCHOR IS NOT WRITTEN HERE EITHER, AND THIS IS THE SECOND OF THE TWO.
            //
            // There are two `.onChange(of: sheetStoryId)` handlers on this view and both wrote it,
            // for the same out-of-date reason: `currentStoryId` used to come only from the WATCHED
            // receipt, which is withheld while a story is paused, and the sheet pauses the story for
            // its whole life. The ungated item-changed report owns it now and the jump handler fires
            // that report from the statement that swaps the item, so the truth arrives on the same
            // runloop turn as the picture. Removing it from one handler and leaving it in the other
            // would have fixed nothing.
        }
        // ⚠️ THE WATCHER BEHIND `refreshTick`, STARTED AND STOPPED WITH THE SHEET. Two handlers with
        // no guards of their own on purpose: every other `sheetStoryId` handler on this view returns
        // early on `showingMine`, and a watcher that inherits those guards is how the sheet's live
        // list came to be dead in the first place. `watchViewCount` is idempotent, so re-asking for
        // the story it is already on costs nothing.
        .onChange(of: showViewers) { _, _ in syncViewCountWatch() }
        .onChange(of: sheetStoryId) { _, _ in syncViewCountWatch() }
        .onDisappear { StoriesService.shared.stopWatchingViewCount() }
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
            // ⚠️ PER PAGE NOW, NOT PER SESSION — and this is a real behaviour change, on purpose.
            //
            // This was `mineOnly`, which meant "my story is alone in this viewer" and so was fixed
            // for the whole sitting. My bucket is one page among several now, so the card treatment
            // and the owner footer follow the PERSON: my page gets the rounded card with the Views
            // and trash bar under it, and paging on to a friend gets their full-bleed story with the
            // library's reply bar. A friend's story must not carry my Views bar, and the footer
            // cannot be decided once for a viewer that walks through several people.
            //
            // ⚠️ AND THE STORY ITSELF IS WRITTEN ONCE, OUTSIDE THAT DECISION. THIS IS HIS
            // "MY OWN STORY NEVER REACHES THE NEXT PERSON" REPORT, 2026-08-14.
            //
            // `storyContent` used to be written once inside `if currentIsMine` and once inside its
            // `else`. Two branches of one conditional are two STRUCTURAL IDENTITIES to SwiftUI, so
            // the moment the viewer left my bucket for a friend's — which is precisely when this
            // flag flips — the whole `StoryView` was destroyed and a new one built in the other
            // branch. The rebuild takes its `@StateObject StoryViewModel` with it, and the fresh one
            // runs `startStory()` on appear, which seeds `currentStoryUser` from `selectedIndex`:
            // THE BUCKET THE DOOR OPENED ON. Mine. So every attempt to leave my own story — the tap
            // past the last item, the sideways swipe, and the last item simply finishing — moved one
            // page forward and was thrown straight back onto me, with the pager rebuilt underneath
            // it. That is his "it stays on my own story… the viewer is locked to the owner story",
            // and it is why only MY bucket could show it: a friend-to-friend turn never moves this
            // flag, so a friend's story paged perfectly all along.
            //
            // ⚠️ DO NOT PUT IT BACK INSIDE THE BRANCH, however tempting the symmetry looks. One
            // writing, at a fixed position in this stack, is what keeps its identity independent of
            // whose page is showing. Only the FOOTER varies, and an `if` with no `else` leaves the
            // sibling in front of it alone. Anything else that has to differ per person must differ
            // by VALUE (a modifier's argument), never by which branch drew it.
            //
            // My own story: a CARD (rounded bottom corners) + solid black footer below. The clip
            // is ONLY applied for mine — clipping a FRIEND's full-bleed story broke the library's
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
                //
                // ⚠️ AND IT IS A VALUE, NOT A BRANCH. A friend's page gets the same modifier at
                // zero opacity, which paints exactly what their page painted before: nothing.
                // Deciding it with a second copy of `storyContent` is what cost the whole
                // viewer its identity — see the note above this stack.
                .background(Color.black.opacity(currentIsMine && !heroFlying ? 1 : 0))
            // ⚠️ EMPTY NOW, AND ON PURPOSE. The owner's bar used to be drawn here, as a sibling of
            // the pager, which is exactly why it could not travel with the story: the cube turns
            // PAGES. It is passed to the library instead and drawn inside my own page, beneath the
            // card, where a friend's reply bar has always been drawn. Nothing replaces it here.
            // (A friend's page adds nothing here either: their story is full-bleed and the library
            // draws their reply bar inside the page, which is now true of MY bar as well. The
            // `else` that used to sit here held a SECOND `storyContent`, and that second writing
            // was the bug — see the note above.)
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
                publishOwnerBar()
                // The counts for ALL of my stories start here, together, rather than one at a time
                // as each becomes current — see `prefetchMyStoryCounts`. This is the earliest moment
                // the viewer knows whose bucket it is on.
                prefetchMyStoryCounts()
            },
            onItemSeen: { id in
                // ⚠️ THE LOOKAHEAD USED TO START HERE AND IT CANNOT. This callback is a SEEN
                // RECEIPT, and the library withholds it while the story is paused, held or
                // buffering — so the next clip's download waited on this clip's download. It now
                // runs off the item CHANGING, inside the viewer, on the same flattened list; see
                // the note at the top of `StoryDetailView.startProgress`.
                //
                // Nothing about "what is on screen" belongs here either, for the same reason and
                // now for the same fix — see `onItemChanged` below. What is left is the only work
                // that genuinely means WATCHED: persisting the seen mark and the view receipt.
                // The synthetic still-uploading item has no real doc — don't persist it as "seen".
                guard !StoriesService.isPending(id) else { return }
                StoryPrefs.markStorySeen(id)
                markSeenItem(id)
            },
            // ⚠️ WHICH ITEM IS ON SCREEN COMES FROM HERE NOW, NOT FROM THE SEEN RECEIPT, AND THAT
            // IS THE FIX FOR BOTH OF HIS 2026-08-10 REPORTS.
            //
            // `currentStoryId` and everything hanging off it — the "Uploading…" bar
            // (`isUploadingItem`) and the owner's view count (`loadBarViewers`) — used to be written
            // by `onItemSeen`. That is a WATCHED receipt: the library withholds it while a story is
            // paused, held, folding, buffering or behind the keyboard, and for a view-once story
            // delivering it SPENDS the single view. So it is the one signal in the library that is
            // deliberately late, and it was being used to answer a question that cannot be late.
            //
            // The viewers sheet pauses the story for its whole life and the watchdog re-asserts that
            // pause twice a second, so under the sheet the receipt may never arrive at all — the id
            // stays stuck on whatever was last WATCHED. That is both reports in one sentence: an
            // eighteen-hour-old story wearing the "Uploading…" bar because the stuck id still
            // matched a placeholder, and the view count arriving late because the fetch is keyed on
            // the same id.
            //
            // `onItemChanged` fires on the item changing with no gate at all, within one 20fps tick.
            // Same split the reference app draws: `markAsSeen` waits for real playback, the current item is
            // published immediately.
            onItemChanged: { id in
                currentStoryId = id
                publishOwnerBar()
                // The synthetic still-uploading item has no real doc, so there are no viewers to
                // fetch — but it MUST still become `currentStoryId`, because that is exactly how the
                // "Uploading…" bar knows the placeholder is the thing on screen.
                guard !StoriesService.isPending(id) else { return }
                loadBarViewers()
            },
            onDrag: { d in dragDown = d },   // fade my overlays out as the card is pulled down
            showMore: true, // "…" is a native dropdown menu in the header; its buttons post notifications
            onSwipeUp: { },   // superseded by the continuous callbacks below
            // Real-time swipe-UP: the library's direction-locked up pan reports the drag live, so the
            // sheet follows the finger 1:1 (native feel) and snaps on release — WITHOUT an app gesture
            // that would fight the library's down dismiss pan. Swipe-DOWN dismiss is the library pan too.
            onSwipeUpChanged: { up in
                // ⚠️ `showingMine`, and this is the guard its first-frame fallback exists for.
                // `currentIsMine` depends on `currentBucketUid`, which is only set AFTER the library's
                // `onUserChanged` fires — so on a fresh open it can still be empty and would silently
                // block the whole swipe-up, or worse, drop through to the friend's-story branch below
                // and open the REPLY KEYBOARD on my own story. `mineOnly` used to cover that window
                // and cannot any more: my bucket is one page among several now.
                guard showingMine else { return }
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
                guard showingMine else {
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
                // The reference app's open rule, in points (from the reference implementation's dismiss-pan handling): commit past
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
            onHeroDrag: { phase, t, v in onHeroDrag(phase, t, v) },
            // MY BAR, HANDED TO THE PAGE THAT DRAWS IT. The view it returns watches
            // `StoryOwnerBarModel`, so a page that is built once still shows a count that moves.
            ownerBar: { _ in AnyView(StoryOwnerBarView()) },
            ownerBarHeight: Self.ownerFooterHeight + max(10, bottomInset)
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
                // ⚠️ APPLE'S SYMBOL, NOT THE EMOJI — his 2026-08-18 "dont use emoji icon use apple
                // icon lock". A 🔒 inside the string is a colour glyph from whatever font the system
                // reaches for: it ignores the text's weight, keeps its own yellow whatever the label
                // is dimmed to, and cannot be aligned to the cap height. `lock.fill` is drawn as part
                // of the label instead, so it takes the same size, the same opacity and the same
                // baseline as the words next to it, and it dims with them.
                HStack(spacing: 6) {
                    Text(reason)
                    Image(systemName: "lock.fill")
                }
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
        // ⚠️ DELETED HERE: the `currentIsMine && !mineOnly` gradient owner bar.
        //
        // It was the safety net for "my story inside a MIXED feed", described in its own comment as
        // not the normal flow, because the card-and-footer layout above only ran for a mine-only
        // viewer. Routing my bucket into the paged set makes a mixed feed THE normal flow, so this
        // would have fired on every viewing of my own story — on top of the card footer, which now
        // triggers on the same `currentIsMine`. Two owner bars, one gradient and one solid, stacked.
        //
        // The card treatment wins because it is the designed one: rounded bottom corners with a solid
        // black Views/trash bar beneath, which is what the gradient bar was replaced by in the first
        // place ("the old gradient bar bled over the story to the screen edge"). Its swipe-up-to-open
        // is not lost either — `onSwipeUpChanged` carries that for every page.
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
        // `miniH` (the full mini-screen composite height) lived here and is deleted: it was passed
        // to the row and never read by it, left over from a card that drew a window onto a composite
        // rather than a story of its own.
        let top: CGFloat        // the card block's top edge on screen
        var centerY: CGFloat { top + h / 2 }
        /// The row's layout AT A GIVEN PULL. `fraction` is load-bearing — half the numbers in
        /// `StoryRowGeometry` change with it — so it is a parameter rather than something the
        /// geometry is left to guess.
        func row(fraction: CGFloat) -> StoryRowGeometry {
            StoryRowGeometry(slotW: w, slotH: h, centerY: centerY,
                             fullW: UIScreen.main.bounds.width, fraction: max(0, min(1, fraction)))
        }
    }

    /// THE STORY'S HEIGHT WHEN NOBODY HAS MEASURED IT YET — and it is the library's own formula
    /// rather than a guess of our own, which is the whole point.
    ///
    /// ⚠️ THE OLD ESTIMATE WAS NOT THE STORY'S SHAPE, AND EVERY CONSUMER OF IT INHERITED THAT.
    ///
    /// It was `scr.height - (currentIsMine ? ownerFooter + bottomInset : 0)`: 766 for my own story
    /// and the whole 852 before `currentIsMine` had landed, against a story that is really 699. The
    /// slot is built as `h * (contentW / contentH)`, so the slot came out TALLER in aspect than the
    /// picture — 1.95 or 2.17 against 1.78 — and a slot taller in aspect than its content is the
    /// black band under the card this file has chased twice. On the 852 branch that is 31pt of empty
    /// card, about 18% of it.
    ///
    /// This is `StoryDetailView.cardHeight` written out: a 9:16 card unless the screen is too short
    /// for one, in which case it gives up height rather than running under the bar below it. On a
    /// 393x852 it returns exactly 699 — the same number the measurement returns — so the estimated
    /// path and the measured path now agree instead of merely being close, and the answer no longer
    /// depends on `currentIsMine` arriving, which is known to be a beat late on a fresh open.
    ///
    /// ⚠️ ONE CALLER NOW, AND THAT IS THE POINT RATHER THAN A LOSS. It briefly had two: `cardSlot`
    /// sized the card with it and `sheetSizeFraction` measured the pull with it, from two different
    /// fallbacks for one rectangle — which on the not-mine branch sized the card from 852 while the
    /// pull was computed from 793, a fraction of 0.154 against 0.300 at the same point in the drag.
    /// The pull does not read a content height at all any more (it is the drag itself), so the story's
    /// own rectangle is asked for in exactly one place: here.
    private var estimatedContentHeight: CGFloat {
        let scr = UIScreen.main.bounds
        return min(ceil(scr.width * 1.77778),
                   scr.height - topInset - max(currentIsMine ? Self.ownerFooterHeight : 0,
                                               bottomInset + 1))
    }

    private var cardSlot: CardSlot {
        let scr = UIScreen.main.bounds
        let sheetH = scr.height * StoryViewersSheetView.heightFraction
        let avail = scr.height - sheetH - topInset          // free area above the open sheet
        // Card block = the centred card + the big count row (~40) below it, centred vertically in
        // the free space with the status bar cleared. The narrow slot is what makes the neighbours
        // sit clearly off-centre so their scale-down actually reads.
        let countArea: CGFloat = 40
        // ⚠️ `currentIsMine`, MATCHING `storyLayer`'S OWN TEST, AND THEY MUST NOT DRIFT APART.
        //
        // This is the height the story CONTENT occupies, and it is short by the owner footer exactly
        // when that footer is drawn. `storyLayer` decides that per page now (it was `mineOnly`, fixed
        // for the whole sitting), so this has to ask the same question the same way or the shape the
        // morph shrinks INTO stops matching the shape it is shrinking.
        //
        // ⚠️ TWO READERS DEPEND ON THIS AGREEING: `driveMorph`, which puts the live card at
        // `slot.centerY`, and the carousel, which draws the row of cards around it. Answer this
        // differently from `storyLayer` and the live story lands somewhere the carousel is not.
        // ⚠️ MEASURED, NOT PREDICTED — and that is the fix for the black band under the story.
        //
        // This used to be `scr.height - (currentIsMine ? ownerFooter + bottomInset : 0)`: a guess at
        // the height the morph would crop against. The morph does not guess — `contentRect` builds
        // it from the metrics the library reports — so two numbers had to agree about one rectangle,
        // and `currentIsMine` is known to arrive a beat late on a fresh open.
        //
        // Guess high and the card is TALLER IN ASPECT than the content it is cropping. The crop then
        // asks for more height than the scaled content renders, and the surplus is empty: a black
        // band across the bottom of the card. With the footer mispredicted the card wants
        // 0.88 × 852 = 750pt of a content only 734pt tall — a 2% error, which is exactly why it
        // appeared "sometimes" rather than always.
        //
        // Reading the morph's own rectangle removes the second copy instead of correcting it. The
        // old estimate stays as the fallback for the frames before a card is registered.
        // ⚠️ LATCHED, NOT READ LIVE — and this is the second half of the fix.
        //
        // Reading the morph directly here made the slot a moving target: the metrics arrive part way
        // through the pull, so the card was sized against a full-screen height for the first frames
        // and against the real content height afterwards. The card grew or shrank as it flew, which
        // is his "sometimes too tall, sometimes too short". A slot has to be ONE rectangle for the
        // whole of a pull or the thing shrinking into it cannot be still.
        //
        // `latchedContent` is captured once at the start of each pull (see `driveMorph`) and held
        // for that sitting. Nil falls back to the old estimate, which is stable for the same reason
        // — it is a pure function of the screen.
        // ⚠️ THE LIVE MEASUREMENT BEFORE THE PREDICTION, AND THAT ORDER IS THE FIX FOR HIS BLACK
        // BAND UNDER THE STORY ON THE FIRST PULL.
        //
        // The latch is still first, and still for the reason below: a slot that moves under a card
        // already in the air is a card that changes size as it flies. But `latchedContent` is only
        // written from `driveMorph` while `p < 0.25`, so a sitting where the morph has not answered
        // inside that window keeps NIL for the whole pull — and nil used to fall straight through to
        // the screen-derived guess. It only fails the first time because that guess reads
        // `currentIsMine`, which arrives a beat late on a fresh open.
        //
        // WHY A HIGH GUESS LEAVES A BAND, in numbers, because "it looks cut off" has been diagnosed
        // three different ways in this file:
        //
        //     slot aspect  = 0.88 · contentH_host / contentW      (h = slotHRef · 0.88, w from contentH)
        //     card aspect  = contentH_real / contentW             (what `applyCore` actually crops)
        //
        // `applyCore` renders `cropH · scale = min(restH · scale, visibleH)`, so the moment the slot
        // is TALLER in aspect than the content, the card draws shorter than the seat it was given and
        // the surplus is empty. With the owner footer mispredicted the host says 932 where the real
        // content is 765 — 22% out, against the 13.6% the 0.88 buys — so the card renders short and
        // the gap is under it. Nothing is cropped, which is why the whole picture is still there in
        // his screenshot with black beneath it.
        //
        // Asking the morph is not a second copy of the number; it is the same rectangle `applyCore`
        // will crop against, which is what `contentSize` exists for. The guess stays as the last
        // resort for the frames before any card is registered, where there is genuinely nothing to
        // ask.
        let content = latchedContent ?? StoryCardMorph.shared.contentSize
        let contentW = content?.width ?? scr.width
        let contentH = content?.height ?? estimatedContentHeight
        // BUILD 249 card size (user: "make it exactly like 249, 250 is too long"), and the HEIGHT is
        // still exactly that number — `slotHRef * 0.88` has not moved since.
        let slotHRef = (avail - countArea) * 0.94
        let h = slotHRef * 0.88
        // ⚠️ THE WIDTH COMES OFF THE HEIGHT NOW, AND THE 0.88 IS NOT IN THE CARD'S SHAPE ANY MORE.
        //
        // His 2026-08-13 screenshots, 555 beside the current build: same height, card ~14% wider,
        // and it reads squat. One line moved between them and it was not this one.
        //
        // What 555 did:  w = slotHRef * (screenWidth / (screenHeight - ownerFooter))
        // What it became: w = slotHRef * (contentW / contentH), contentH now MEASURED
        //
        // On a 430x932 with his footer that swaps 872 for 765 underneath, so the width goes
        // 0.493 -> 0.562 of the reference. The height never changed, which is exactly what he saw.
        //
        // ⚠️ AND THIS IS WHY THE 0.88 WAS INVISIBLE FOR SO LONG. Paired with the screen-height guess
        // it produced `0.88 * 872/430 = 1.785` — 9:16 to within half a percent — so the card was
        // aspect-TRUE by accident of that pairing and the "12% shorter" it was signed off as never
        // actually shaved anything. Swapping the guess for the real content height dropped the
        // number under it and the 0.88 started biting for real: 1.566, genuinely squat.
        //
        // So the height keeps the 0.88 and the width is derived from it at the story's OWN aspect.
        // That lands at 0.4947 of the reference against 555's 0.493 — under half a point on screen —
        // and because the card now has exactly the content's shape, `applyCore`'s crop removes
        // nothing and cannot leave the empty band under the card either. One expression answers both
        // reports, which is the sign it is the right one.
        let w = h * (contentW / max(contentH, 1))
        return CardSlot(w: w, h: h, top: topInset + (avail - countArea - h) / 2)
    }

    // ⚠️ `scheduleFrozenCapture` AND `captureFrozenCover` ARE GONE, AND NOTHING REPLACES THEM HERE.
    //
    // Between them they were a 0.35s settle-and-verify timer, a force flag, a url cross-check, a
    // live-card photograph through one global pointer, and a sweep over every other story — all to
    // answer one question: what picture does this card show? A card answers that for itself now, at
    // draw time, keyed by its own clip (`cardMedia`).
    //
    // ⚠️ AND THE ANSWER IS NO LONGER A PHOTOGRAPH OF ANYTHING. Every version of this — the capture
    // timer, the frame bank that replaced it, the weak registry of players, the paused-player pool —
    // was trying to catch a picture before a pause took it away, and the source refuses: a paused
    // item's video output hands its buffer over exactly once. The clip's own player is still alive
    // and still paused on that second (`StoryItemViewStore`), so the frame is generated from the
    // clip's own file at that exact time instead. There is no instant to catch, which is why there
    // is nothing left here to schedule.

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
        // ⚠️ WHAT HE JUST CHOSE BEATS WHAT THE SNAPSHOT SAYS. `StoryViewer` is handed
        // `let groups: [StoryGroup]` when it is presented and never re-fed for anything but an id
        // change, so a story whose audience was edited from the sheet over the top of it goes on
        // wearing the label it was opened with until the whole viewer is thrown away. This is that
        // one field, kept for as long as this sitting lasts; the repository catches up underneath and
        // the next open reads the real thing.
        if let b = audienceOverride[s.id] { return b }
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
    /// ⚠️ THIS IS WHAT MAKES THE CIRCLE MORPH WORK, and it is why the circle needed almost no new
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
        setFlightChromeHidden(hero.exiting || f > Self.heroChromeSpan)
    }

    /// THE ONE WRITER OF "IS A FLIGHT HIDING THE CHROME" — the box, the readable flag and the
    /// notification together, because they are one fact and were drifting apart.
    ///
    /// ⚠️ THE READABLE FLAG IS WHY THE OPEN NOW ANIMATES AT ALL (his 2026-08-16 report). This posted
    /// a notification and nothing else, and on an OPEN the first post is made while the card is
    /// being seated — before the page that draws the header and footer exists. Nobody heard "hide",
    /// so the page came up with its chrome already visible over a card still out in the room, and
    /// the "show" that arrives at 18% was no change and animated nothing. The close was always
    /// correct because its page is on screen for both posts. `StoryCardMorph.flightChromeHidden`
    /// is the same answer left where a page being born can read it.
    private func setFlightChromeHidden(_ hide: Bool) {
        guard hero.chromeHidden != hide else { return }
        hero.chromeHidden = hide
        if heroFlying != hide { heroFlying = hide }
        StoryCardMorph.flightChromeHidden = hide
        NotificationCenter.default.post(name: .init("storyFlightActive"), object: hide)
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
        // reference screenshot shows the picture inside the circle almost from the first frame.
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
    /// also makes `resetFlight`'s black a visual no-op, and gives the close drag the reference app's look:
    /// the letterbox black GIVES WAY progressively as the card leaves, instead of vanishing on the
    /// first frame of the drag.
    ///
    /// In the middle: the other app's grey, from his screenshots — the list behind is clearly dimmed but
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
    /// The one line the locked reply bar shows, whichever refusal it is. His words, and a typographic
    /// apostrophe because this is a sentence rather than code.
    private static let replyLocked = "You can’t reply to this story"

    private var replyLockReason: String? {
        guard !currentIsMine else { return nil }          // my own story has the owner bar instead
        // ⚠️ ONE SENTENCE FOR BOTH REFUSALS, ON HIS 2026-08-18 WORD, AND THE LOCK IS NO LONGER IN IT.
        //
        // It read "You can only reply to people you chat with 🔒", which explains the app's rule to
        // somebody who did not ask about it and is a mouthful on one line. His replacement says the
        // only thing the reader needs: this story cannot be replied to. Whether that is the author's
        // reply switch or the audience they chose is the app's business, not the reader's.
        //
        // ⚠️ AND THE EMOJI IS GONE FROM THE STRING. A 🔒 is a colour glyph from whatever font the
        // system picks, so it does not match the text's weight, does not take the text's colour, and
        // cannot be tinted with it. The bar draws `lock.fill` beside this now — see the call site —
        // which is Apple's own symbol, sized to the text and dimmed with it.
        guard deliveredToMe || StoryContact.isFriend(currentBucketUid) else { return Self.replyLocked }
        guard currentStory?.allowsReplies == false else { return nil }   // a real bar is showing
        return Self.replyLocked
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
        // the reference app's own transition logic carries a `sourceView` rather than a remembered rectangle. A
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
            // that never moved — his frame-grab, against another mainstream messenger where "the thumbnail itself
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
            // he likes, and it is the standard messengers' behaviour: out as a card, home as a
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
            // The cube must not fold while the card is in flight, in EITHER direction: `applyCube`
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
            // THE SLOT EMPTIES, the same way, on his frame-grabs (2026-08-07): "the card goes
            // [to] the empty place it comes from... [the] place is empty and waiting to fill it
            // back". The card that lifted off IS the slot's picture (the cover above), so hiding
            // the real one costs nothing and the row shows a waiting hole for as long as the story
            // is open. Revealed by the teardown (`storyPresenterClosed`), not by the open.
            MediaSourceVisibility.shared.hide(MediaOpenRects.key(.storyRow, heroKeyNow()))
            StoryCardMorph.shared.revealAfterHeroOpen?()
            // THE OPEN'S OWN SPRING — softer than the close's, on his frame-scrub
            // (2026-08-07): what reads as "smoother" there is not the total time, it is the long
            // gentle glide into full screen, where another mainstream messenger's 631 arrives and stops. Still softer than
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
            // is out in the room. Matching his reference screenshot, where the page behind the growing
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
                setFlightChromeHidden(false)
                StoryCardMorph.heroDismissActive = false
                // `resetFlight`: identity, unmasked, cover off, and the presenter's wall opaque
                // again. The sheet's own `reset` has no business here — the flight never touched
                // its view. NO `MediaSourceVisibility.reveal()` any more: the slot stays EMPTY for
                // the whole viewing, waiting for the close to fill it back (his spec);
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
            // it and left a bare photo sliding around. Another mainstream messenger keeps them: they are drawn inside the
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
            // from. Another mainstream messenger's card bottoms out at just under a third of the screen and will not go
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
        NotificationCenter.default.post(name: .init("pauseStory"), object: nil)
        let anchorCentre = CGPoint(x: hero.anchor.midX, y: hero.anchor.midY)
        // THE CARD FILLS THE EMPTY SLOT IT LEFT, his spec in his own words: "the card
        // goes [to] the empty place it comes from... waiting to fill it back". The slot has been
        // hidden since the open. On the way home the flying card puts the COVER back on (the
        // landing tick below: in from just before half-way, fully worn by four-fifths), so what
        // touches down is pixel-identical to the row card the teardown then reveals — the swap at
        // the landing exchanges two identical pictures and cannot pop. This replaces the previous
        // fade-into-a-visible-card landing: he watched it frame by frame and asked for the
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
            setFlightChromeHidden(false)
            // Full screen, square, unmasked, and the wall behind opaque again. `resetFlight` is
            // what puts the container back exactly, rather than an `applyFlight(fraction: 0)` that
            // leaves a mask covering the whole card for every frame the story renders from here on.
            StoryCardMorph.shared.resetFlight()
            StoryCardMorph.heroDismissActive = false
            StoryCardMorph.shared.restoreAfterHero?()
        }
    }

    // ⚠️ `@MainActor` FROM HERE DOWN THIS PATH, EXPLICITLY. `StorySheetPageDrag` is a `@MainActor`
    // class and this chain reads it (`pageDragBox.rowLink`), so the isolation has to be
    // stated rather than inherited: conforming to `View` isolates `body`, not the type's own
    // methods, and a nonisolated method touching a main-actor class is a hard error rather than a
    // warning. Every caller is a `body` closure, which is already on the main actor.
    @MainActor
    private func driveMorph(_ p: CGFloat) {
        // ⚠️ A CANCELLED FLIGHT LEAVES BOTH HERO FLAGS RAISED, AND THIS IS WHERE THEY COME DOWN.
        //
        // `SheetProgressAnimator.cancel()` nils the completion, and the hero's completion is the
        // ONLY place `hero.live` and `heroDismissActive` are lowered on the open path. So an open
        // whose spring is interrupted — a finger arriving during it is enough, and that is the
        // commonest thing a person does — leaves both standing for the rest of the sitting. Every
        // gate below then refuses forever: the story simply never shrinks when the sheet is pulled,
        // which is his 2026-08-13 video.
        //
        // The test is not a guess about who cancelled what. If the hero's own spring is not running,
        // there is no flight, and a flag that says otherwise is describing something that has already
        // finished. The pre-554 build survived the same leak because its shrink read neither flag;
        // 554 put `heroDismissActive` in front of the placement, which is why the leak only started
        // showing then.
        if hero.live, !heroAnimator.isRunning {
            hero.live = false
            StoryCardMorph.heroDismissActive = false
        }
        // A hero open or close owns the card outright. Without this, the sheet's reset-on-zero would
        // slam a card that is mid-flight back to full screen — and `viewersProgress` is written to 0
        // by several teardown paths, one of which is the close this would be interrupting.
        guard !hero.live else { return }
        // ...and the same for the static flag on its own. `hero.live` is false from here on, so a
        // raised `heroDismissActive` cannot be a live flight either — it is the same leak reaching
        // the row's placement, which reads it directly.
        if StoryCardMorph.heroDismissActive, !heroAnimator.isRunning {
            StoryCardMorph.heroDismissActive = false
        }
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
        // ⚠️ CAPTURE THE CONTENT RECTANGLE ONCE, AT THE TOP OF THE PULL, AND NOT AGAIN.
        //
        // The morph answers nil until the library's metrics are real, so the first frames of a pull
        // may find nothing and keep the screen-derived estimate. The moment a real answer exists it
        // is latched for the rest of this sitting — `cardSlot` must not be re-measured under a card
        // that is already flying, or the slot moves and the card changes size in the air.
        //
        // Written only while the pull is still near the bottom. Past that the card is committed to a
        // shape and a late arrival would be exactly the jump this exists to prevent.
        if latchedContent == nil, p < 0.25, let real = StoryCardMorph.shared.contentSize {
            latchedContent = real
        }
        // ⚠️ `setHidden(false)` USED TO BE FORCED HERE ON EVERY FRAME BELOW p≈0.9, AND IT IS GONE
        // WITH THE THING IT WAS REPAIRING.
        //
        // It was a belt on the copy-swap: the copy faded out with the carousel under 0.9, so a hide
        // left standing by a cancelled swipe meant alpha 0 under a vanished copy — his black window.
        // Nothing hides the live story any more, so there is no stuck flag to sweep up after, and a
        // per-frame repair for a state that cannot occur is just a line waiting to be wrong.
        //
        // ⚠️ THE PULL TELLS THE ROW HOW FAR IT HAS GOT, AND STOPS THERE. It used to compute the live
        // story's whole rectangle and post it to the morph, which made it the second thing laying
        // out a story the row was already laying out. One number goes out now; the row owns the
        // layout, the live story included. See `StoryRowController.setFraction`.
        pageDragBox.rowLink?.setFraction(sheetSizeFraction(p))
    }

    /// THE PULL — the reference layout's `contentScaleFraction`, and the one definition of it.
    ///
    /// ⚠️ STATIC AND SHARED, because the row is laid out from it too now. Half of `StoryRowGeometry`
    /// changes with this number — the spacing, the resting position — so the cards and the live
    /// story reading two different copies of it would put them in two different places, which is the
    /// exact failure this rebuild is being repaired for.
    /// ⚠️ THIS IS DERIVED FROM THE SHEET'S OWN GEOMETRY NOW, NOT DRAWN BY HAND.
    ///
    /// It used to be `clamp((p - 0.08) / (0.9 - 0.08))`: a straight line with a dead patch at the
    /// start and a tenth left over at the end, chosen by eye. It lands in the right place at both
    /// ends and agrees with the sheet nowhere in between, which is the owner's report that the
    /// thumbnails do not stay in step with the sheet while he drags it. A remap cannot be in step
    /// with something it does not read.
    ///
    /// Theirs is not a curve at all — it is what fits. `:3955-3971`, in their names:
    ///
    ///     contentVisualHeight = min(contentSize.height, availableSize.height - insets.top - viewListInset)
    ///     contentVisualScale  = min(1.0, contentVisualHeight / contentSize.height)
    ///     contentScaleFraction = 1.0 - (contentVisualScale - contentMinScale) / (contentMaxScale - contentMinScale)
    ///
    /// The story is only ever as big as the room left above the sheet, and the fraction is where
    /// that sits between its two ends. Every number in it is a length on the screen this frame, so
    /// it cannot drift out of step with the sheet: it IS the sheet.
    ///
    /// ⚠️ AND THERE IS NO DEAD PATCH AT THE START, BECAUSE THEIRS HAS NONE. The owner, 2026-08-13:
    /// the shrink "start when the sheet viewer is 10/15% coming down… feeling late". He is right, and
    /// the first version of this derivation is what put it there.
    ///
    /// The slack came from measuring the free space as the whole screen below the status bar. On a
    /// 393x852 a 9:16 story is 699pt of a 793pt space, so the sheet had 94pt — about 17% of its
    /// travel — to climb before it reached the bottom of the story and anything began to move.
    ///
    /// Their story has no such slack, and the three lines that say so are:
    ///
    ///     :3442  let defaultHeight = 60.0 + safeInsets.bottom + 1.0
    ///     :3542  viewListInset = defaultHeight * (1 - midFraction) + midFraction * midViewListHeight
    ///     :3551  maximizedBottomContentHeight = defaultHeight
    ///
    /// Their view list is never off the screen: it RESTS at `defaultHeight`, and the story's own
    /// height is built as `min(9:16, available - top - defaultHeight)` — already fitted to the space
    /// above it. So `contentVisualBottomInset`, which is `max(default, viewListInset)`, sits exactly
    /// on `defaultHeight` at rest and exceeds it on the first pixel of the drag. The story starts
    /// shrinking immediately because it was never larger than the room it had.
    ///
    /// Ours rests fully off the screen, so the honest equivalent is that the story cedes exactly the
    /// height the sheet takes, from the first pixel:
    ///
    ///     liveH = restH - p·sheetH        minH = restH - sheetH
    ///     fraction = (restH - liveH) / (restH - minH) = (p·sheetH) / sheetH = p
    ///
    /// which cancels to the drag itself. So this is `p`, and that is a derivation rather than a
    /// shrug: the reason it is linear is that a story already fitted to its space gives up whatever
    /// is taken from it, one point for one point.
    ///
    /// ⚠️ IT ALSO ENDS THE LAST FAMILY OF BUGS THIS FUNCTION HAD. Reading a measured content height
    /// in here meant reading a value that is nil until the library reports one and can turn real at
    /// any moment — which moved the resting height under a drag in progress and jumped the fraction
    /// BACKWARDS mid-pull. There is nothing left to read: `p` is the finger. Do not reintroduce a
    /// content height here; `cardSlot` is where the story's own rectangle belongs.
    func sheetSizeFraction(_ p: CGFloat) -> CGFloat {
        max(0, min(1, p))
    }

    // ⚠️ `placeLiveStory(fraction:)` IS DELETED HERE — the 2026-08-13 ruling, and the largest single
    // piece of it.
    //
    // It worked out which story was live, where the row was sitting, and what rectangle the story
    // should therefore occupy, and posted that to `StoryCardMorph`. Every one of those questions is
    // one the ROW answers for each of its own cards, in a loop, from `StoryRowGeometry` — so this
    // was a second, hand-written copy of the row's layout that had to arrive at the same answer as
    // the loop it was standing beside. It did not, four times: the row position that defaulted to
    // "story one", the logical distances used where the scaled ones were needed, the two-step motion
    // at the page commit, and the pre-divided x that existed to cancel a lerp on the far side.
    //
    // The live story is an item in the row's own table now (`StoryRowController.items`), placed by
    // the same `StoryRowPlacement` as its neighbours in the same pass. What used to be pushed from
    // here is one number: how far the pull has got. See `driveMorph`.

    // The layer behind the viewers sheet: the row of ALL my stories, with the live one among them
    // rather than parked in the middle of them. The neighbours and the count row fade in over the
    // last tenth of the pull, behind a card that has already stopped moving.
    @ViewBuilder private var viewersBackdrop: some View {
        let p = viewersProgress
        // ONE source for the slot (see `cardSlot`). The fill-vs-blur decision the neighbour cards
        // make against `slotH / slotW` still lives in `card(_:)`; only the numbers moved.
        let slot = cardSlot
        let blockTop = slot.top
        // STAGING. `carIn` fades the neighbours and the count row in over the last tenth of the pull.
        //
        // ⚠️ IT NO LONGER HAPPENS "BEHIND A CARD THAT HAS ALREADY STOPPED MOVING", AND THE OLD
        // SENTENCE IS DELETED RATHER THAN REPHRASED. That was only ever true by coincidence: the old
        // fraction finished at p = 0.9 and this fade started at p = 0.9. The pull is geometric now
        // and finishes with the sheet, so at the moment the neighbours begin to arrive the centre
        // card still has the last tenth of its travel to make.
        //
        // Left that way on purpose. Theirs does not fade a row in at all — every item is present the
        // whole time and the tint layer is what makes the neighbours invisible while the sheet is
        // down, which is the term ported alongside this. Arriving over the last of the motion is
        // closer to that than waiting for the motion to stop, and the thing this fade is still
        // needed for is the count badges and the shadows, which sit outside the tint.
        //
        // THERE IS NO PICTURE OF THE STORY ANYWHERE IN THIS ROW, and that is the whole of the
        // frozen-frame fix. The live story is one of the row's items now — laid out by the row's own
        // geometry, sliding when the row slides — so a video shows the frame it is actually on
        // because it is still the same layer drawing it, at every position and not only at rest.
        // The card standing in its place keeps its frame and its tap target and draws no pixels, so
        // there is exactly ONE picture of a story at every moment and nothing to hand over at any
        // threshold. That seam, where two renderers disagreed about framing, was `402ec4d`'s bug and
        // the parent of every frozen-cover report since.
        //
        // ⚠️ STAGED OFF THE PULL'S OWN FRACTION NOW, NOT OFF `p` A SECOND TIME. It was
        // `(p - 0.9) / 0.07`, a second hand-drawn curve on the same input, and it only lined up with
        // the card stopping because the old fraction happened to finish at 0.9 as well. The fraction
        // is geometric now and finishes when the sheet does, so a curve on `p` would have started
        // fading the row in while the card was still moving. One progress value, read once, and the
        // staging expressed against it.
        let pull = sheetSizeFraction(p)
        let carIn = max(0, min(1, (pull - 0.88) / 0.12))
        // Feed the row from the LIVE repo (not the viewer's immutable snapshot), so a story
        // deleted while viewing doesn't linger as a ghost card. Fall back to the snapshot.
        let liveMyStories = StoriesRepository.shared.mine?.stories ?? myStories
        ZStack(alignment: .top) {
            MyStoriesCarousel(stories: liveMyStories, activeId: $sheetStoryId,
                              countsTick: countsTick,
                              // THE SAME `pull` THE STAGING ABOVE AND THE LIVE STORY BOTH USE — one
                              // value, computed once in this body, handed to everything that has to
                              // agree about how far the sheet has got. See `sheetSizeFraction`.
                              row: slot.row(fraction: pull),
                              // WHICH OF THE ROW'S ITEMS IS THE LIVE ONE. It is the only thing the
                              // row needs to be told about the story layer: that item hides its own
                              // picture and its placement is handed to the morph instead. Where it
                              // goes is not passed, because the row works that out for this card the
                              // same way it works it out for every other one.
                              liveStoryId: targetStoryId,
                              onActiveTap: { closeViewers() },
                              // THE DEFERRED PAGER JUMP IS SPENT HERE — the row is still now, so
                              // the one story swap the whole movement owes happens at rest. Same
                              // guards as the onChange posts; `sheetStoryId` may have moved past
                              // `id` on a newer gesture, in which case that gesture's own settle
                              // will pay its own debt.
                              onIndexSettled: { id in
                                  guard showViewers, !id.isEmpty, id != currentStoryId,
                                        id == sheetStoryId else { return }
                                  NotificationCenter.default.post(name: .init("jumpToStoryItem"),
                                                                  object: id)
                              },
                              pageDrag: pageDragBox)
                .padding(.top, blockTop)
                .opacity(Double(carIn))
                // ⚠️ `> 0` RATHER THAN `> 0.5`, AND THE 0.19pt THAT BUYS IS A REAL DROPPED TAP.
                //
                // The sheet starts handing touches above it to this band at `progress > 0.95`
                // (`StoryViewersSheetView.hitTest`). With the pull geometric, `carIn > 0.5` is not
                // reached until p = 0.95034 — so for a hair of the gesture the sheet lets a tap
                // through and the carousel refuses it, and a tap that lands there does nothing at
                // all. The two gates have to be on the same side of each other, and the cheap way to
                // guarantee that is for this one to open first and stay open.
                .allowsHitTesting(carIn > 0)
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
        // Neighbour flags for the sheet's horizontal page-swipe (the reference app's sheet-to-sheet slide),
        // in the SAME live order the carousel lays its cards out in, so "next" is the card to the
        // right and never a stale snapshot's idea of it.
        let arr = StoriesRepository.shared.mine?.stories ?? myStories
        let idx = arr.firstIndex { $0.id == sheetStoryId }
        // WHICH TABS A STORY'S VIEWERS LIST GETS, from the same two functions the story's own
        // audience pill reads. BY ID rather than for the active story alone: the sheet holds a real
        // panel per story now, and the one sliding in has to arrive wearing its own audience instead
        // of the audience of the story it is replacing.
        //
        // Hoisted out of the initializer with its type written down, not inlined: this file has cost
        // three builds to the type checker giving up on a long call, and a multi-statement closure
        // returning a labelled tuple inside one is exactly that shape.
        let audienceFor: (String) -> (title: String, bothTabs: Bool) = { id in
            guard let s = arr.first(where: { $0.id == id }) else { return ("All Viewers", true) }
            return (storyAudienceTitle(for: s), storyAudienceHasBothTabs(s))
        }
        return StoryViewersSheet(activeStoryId: sheetStoryId,
                          audienceFor: audienceFor,
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
                                  pageDragBox.value = 0
                                  return
                              }
                              // The drag zeroes IN THE SAME TRANSACTION as the id flip, on the
                              // panel's own 0.28s return curve — the row glides its remaining
                              // distance while the new sheet slides in, one motion.
                              //
                              // ⚠️ THE FLAG THAT USED TO OUTLIVE THIS GESTURE IS DELETED, AND SO IS
                              // THE BUG IT WAS PATCHING.
                              //
                              // `sheetPaging` existed because clearing it one frame into a 0.28s
                              // glide handed the live story back to the slot while the row was still
                              // two thirds of a card off centre, and the cards then slid over the
                              // top of it — his overlapping cards. The whole difficulty was that a
                              // boolean had to describe a MOVEMENT and therefore had to be timed to
                              // match one. Nothing is handed anywhere now: the live story reads the
                              // row's position on every frame of this glide, so the glide needs no
                              // description of itself.
                              // ⚠️ THE DRAG IS DROPPED AT ONCE AND THE ROW SPRINGS ITS OWN VIEWS,
                              // WHICH IS THEIRS AND IS NOT THE SAME AS ANIMATING THE NUMBER.
                              //
                              // This used to animate `pageDragBox.value` to zero over 0.28s in the
                              // same transaction as the id flip. With the row deriving its position
                              // as `scroll - pageDrag`, that is a DISCONTINUITY: the offset moves a
                              // whole card at once while the drag is still two thirds of a card, so
                              // the row jumps backwards by the difference and then glides forwards
                              // again. It was invisible while the row was redrawn from scratch every
                              // frame and it is not invisible now.
                              //
                              // Theirs sets `viewListPanState = nil` — the pan contribution is gone
                              // in one step — raises `isCompletingViewListPan`, and animates the
                              // ITEM POSITIONS over a 0.3s spring. The number is discontinuous and
                              // the pictures are not, which is the only way round that is smooth.
                              // `StoryRowController.setPageDrag` starts that spring when it sees the
                              // drag return to zero.
                              // ⚠️ `commitPage` NO LONGER MOVES THE ROW, AND THAT IS THE 2026-08-17
                              // FIX. It records the story the row is waiting for — theirs is
                              // `animateNextNavigationId = nextItem.id` in the committed branch of
                              // `viewListPanGesture`, which drops neither the pan fraction nor the
                              // scroll offset — and the row seats itself on the ONE pass where that
                              // story's model arrives, which is the same block a tap goes through.
                              // Re-seating here sprang every card once while the live layer was still
                              // the story being left, and the arriving id sprang them again a turn
                              // later: two springs over one set of views for one gesture.
                              let arriving = live[i + d].id
                              pageDragBox.commitPage(toStoryId: arriving)
                              sheetStoryId = arriving
                          },
                          // THE ONLY PER-FRAME WRITE, and it goes to the box, which nothing
                          // subscribes to except the row itself.
                          onPageDrag: { f in
                              // ⚠️ A DRAG THAT IS GIVEN UP DOES NOT TELEPORT THE ROW, AND THE THING
                              // THAT MAKES IT SMOOTH IS THE ROW'S SPRING, NOT AN ANIMATED NUMBER.
                              //
                              // The sheet answers an abandoned page by calling this with 0 and THEN
                              // springing its panel home. Written straight through with the row
                              // drawn from the raw value, the row snapped back in one frame while
                              // the panel was still travelling — two halves of one gesture on two
                              // clocks. That was patched by animating the value itself.
                              //
                              // Theirs does neither: `viewListPanState = nil` drops the contribution
                              // at once and a 0.4s spring carries the item POSITIONS home
                              // (`isCompletingViewListPan`). `StoryRowController.setPageDrag` starts
                              // that spring when it sees the drag return to zero, so the row is
                              // still gliding while the panel is, and there is no animated number in
                              // between for the two to disagree about.
                              // ⚠️ `deliver`, NOT a write to `value` — the row is moved inside this
                              // callback rather than inside the SwiftUI pass the write schedules.
                              // That is their one hop from finger to card; see `rowLink`.
                              //
                              // ⚠️ AND IT IS LABELLED AN ABANDON, WHICH IS THEIR 0.4s RATHER THAN
                              // 0.3s. A zero arriving HERE is always a drag released short — the
                              // commit has its own path above — and theirs deliberately springs a
                              // given-up drag home more slowly than one that meant something. The
                              // label is ignored on the frames of a live drag, which are the
                              // finger's and are never animated.
                              pageDragBox.deliver(f, settle: .abandon)
                          },
                          // A viewer's profile opens in the SAME sheet the story header uses, so
                          // there is one profile screen in this viewer and not two that drift.
                          onOpenProfile: { v in
                              profileSheet = StoryGroup(authorUid: v.id, name: v.name,
                                                        photoUrl: v.photoUrl, stories: [],
                                                        lastViewedAt: nil, isMine: false)
                          },
                          // The tap's slide hint rides the same box the page-drag does — see
                          // `StorySheetPageDrag.pendingSheetSlide`.
                          slideBox: pageDragBox,
                          // THE SHEET'S LIVE LIST. Reading the service's counter HERE is what
                          // subscribes this view to it, so a view landing while the sheet is open
                          // re-renders with a new tick and reaches `Coordinator.refresh` instead of
                          // dying at its `tick != lastTick` guard. The property existed on the sheet
                          // and no caller had ever passed it, so the list was frozen for the whole
                          // sitting. The watcher itself is started and stopped with the sheet, below.
                          refreshTick: StoriesService.shared.viewCountTick)
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
    /// story-card drag, and the list hand-off all end here. The reference app's thresholds, read from
    /// the reference implementation's dismiss-pan handling and converted to our progress
    /// units (their rule is on translation in points, screen-height fractions): close on a
    /// deliberate pull OR a modest flick; anything less springs back open. Their old counterpart
    /// here demanded 80% of the sheet's travel, which is why "scroll down to close is soo hard".
    private func settleViewers(progress p: CGFloat, dragStart: CGFloat, velocityUp: CGFloat) {
        let sheetH = UIScreen.main.bounds.height * StoryViewersSheetView.heightFraction
        let droppedPts = (dragStart - p) * sheetH          // + = dragged toward closed
        let vDownPts = -velocityUp * sheetH                // + = moving toward closed, pt/s
        // The reference app: close if the drag covered ≥30% of the screen, or ≥5% with ≥150pt/s of speed.
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
    /// self-heal) funnels here, and none of them may dismiss the whole viewer. (The reference app's
    /// own close handling does the same check in as many words: list open → hide the list only.)
    /// The story whose view counter is worth following: the one the sheet is showing, and only while
    /// the sheet is up. A listener left running behind a closed sheet is a read charge for a screen
    /// nobody is looking at, which is why this is a sync rather than a start.
    private func syncViewCountWatch() {
        if showViewers, !sheetStoryId.isEmpty {
            StoriesService.shared.watchViewCount(storyId: sheetStoryId)
        } else {
            StoriesService.shared.stopWatchingViewCount()
        }
    }

    private func closeViewers(velocity: CGFloat = 0) {
        // ⚠️ THE DEFERRED JUMP IS SPENT HERE, at the START of the collapse, which is the same beat
        // the reference app builds the player it refused to build while the list was up. The clip loads
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
            // ⚠️ THE ONE PLACE THIS IS STILL WRITTEN BY HAND, AND IT IS KEPT ON PURPOSE.
            //
            // The two handlers that used to write it while the sheet is OPEN no longer do: the
            // ungated item-changed report owns the anchor, and the jump handler fires that report
            // from the statement that swaps the item, synchronously inside this very `post`. So by
            // the time this line runs the anchor is usually already `landing` and this is a no-op.
            //
            // It stays for the one case the report cannot cover. The library's handler refuses a
            // jump to the item it is already on (`idx != getCurrentIndex()`), and it refuses
            // silently — so if the anchor has drifted while the library sits exactly where we are
            // asking it to go, nothing reports and nothing corrects it. Anywhere else that is
            // harmless; here it is not, because this is the collapse, and a stale anchor is the id
            // the row blanks and the id the live card flies home to. The story would grow back to
            // full screen out of the wrong slot with the wrong card blanked.
            //
            // The old reason written here — that `onItemSeen` is withheld while the story is paused
            // — was true and is no longer why. Do not restore the same line to the two open-sheet
            // handlers on the strength of it.
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

        // ⛔ THE HEART IS THE ONLY THING THAT IS A REACTION. Everything else is a message.
        //
        // His 2026-08-18 ruling, and it is the reference app's split: the ❤️ button records on the
        // story's "Seen by" row and stays there; a tap on the react bar, a typed reply, an emoji, any
        // of it, goes to the chat as an ordinary message. "Other reactions or replies should only be
        // sent to the DM and should not replace the Love badge in the viewer sheet."
        //
        // ⚠️ THIS REVERSES HALF OF THE 2026-08-05 RULE AND KEEPS THE OTHER HALF. That day he had the
        // react-bar emojis moved OUT of the chat and into the sheet, and both were treated as one
        // thing from then on. Splitting them is what he is asking for now: the heart alone is a
        // reaction, because the heart alone is the badge the author sees next to a name. An emoji
        // that overwrote it took his ❤️ off the row, which is the "should not replace" in his words.
        //
        // The three doors are told apart by what the library hands over, and nothing else:
        //   • no text, no emoji  → the heart button
        //   • an emoji, no text  → the react bar
        //   • text               → the reply field
        if typed == nil && emoji == nil {
            // Remembered locally so the heart is still red when the story is reopened. Un-liking
            // takes the reaction off the author's row and sends nothing at all.
            StoryPrefs.setStoryLiked(storyId, isLiked)
            if isLiked {
                Task { await StoriesService.shared.setStoryReaction(s, emoji: "❤️") }
                flashSentToast("Reacted")
            } else {
                Task { await StoriesService.shared.clearStoryReaction(s) }
            }
            return
        }

        let text = typed ?? emoji ?? ""
        guard !text.isEmpty else { return }
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
        let faces = barViewers?.recent ?? []
        let total = barViewers?.count ?? 0
        let reactions = barViewers?.reactionCount ?? 0
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
                    if !faces.isEmpty {
                        HStack(spacing: -8) {
                            ForEach(faces) { v in
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
                                     : "\(total) View\(total == 1 ? "" : "s")")
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
    //
    // ⚠️ THIS IS NOT DRAWN BY THIS SCREEN ANY MORE. It is handed to the library and drawn INSIDE my
    // own page, so it turns with the cube instead of sitting flat at the bottom while the story
    // folds away above it — his 2026-08-14 order, and his third report of that bar. What is left
    // here is the CONTENT and the two actions; where it is drawn belongs to the page now. See
    // `StoryDetailView.ownerBar` and `StoryOwnerBarModel`.
    static let ownerFooterHeight: CGFloat = 52
    /// Hand the CURRENT contents of the bar to the page that draws it. Called wherever any of it can
    /// change: a new count landing, the item changing, an upload starting or finishing.
    private func publishOwnerBar() {
        let m = StoryOwnerBarModel.shared
        m.faces = barViewers?.recent ?? []
        m.count = barViewers?.count ?? 0
        m.reactions = barViewers?.reactionCount ?? 0
        let s = currentStory
        m.oneTimeFull = (s?.oneTime ?? false) && s?.recipientsLeft == 0
        m.uploading = isUploadingItem
        m.bottomInset = bottomInset
        m.onViews = { openViewers() }
        m.onDelete = { confirmDelete = true }
        m.onCancelUpload = { uploadSvc.cancelUpload(); onClose() }
    }

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

    /// EVERY ONE OF MY STORIES' COUNTS, IN PARALLEL, THE MOMENT THE VIEWER OPENS.
    ///
    /// His report: open your own story and the footer reads "0 Views" for a second or two before the
    /// real number appears. `ed41361d` stopped that happening on a RE-visit; this is the first visit,
    /// which it deliberately did not cover.
    ///
    /// The fetch used to be one story at a time, started when that story became the current item. So
    /// the first count could not begin until the viewer had opened AND settled on an item, and every
    /// later story paid its own round trip when you reached it. This starts all of them at once, at
    /// the moment the viewer knows the bucket is mine — the same `withTaskGroup` shape the viewers
    /// sheet already uses for its carousel (`loadAll`), pointed at the footer's cache instead.
    ///
    /// Once per session: `myStories` is stable for a viewing and a second sweep would buy nothing.
    ///
    /// ⚠️ THIS SHORTENS THE WAIT, IT DOES NOT REMOVE IT, and the difference matters because he asked
    /// for the reference app's behaviour. The reference app does not fetch a count at all: its own story-list item type
    /// carries `views` (seenCount, reactedCount, a few recent peers) DOWN WITH THE STORY, and the
    /// full list is only requested when you open the list. Ours reads the whole `views` subcollection
    /// — every viewer document, names resolved — to display one number. Matching them properly means
    /// a counter denormalised onto the story doc, which is a server change and the owner's call.
    private func prefetchMyStoryCounts() {
        // `showingMine` for the same first-frame reason as the sheet guards: this runs early, and
        // `currentBucketUid` is not written yet on the opening frame. `prefetchedCounts` latches, so
        // being asked once more later costs nothing — being asked too early and refusing would.
        guard showingMine, !prefetchedCounts else { return }
        prefetchedCounts = true
        let mine = myStories
        guard !mine.isEmpty else { return }
        Task {
            await withTaskGroup(of: (String, StoryViewSummary?).self) { group in
                for s in mine { group.addTask { (s.id, await Self.viewSummary(storyId: s.id)) } }
                for await (id, answer) in group {
                    // No answer leaves whatever the cache already knows on screen. See `viewSummary`.
                    guard let v = answer else { continue }
                    viewersByStory[id] = v
                    countsTick &+= 1
                    // Every one of them, not just the one on screen: this sweep is the cheapest
                    // chance the cache gets to be right about the stories he has not reached yet,
                    // so the NEXT visit opens on a number AND on faces for all of them.
                    StoryCountCache.put(id, count: v.count, reactions: v.reactionCount,
                                        recent: v.recent.map(\.id))
                    // The one on screen paints as soon as ITS answer lands, whichever order they
                    // arrive in — the group is not awaited as a batch for exactly that reason.
                    if id == currentStoryId { barViewers = v; publishOwnerBar() }
                }
            }
        }
    }

    private func loadBarViewers() {
        // ⚠️ CLEARED FIRST, BECAUSE THE OLD ANSWER IS WRONG THE INSTANT THE STORY CHANGES. This only
        // ever ASSIGNED, and only on success — so tapping from a story with 12 views to one with
        // none kept reading "12 Views" with the previous story's avatars for the whole network round
        // trip, then dropped to 0. It leaked the other way too: leave your own bucket for a friend's
        // and come back, and the footer painted with the old bucket's viewers for the first frames.
        // An empty footer for a moment is honest; somebody else's numbers are not.
        guard currentIsMine, !currentStoryId.isEmpty else {
            if barViewers != nil { barViewers = nil }
            return
        }
        let id = currentStoryId
        if lastBarViewersStoryId != id {
            lastBarViewersStoryId = id
            // ⚠️ THIS STORY'S OWN LAST ANSWER, NOT AN EMPTY BAR — the second half of his "the count
            // comes late". Clearing was right about the danger and too blunt about the cure: the
            // rule is that a story must never wear ANOTHER story's numbers, not that it must forget
            // its own. Keyed by id, so it cannot break that rule, and every entry in here was really
            // fetched for really this story.
            //
            // Tapping back and forth through your own stories, and re-opening the viewer, both used
            // to repaint "0 Views" for a Firestore round trip every single time. Now only a story
            // nobody has asked about yet waits, and the refresh below still lands over the top.
            // ⚠️ AND WHEN THIS SESSION HAS NOTHING, THE LAST SESSION'S NUMBER STANDS IN — his
            // 2026-08-14 report: "Views count shows 0 when I first open the story, then updates a
            // few seconds later."
            //
            // `viewersByStory` dies with the viewer, so it only ever helped WITHIN one sitting. The
            // first open of the day therefore always paid a Firestore round trip with "0 Views"
            // painted over the top of it, and 0 is not a neutral placeholder — it is a number, and
            // it is a wrong one. `StoryCountCache` keeps just the two numbers per story on disk, so
            // the count that was true when he last looked is on screen in the first frame and the
            // fetch below only ever corrects it.
            //
            // ⚠️ AND THE FACES COME WITH IT NOW — his 2026-08-16 report, "the viewers' profile
            // avatars appear late". They used to be left out of the cache on purpose, because
            // storing other people's names and photographs was not worth the room. What that missed
            // is that a face is never STORED, it is RESOLVED: the fetch reads uids off the counter
            // document and looks them up in the chat list already in memory. So the cache keeps the
            // three uids, resolves them through the same function the network path uses, and the
            // avatars are on screen in the first frame with nothing written to disk that was not
            // there before. See `StoryCountCache`.
            barViewers = viewersByStory[id] ?? StoryCountCache.summary(for: id)
            publishOwnerBar()
        }
        Task {
            // Nil = the read failed; the cached number stays rather than being overwritten with 0.
            guard let v = await Self.viewSummary(storyId: id) else { return }
            apply(v, for: id)
            // The counter said nobody. Usually true, occasionally a trigger that never ran, so it is
            // checked BEHIND the number rather than in front of it — see `verifiedZero`. Nil leaves
            // what is already on screen alone.
            if v.count == 0, let corrected = await Self.verifiedZero(storyId: id) {
                apply(corrected, for: id)
            }
        }
    }

    /// One place the footer, the cache and the carousel are all told the same number, so a correction
    /// arriving late cannot update one of them and leave the others behind.
    private func apply(_ v: StoryViewSummary, for id: String) {
        viewersByStory[id] = v
        countsTick &+= 1
        StoryCountCache.put(id, count: v.count, reactions: v.reactionCount,
                            recent: v.recent.map(\.id))
        if id == currentStoryId { barViewers = v; publishOwnerBar() }
    }

    /// THE COUNTER FIRST, THE RECEIPTS ONLY IF THERE IS NO COUNTER.
    ///
    /// `stories/{id}/meta/views` is one small document the server keeps, and it is what the reference
    /// app's story object carries down with the story rather than fetching. Every story posted before
    /// that trigger existed has none, and those still count their receipts the old way — so this
    /// answers correctly during the whole changeover and there is no migration to run.
    /// The same question from outside this view — the preview row asks it for every card. One
    /// definition of "how many watched this", so the row's number and the footer's cannot disagree.
    static func viewSummaryPublic(storyId: String) async -> StoryViewSummary? {
        await viewSummary(storyId: storyId)
    }

    /// ⚠️ A ZERO IS NOT EVIDENCE OF ZERO, CHECKED AFTERWARDS RATHER THAN IN THE WAY.
    ///
    /// `stories/{id}/meta/views` is a denormalised counter a server trigger maintains, so it is one
    /// write behind by nature and stays at its initial value for good if that trigger failed, was
    /// deployed after the story was posted, or never ran for it. The receipts underneath are what
    /// somebody watching actually wrote, and they are the truth — which is his "0 above the eye with
    /// a viewer named in the list right below it".
    ///
    /// A missing counter document already falls through to the receipts inside `fetchViewSummary`.
    /// This is the other case: a document that EXISTS and says zero, indistinguishable from "nothing
    /// was ever counted here".
    ///
    /// ⚠️ AND IT RUNS AFTER THE NUMBER IS ALREADY ON SCREEN, NEVER IN FRONT OF IT. Zero is the honest
    /// answer nearly every time, so making every caller wait for a confirmation of it is paying for
    /// the rare case on every single story. Nil means "nothing to correct" — the number already shown
    /// stands.
    static func verifiedZero(storyId: String) async -> StoryViewSummary? {
        guard let receipts = await StoriesService.shared.fetchViewers(storyId: storyId),
              !receipts.isEmpty else { return nil }
        return .counted(from: receipts)
    }

    /// ⚠️ NIL IS "NO ANSWER", NOT "NO VIEWS" — see the guard inside. A caller that cannot tell the
    /// two apart writes a zero over a number that was right.
    private static func viewSummary(storyId: String) async -> StoryViewSummary? {
        // ⚠️ A COUNTER OF ZERO IS NOT EVIDENCE OF ZERO — his 2026-08-18 screenshot, "0" above the
        // eye with one viewer named in the list directly underneath it.
        //
        // These are two different sources and only one of them is the truth. The list reads the
        // RECEIPTS, which are the documents somebody watching actually wrote. This reads
        // `stories/{id}/meta/views`, a denormalised counter a server trigger maintains — so it is
        // one write behind by nature, and a trigger that failed, was deployed late, or never ran for
        // a story posted before it existed leaves the number at its initial value for good.
        //
        // `fetchViewSummary` already answers nil for a MISSING document, which falls through to the
        // receipts correctly. The gap is a document that EXISTS and says zero: indistinguishable
        // from "the trigger never counted anything", and trusted anyway.
        //
        // So zero is the one value that gets checked against the receipts. It is also the one value
        // where checking is free: a story with genuinely no views has no receipts to read either, so
        // the honest case costs an empty query and the broken case gets the right number. Any
        // non-zero counter is still believed and still costs one small document, which is the whole
        // reason the counter exists.
        // ⚠️ ONE ROUND TRIP, ALWAYS. The zero-versus-receipts reconciliation this used to do INLINE is
        // correct and it is now `verifiedZero` below, because doing it here made every caller wait for
        // a second fetch — including `prefetchMyStoryCounts`, which is the sweep that exists to have
        // the numbers ready before he can look at them. That is his "views and trash is coming late"
        // and "eye is working but just appearing late": the fix for a wrong number bought a slow one.
        if let s = await StoriesService.shared.fetchViewSummary(storyId: storyId) { return s }
        // ⚠️ A FAILED RECEIPT READ IS NOT A ZERO. `fetchViewers` answers nil when the request itself
        // failed, and counting nil as an empty list is what wrote "0 views" over a story that had
        // been read correctly a moment before. No answer leaves the previous number where it is.
        guard let receipts = await StoriesService.shared.fetchViewers(storyId: storyId) else { return nil }
        return .counted(from: receipts)
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

    /// THE PEOPLE AFTER ME, so a story opened while it is still posting reaches them like any other.
    ///
    /// This door fed the viewer ONE bucket, so tapping past the last of my items ran out of people
    /// and closed the viewer instead of moving on, and there was nobody to swipe to at all — the
    /// same complaint as the row's door, arriving through the one path that had never been changed
    /// with it. Same list and same order the row's door builds (`MainShell.openStoryFromRow`): me
    /// first, then everyone I have not hidden.
    ///
    /// Nobody else posting leaves this exactly as it was — one bucket, the solo host, today's
    /// behaviour byte for byte.
    private var siblings: [StoryGroup] {
        guard let g = group else { return [] }
        return [g] + repo.others.filter { !StoryPrefs.isHidden($0.authorUid) }
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
            if !siblings.isEmpty {
                // The app's own flight, same as every other story: it grows out of the uploading
                // card and the drag-down flies back into it. `heroSourcePinned` STAYS TRUE even
                // though the viewer can page now: while a post is still in the air the row's only
                // card for me is the uploading placeholder, registered under its own key, so the
                // anchor cannot follow the way the row's door lets it. One card, one landing.
                StoryViewer(groups: siblings, startIndex: 0,
                            heroDismiss: !heroSourceKey.isEmpty,
                            heroSourceKey: heroSourceKey, heroSourcePinned: true,
                            // ⛔ AND THEY REACHED ME, WHICH THIS DOOR NEVER SAID — his "while my
                            // story is uploading, swiping to the next person says You can only reply
                            // to people you chat with, and after the upload the same person lets me
                            // reply".
                            //
                            // `siblings` is `[mine] + repo.others`, and `others` IS the query
                            // "recipientUids contains me" — being in it is the author's own audience
                            // choice, which is the whole reason the row's door passes this. Left
                            // out, `replyLockReason` fell through to `StoryContact.isFriend`, a
                            // second and stricter test of my chat list, and locked the bar.
                            //
                            // ⚠️ NOT A DEMO-ONLY FAULT, though demo people are what makes it show
                            // every time — they are never `isFriend`, so the fallback always
                            // refuses. A real author whose story reached me but who is not in that
                            // list was refused exactly the same way, for as long as an upload was in
                            // flight. Same list, same reasoning, same flag as
                            // `MainShell.openStoryFromRow`; this was the one door never brought
                            // along with it.
                            deliveredToMe: true,
                            onHeroClose: onHeroClose,
                            onClose: onClose, onProfile: onProfile)
                    // ⚠️ NO `.id(svc.uploading)` — THAT WAS THE CLOSE-AND-REOPEN. Re-keying on the
                    // upload flag destroyed and recreated the WHOLE viewer the moment a background
                    // post landed, whatever story he was watching (his 2026-08-09 report: watching A
                    // while C uploads, C finishes, A closes/reopens). The viewer now stays alive and
                    // the placeholder→real swap flows through `reconcileSignature` in StoryViewer —
                    // the reference app's behaviour: a background post is a data update, never a transition.
            } else {
                // Nothing to show (no stories and no upload) → just close.
                Color.clear.onAppear { onClose() }
            }
        }
    }
}

/// WHAT THE OWNER'S BAR SAYS, IN A PLACE THE PAGE CAN READ IT.
///
/// The bar is drawn inside my own story page now, so that it turns with the story instead of sitting
/// flat at the bottom of the screen while the story folds away above it. A page is built ONCE and
/// cached (`StoryPager.makePage`), so anything the injected closure captured at build time would be
/// frozen at build time — the count would never move again. This is the live channel: the viewer
/// writes it whenever any of it changes, the bar observes it, and the page is never rebuilt.
@Observable final class StoryOwnerBarModel {
    static let shared = StoryOwnerBarModel()
    private init() {}
    var faces: [StoryViewerInfo] = []
    var count = 0
    var reactions = 0
    var oneTimeFull = false
    /// The still-uploading placeholder wears the cancel bar instead of the Views bar.
    var uploading = false
    var bottomInset: CGFloat = 0
    var onViews: () -> Void = {}
    var onDelete: () -> Void = {}
    var onCancelUpload: () -> Void = {}
}

/// The bar itself, drawn by the page. Everything it says comes from the model above, which is what
/// keeps it current inside a page nobody rebuilds.
struct StoryOwnerBarView: View {
    @State private var m = StoryOwnerBarModel.shared

    var body: some View {
        Group {
            if m.uploading {
                HStack(spacing: 12) {
                    Button { m.onCancelUpload() } label: { UploadCancelRing(diameter: 28) }
                        .buttonStyle(.plain)
                    Text("Uploading…").font(.subheadline).foregroundStyle(.white)
                    Spacer()
                }
            } else {
                HStack(spacing: 12) {
                    Button { m.onViews() } label: {
                        HStack(spacing: 8) {
                            if !m.faces.isEmpty {
                                HStack(spacing: -8) {
                                    ForEach(m.faces) { v in
                                        AvatarView(name: v.name, photoUrl: v.photoUrl, size: 26)
                                            .overlay(Circle().stroke(.black, lineWidth: 1.5))
                                    }
                                }
                            } else {
                                Image(systemName: m.oneTimeFull ? "1.circle" : "eye")
                                    .font(.subheadline).foregroundStyle(.white)
                            }
                            Text(m.oneTimeFull ? "Once viewer is full"
                                               : "\(m.count) View\(m.count == 1 ? "" : "s")")
                                .font(.subheadline.weight(.medium)).foregroundStyle(.white)
                                .lineLimit(1)
                            if m.reactions > 0 {
                                Image(systemName: "heart.fill").font(.subheadline).foregroundStyle(.red)
                                Text("\(m.reactions)").font(.subheadline).foregroundStyle(.white)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Button { m.onDelete() } label: {
                        Image(systemName: "trash").font(.title3).foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity)
        .frame(height: StoryViewer.ownerFooterHeight)
        .padding(.bottom, max(10, m.bottomInset))
        .background(Color.black)
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
            // Nil is a failed read, not an empty list: leave the list alone and stop the spinner, so
            // the sheet says nothing rather than saying nobody watched. See `fetchViewers`.
            if let v = await StoriesService.shared.fetchViewers(storyId: storyId) { viewers = v }
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
    /// Bumped by the host whenever a story's view counter answers. Drives a re-read of the numbers
    /// on the cards — see the second `.task` below.
    var countsTick: Int = 0
    /// THE ROW'S LAYOUT, OWNED BY THE HOST NOW. It used to be five private formulas down this file,
    /// which was fine while the only thing laid out by them was a card. The live story is laid out
    /// by them too now, so they cannot live where only the cards can see them — see `StoryRowGeometry`.
    let row: StoryRowGeometry
    /// WHICH STORY THE LIVE LAYER IS HOLDING, and therefore the one card that draws no pixels.
    ///
    /// ⚠️ THIS REPLACES `hideActiveContent`, AND THE DIFFERENCE IS THAT IT IS UNCONDITIONAL.
    ///
    /// The old flag was the copy-swap: for the length of a swipe the row drew its own centre card
    /// and the real story was hidden underneath it, because the real story was pinned to the slot
    /// centre and could not follow a moving row. Two renderers for one story, exchanged mid-motion,
    /// which is where the flash, the overlapping cards and the frozen covers all came from.
    ///
    /// The live story slides with the row now, so there is nothing to stand in for and nothing to
    /// exchange. Exactly one view draws a given story at every moment, which is the whole of the
    /// reference app's rule and the reason they have none of these bugs to fix.
    let liveStoryId: String
    var onActiveTap: () -> Void = {}    // tap the centred card → collapse back to full screen
    /// The row's scroll came fully to rest on this story — the host spends the DEFERRED pager jump
    /// here. See `StoryRowController.onIndexSettled`.
    var onIndexSettled: (String) -> Void = { _ in }
    /// The sheet's sideways page-drag, ALREADY IN CARD UNITS — a fraction of the panel's journey,
    /// and one panel journey is one card. It is their `viewListPanState.fraction`, which they add to
    /// the same `offsetFraction` the scroller feeds, and it must not be divided by anything: see the
    /// long note at `onPageDrag` in StoryViewersSheetUIKit for the two builds that got it wrong in
    /// each direction.
    /// ⚠️ `@ObservedObject`, SO THIS IS THE ONLY VIEW A PAGE-DRAG RE-RENDERS. It used to be a plain
    /// `CGFloat` copied down from the host's `@State`, which meant every frame of the drag
    /// invalidated the host's whole body — the pager, the sheet, every overlay — to move this row.
    /// See `pageDragBox` on the host.
    @ObservedObject var pageDrag: StorySheetPageDrag
    // ⚠️ THE FRAME-TICK OBSERVER IS GONE FROM HERE AND LIVES ON THE CARD NOW. It is the nudge that
    // makes a card re-ask for a generated video frame, and observed at this level one clip's frame
    // arriving redrew every card in the row. `StoryRowCardMedia` observes it, so it redraws one.

    /// Per-story numbers, fetched once and then only when the story set changes.
    ///
    /// ⚠️ THE NUMBERS, NOT THE PEOPLE. This was `[String: [StoryViewerInfo]]` and the row derived the
    /// counts from it inside `body` — a dictionary rebuilt, and a `filter` per story, on every pass.
    /// That was free while the only thing that ran a pass was a fetch landing; a sheet page-drag runs
    /// one per frame, so it is not free any more. The people were never used here.
    @State private var counts: [String: StoryRowCounts] = [:]
    // ⚠️ `scroll` IS NOT SWIFTUI STATE ANY MORE, AND THAT DELETION IS THE POINT OF THIS WHOLE MOVE.
    //
    // It was a `@State private var scroll: CGFloat`, written by the scroll view's delegate on every
    // frame of a drag. Every one of those writes invalidated this view, so a swipe rebuilt the entire
    // row's view tree — each card re-asking for its picture, re-applying a clip, a shape, an opacity
    // and a shadow — sixty to a hundred and twenty times a second, to move some views sideways. That
    // is the largest part of the owner's "the swipe is slow and jumpy".
    //
    // The reference app writes `position` and `scale` onto views that already exist, from a function
    // called by the scroll delegate, and rebuilds nothing. `StoryRowController` is that function, and
    // the row's position lives in its scroll view where a position belongs. What is left here is the
    // things that genuinely change at human speed: which card is centred, and the counts.

    /// Which card the row is centred on, reported by the row when it crosses a half-card. It drives
    /// the big count row below the cards and keeps `activeId` in step; it does not move anything.
    @State private var centredIndex = 0

    /// A weak pointer at the row's controller, so the interpolated page-drag can be handed to UIKit
    /// once per frame without going through a SwiftUI update to get there.
    @State private var link = StoryRowLink()

    // ⚠️ `scrollerBusy`, `retargeting` AND `rowBusy` ARE ALL DELETED, AND THE QUESTION THEY ANSWERED
    // NO LONGER EXISTS.
    //
    // "Is the row still moving?" was only ever asked so the host could decide WHICH OF TWO PICTURES
    // of the active story to show: the carousel's own card while anything was in motion, the real
    // story once everything had stopped. Three separate signals fed it — a finger, our own retarget
    // spring, and a fractional-position belt for the paths neither knew about — and it still got the
    // answer wrong twice on device, because a question asked at the wrong instant is wrong however
    // many ways you ask it. His "the window cards are overlapping when I swipe the viewers sheet"
    // was this: the row cards sat exactly where the formula puts them at 0.63 of a card past centre
    // while the card in the slot sat at dead centre wearing the scale of a card 0.37 to the LEFT.
    //
    // Position and scale disagreeing by exactly the page-drag is the signature of a view that is
    // pinned to the slot centre while the row moves around it. The live story is not pinned any
    // more — it is laid out by `StoryRowGeometry` like every other card, from the same row position,
    // in the same frame. There is one picture of a story, it is always in the right place, and there
    // is no moment at which anything has to be swapped for anything. So there is nothing to time.
    //
    // What the row owes the outside world is now one number instead of a boolean: where it is.

    // ⚠️ `publishRowPosition` IS DELETED, WITH THE WIRE IT RAN ON.
    //
    // The row reported its position outward every frame so this view could turn it back into a
    // placement for the live story. That was the SwiftUI half of the two-renderer seam: the row had
    // already computed where every card goes, published a number, and had it computed again by
    // somebody else. The row places the live story itself now, in the same loop, from the same
    // `StoryRowPlacement` — so there is nothing to publish and nobody to publish it to.
    //
    // The guard that used to live here, "the row never drives the fraction to zero", moved with the
    // job into `StoryRowController.placeLiveStory` and inverted: the row is the only writer now, so
    // it has to be the one that puts the story back.

    // `rowPos` lived here, deriving the row's position for the cards to be drawn from. The row
    // derives it inside `StoryRowController.updateScrolling` now, off the same `StoryRowGeometry`,
    // which is what makes it a UIKit layout pass rather than a SwiftUI one.

    /// The card the row is centred on, clamped into the stories it actually has.
    ///
    /// ⚠️ `Int(_:)` TRAPS ON INFINITY AND NaN rather than clamping — the shape of the crash in build
    /// 463 — so the row does the rounding and this only has to defend against a stale index left over
    /// from a story that has since been deleted.
    private var index: Int {
        max(0, min(max(0, stories.count - 1), centredIndex))
    }

    init(stories: [Story], activeId: Binding<String>, countsTick: Int = 0,
         row: StoryRowGeometry, liveStoryId: String,
         onActiveTap: @escaping () -> Void = {},
         onIndexSettled: @escaping (String) -> Void = { _ in },
         pageDrag: StorySheetPageDrag) {
        self.stories = stories
        self._activeId = activeId
        self.countsTick = countsTick
        self.row = row
        self.liveStoryId = liveStoryId
        self.onActiveTap = onActiveTap
        self.onIndexSettled = onIndexSettled
        self._pageDrag = ObservedObject(wrappedValue: pageDrag)
        // Seeded to the opened-on story so the big count row underneath is right on the first frame.
        // The ROW seeds itself from `activeIndex`, which is the same expression — see `StoryRow`.
        self._centredIndex = State(initialValue: stories.firstIndex(where: { $0.id == activeId.wrappedValue }) ?? 0)
    }

    // The settle timer that used to live here is gone: the scroller's own delegate events say
    // exactly when the row has stopped, so the story hand-off no longer waits a guessed beat.

    // The five geometry formulas that used to live here are `StoryRowGeometry` now, unchanged. They
    // moved because the live story is laid out by them too — see that type's note.
    private var slotH: CGFloat { row.slotH }


    var body: some View {
        let focusedID = stories.indices.contains(index) ? stories[index].id : activeId
        let focused = counts[focusedID] ?? .zero
        VStack(spacing: 12) {
            // THE ROW, IN UIKIT — see StoryRowUIKit.swift. What used to be here was a `ZStack` of
            // SwiftUI cards positioned from an `@State` the scroll view wrote on every frame, which
            // is a full body rebuild per frame to move some views sideways. The reference app writes
            // `position` and `scale` onto views that already exist and rebuilds nothing; this is that.
            StoryRow(stories: stories,
                     liveStoryId: liveStoryId,
                     geometry: row,
                     counts: counts,
                     // Only ever read to catch a selection somebody ELSE moved — the sheet paging
                     // sideways, or the row being opened on a story it is not centred on. The row's
                     // own scrolling reports outward and is never told what it already knows.
                     activeIndex: stories.firstIndex(where: { $0.id == activeId }),
                     link: link,
                     // THE SELECTION MOVES DURING THE SCROLL, at the half-card, which is their
                     // `scrollViewDidScroll` navigate. `activeId` is `sheetStoryId` on the host, so
                     // the viewers list and the story behind follow the card you are looking at.
                     onIndexChanged: { i in
                         // Where the sheet currently is, read BEFORE the id moves — the tap's
                         // direction is which side of it the tapped card sits on.
                         let was = stories.firstIndex(where: { $0.id == activeId })
                         centredIndex = i
                         guard stories.indices.contains(i), stories[i].id != activeId else { return }
                         // A TAP PAGES THE VIEWERS LIST, A SCROLL SWAPS IT — both the reference
                         // app's behaviour. The row's pending-tap flag is up exactly while a tap's
                         // navigation is in flight (and never during a drag), so it is the one
                         // honest discriminator. The hint rides the box in the same transaction as
                         // the id and is consumed once by the sheet's sync.
                         if link.tapNavigationPending, let was, was != i {
                             pageDrag.pendingSheetSlide = i > was ? 1 : -1
                         }
                         activeId = stories[i].id
                     },
                     onIndexSettled: { i in
                         guard stories.indices.contains(i) else { return }
                         onIndexSettled(stories[i].id)
                     },
                     onActiveTap: { onActiveTap() })
                .frame(maxWidth: .infinity)
                .frame(height: slotH)
            // The centred card's count, big + centred under the row (mockup).
            countRow(views: focused.views, likes: focused.likes, big: true)
        }
        // ⚠️ THE ONE VALUE SWIFTUI STILL INTERPOLATES BEHIND THE ROW'S BACK.
        //
        // A finger on the row is the row's own scroll view and never comes through here. A finger on
        // the SHEET writes `pageDrag.value` per frame, and the commit and the spring home animate it
        // with `withAnimation` — which does NOT walk the value, it sets it at once and interpolates
        // the rendered attributes. So an `.onChange` would fire once with the destination and the
        // cards would glide while the live story teleported. `Animatable` is the seam SwiftUI gives
        // for reading the interpolated value on each frame, and the row is handed it directly rather
        // than through a state write that would rebuild something.
        // The sheet's drag reaches the row through this, in the pan handler, the way theirs does —
        // see `StorySheetPageDrag.rowLink`. Set here rather than in an initializer because `link` is
        // `@State` and only has its persistent identity once the view is on screen.
        .onAppear { pageDrag.rowLink = link }
        // ⚠️ STILL HERE, AND IT IS NOT A DUPLICATE OF THE DIRECT CALL ABOVE. This is the ANIMATED
        // half: a `withAnimation` write does not walk the value, it sets it at once and interpolates
        // the rendered attributes, so a frame-by-frame readout is the only way to see the
        // in-between values. A finger goes direct; an animation comes through here. Whichever
        // arrives first, `StoryRowController.setPageDrag` ignores the second (`v != pageDrag`).
        .modifier(StoryRowPositionReporter(pageDrag: pageDrag.value) { d in link.setPageDrag(d) })
        // ⚠️ KEYED ON THE STORIES. A bare `.task` runs once per MOUNT and never again, so the counts
        // were fetched once and a story that landed while the sheet was open kept "0" for the rest
        // of the session no matter how many people watched it. `id:` re-runs it when the set
        // changes, which is exactly when the answer it cached stopped being complete.
        .task(id: stories.map(\.id)) { await loadAll() }
        // ⛔ AND AGAIN WHENEVER A COUNT ACTUALLY MOVES — the numbers on these cards used to be a
        // photograph of the moment the sheet opened.
        //
        // The task above is keyed on the story SET, which changes when a story is posted or deleted
        // and at no other time. So somebody watching one of them while he sat looking at the sheet
        // never appeared: the panel's own list followed it (`refreshIfCountMoved`), the little number
        // over the card did not, and the two disagreed on screen.
        //
        // `countsTick` is bumped by the host every time a summary lands from the server's counter
        // document, so this costs nothing until there is real news. Two tasks rather than one
        // compound key: they answer to different things, and either one arriving is a reason to
        // re-read.
        .task(id: countsTick) { await loadAll() }
    }

    // `cardMedia`, `card` and `centreDistance` moved to StoryRowUIKit.swift with the row itself.
    // `cardMedia` is `StoryRowCardMedia` there, unchanged in every branch; the clip and the corner
    // are the card view's; the live story's item hides its own picture, which is the row's decision
    // and lives in the row's loop (`setLive`); and `centreDistance` — which hid a card's own small
    // count as it reached the centre — is two lines inside the layout pass, where it costs an alpha
    // write instead of a SwiftUI geometry read per card per frame.

    // Eye + views + heart + likes, white over a soft shadow — the row's BIG count, under the cards.
    // The small one inside each card is `StoryRowCountView`, in UIKit, because its alpha is written
    // on every frame of a scroll. This one changes when the centred card changes and no faster.
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

    /// ⚠️ THE COUNTER DOCUMENT, NOT EVERY RECEIPT — and the old way was reading the entire viewer
    /// list of EVERY story just to show two integers under each card.
    ///
    /// `stories/{id}/meta/views` is one small document the server keeps for exactly this, and the
    /// story footer has been reading it since it was built (`viewSummary`). This row was still doing
    /// it the pre-counter way: one whole `views` subcollection per story, in parallel, on every open
    /// — and then the sheet's own panel fetched the same subcollections a second time for the list.
    /// For five stories with fifty viewers that is five hundred documents to draw ten digits.
    ///
    /// The receipts remain the fallback for a story posted before the trigger existed, which is what
    /// `viewSummary` already arranges — so this is the same answer, asked the cheap way first.
    ///
    /// ⚠️ AND A FAILED READ LEAVES THE OLD NUMBER ALONE. Nil is "no answer" (see `viewSummary`);
    /// writing a zero for it is how a card that had been counted correctly went back to 0.
    private func loadAll() async {
        await withTaskGroup(of: (String, StoryViewSummary?).self) { group in
            for s in stories { group.addTask { (s.id, await StoryViewer.viewSummaryPublic(storyId: s.id)) } }
            // Reduced to numbers HERE, once per fetch, rather than in `body` once per frame.
            for await (id, answer) in group {
                guard let v = answer else { continue }
                counts[id] = StoryRowCounts(views: v.count, likes: v.reactionCount)
            }
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
                            .foregroundStyle(selected.contains(c.id) ? Color.primary : .secondary)
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
