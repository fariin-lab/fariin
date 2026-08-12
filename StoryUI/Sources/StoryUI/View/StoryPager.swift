//
// Route A: UIKit UIPageViewController pager (replaces the SwiftUI TabView). The dismiss pan is added to
// the pager's OWN scroll view (a real direct subview) with require(toFail:), so cube (sideways) and
// dismiss (down) are mutually exclusive (the same page-controller mechanism). Each page hosts
// the existing SwiftUI StoryDetailView, so all the story logic (progress, reply, tap-advance) is reused.
//
// ⚠️ THE CUBE FOLD LIVES IN `StoryCubePager.swift` NOW, AND NOWHERE ELSE. This header used to say it was a
// `rotation3DEffect` inside StoryDetailView; that was a second implementation, it could not follow a
// finger, and it is deleted. There is also no longer a flat alternative or a setting to choose one:
// the person-to-person turn is the cube, driven by a display link off real layer positions, entered
// either by a finger or by a tap.
//

import SwiftUI
import UIKit

struct StoryPager: UIViewControllerRepresentable {
    @ObservedObject var viewModel: StoryViewModel
    @Binding var isPresented: Bool
    let userClosure: UserCompletionHandler?
    let onProfile: ((StoryUIUser) -> Void)?
    let onItemSeen: ((String) -> Void)?
    /// Ungated "which item is on screen" — see `StoryDetailView.onItemChanged`. Passed straight
    /// through; this pager has no opinion about it.
    let onItemChanged: ((String) -> Void)?
    let showMore: Bool                    // show the header "…" dropdown menu
    let onDragChanged: (CGFloat) -> Void   // overlay fade only; the card itself moves in UIKit (smooth)
    let onCommit: () -> Void               // pulled past threshold -> dismiss
    let onCancel: () -> Void               // released short -> overlays restore
    let onSwipeUp: () -> Void              // up-swipe -> host opens the views sheet
    var onSwipeUpChanged: (CGFloat) -> Void = { _ in }   // LIVE upward drag amount (pts, +up) → real-time open
    var onSwipeUpEnded: (CGFloat, CGFloat) -> Void = { _, _ in }  // (translation +up, velocity +up) on release
    var dismissEnabled: Bool = true        // install the library's native DOWN dismiss pan (smooth UIKit)
    var swipeUpEnabled: Bool = true        // install the library's UP pan (false -> host owns swipe-up)
    /// Install the HOST-DRIVEN down pan instead: it moves nothing itself and decides nothing, it
    /// reports the finger and lets the host animate the card back into whatever it was opened from.
    /// Mutually exclusive with `dismissEnabled` (that one is the library's own shrink-and-melt) and
    /// with the passive watcher (that one exists only to nudge Apple's transition along).
    var heroDismiss: Bool = false
    var onHeroDrag: (StoryHeroPhase, CGPoint, CGPoint) -> Void = { _, _, _ in }   // phase, translation, velocity

    // TRUE while a swipe-down dismiss drag/exit is running. The cube fold derives its angle from
    // each page's position — and the dismiss transform MOVES the card, so a fast flick slammed the
    // pages into a sudden violent fold (content flips away = "wrong story/layout", edge-on =
    // "black frame"). The cube must be inert during dismissal. Read in `applyCube`'s motion test.
    static var dismissActive = false
    // DELETED HERE: `horizontalScroll`. It published the pager's internal scroll view so
    // `StoryDetailView.getAngle` could gate its SwiftUI fold on that scroll being live. `getAngle`
    // is gone (see below), and with it the only reader — the property was left written by two
    // places and read by none, which a `static weak var` will never warn about. `applyCube` asks
    // its own `internalScroll` directly, which it has always had.

    /// ⚠️ DELETED HERE: `PersonTransition`, `personTransition` and `personTurnDuration`.
    ///
    /// The person-to-person turn used to be a SETTING with two implementations behind it — a flat
    /// 100ms `CATransition` push (the default, and so what everybody actually got) and the 3D cube.
    /// Both were kept switchable on his 2026-08-11 instruction, to be compared rather than replaced.
    ///
    /// He compared them on 2026-08-12 and ruled: the cube is the transition, and the flat slide
    /// "should no longer exist anywhere in the person-to-person story transition". So there is one
    /// path now, it is the cube, and there is no flag to read — which also removes the class of bug
    /// where a gate somewhere reads the setting and a gate somewhere else does not.
    ///
    /// The `getAngle` fold in `StoryDetailView` went with it. That was a SECOND cube, in SwiftUI,
    /// 45° off a `GeometryReader`'s `minX` — and a GeometryReader re-evaluates on SIZE, not POSITION,
    /// so it could not follow a finger at all. Two folds on the same pages is what produced the shake.

    /// ⚠️ DELETED HERE: `cubeTurnSpeedup`. It was a `layer.speed` multiplier of 3.0, shortening
    /// `UIPageViewController`'s private turn duration to answer his 2026-08-11 "approximately 0.10
    /// seconds".
    ///
    /// Telegram's peer turn — tap and finger-lift alike, it is literally one code path — settles
    /// over **0.4s on a spring** (`ComponentTransition(animation: .curve(duration: 0.4, curve:
    /// .spring))` in `commitHorizontalPan`, where a tap is a synthesised zero-length pan committed
    /// with velocity ±200). UIKit's own `.scroll` turn runs within a frame or two of that, so the
    /// parity he asked for on 2026-08-12 is simply to leave its clock alone — and a multiplier of
    /// 1.0 is three lines implementing an identity function. See the note at the call site.
    ///
    /// Their number is 0.4s. It is written here rather than declared as a constant because nothing
    /// reads it: a constant with no readers is the same dead state this commit is removing.

    /// ⚠️ DELETED HERE: `cubeTurnActive`.
    ///
    /// It existed to tell `applyCube` that a programmatic turn was moving the pages, because that
    /// fold ran only while UIKit's private scroll view admitted to being dragged and a tap never set
    /// those flags. The container writes every face from its own pan and its own settle now, so
    /// there is nothing to tell: a flag with no readers is exactly the dead state this replacement
    /// removes. `personTurnActive` stays — the TAP still asks it before it moves anybody.

    /// TRUE FOR THE WHOLE OF ANY PROGRAMMATIC PERSON-TO-PERSON TURN — cube or flat — and it is what
    /// the TAP asks before it moves anybody (`StoryDetailView.updateStory`).
    ///
    /// His 2026-08-12 report: tapping the right side repeatedly during a cube turn kept navigating
    /// and then "suddenly takes me back to the story I had already left". Refusing the SYNC mid-turn
    /// (`isTurning`, which this mirrors) was never enough, because the page being left is still on
    /// screen for the length of the turn and still answers taps — and `getNextStory` computes the
    /// destination from ITS OWN position, so a late tap on the departing page writes "the person
    /// after ME", which is the person you have already gone past. That is the bounce.
    ///
    /// So a tap during a turn is DROPPED, not queued: his rule, and the reference app's shape too — its
    /// peer move runs through one commit whose settle owns the screen until it lands.
    ///
    /// ⚠️ IT MUST NEVER STRAND TRUE or tapping stops working for the rest of the viewer's life. It
    /// is written in exactly the three places `isTurning` is, and cleared again when a pager is
    /// built — the same belt `dismissActive` has.
    static var personTurnActive = false

    func makeUIViewController(context: Context) -> StoryPagerHostVC {
        StoryPager.dismissActive = false   // fresh viewer never inherits a stale flag
        StoryPager.personTurnActive = false
        // ⚠️ NO UIPageViewController. See `StoryCubePager.swift` — the fold is ours now, driven by
        // one pan and one number, which is what makes the finger move it and what removes the
        // model-versus-presentation disagreement that flashed at the end of every turn.
        let pager = StoryCubePagerVC()
        pager.dataSource = context.coordinator
        pager.delegate = context.coordinator
        // Its own `viewDidLoad` paints the black and sets the corner curve — the same two lines this
        // used to do here, moved so a container built anywhere is born correct.
        context.coordinator.pager = pager
        if let first = context.coordinator.makePage(for: viewModel.currentStoryUser) {
            pager.loadViewIfNeeded()
            pager.setFocused(first)
        }
        // BORN INVISIBLE for a hero open — see StoryCardMorph.heroOpenPending. Set here, in
        // `makeUIViewController`, because this is the last synchronous moment before the first
        // paint; anything later is a frame too late and the frame is the bug.
        if heroDismiss {
            pager.view.alpha = 0
            StoryCardMorph.shared.revealAfterHeroOpen = { [weak pager] in pager?.view.alpha = 1 }
            // REGISTERED HERE, NOT WHERE THE PAN IS INSTALLED, and the difference is a real bug that
            // was in this file for about ten minutes. `installDismissPan` attaches the card BEFORE
            // it installs the pan, and attaching the card is what fires the host's staged open — so
            // hooks registered next to the pan would still be nil at the one moment the open needs
            // them, and the story would grow out of the row on a full black screen.
            StoryCardMorph.shared.prepareForHero = { [weak pager] in pager?.view.backgroundColor = .clear }
            StoryCardMorph.shared.restoreAfterHero = { [weak pager] in pager?.view.backgroundColor = .black }
            // A story nobody can see is worse than an open with no animation. If the host has not
            // claimed the card by now, something upstream is wrong and the story is shown as it is.
            //
            // 0.6s, and it MUST stay behind the host's own ceiling (`stageHeroOpen`, ~0.55s) or this
            // reveals the story at full size while the host is still waiting for the geometry to fly
            // it — which is the pop the host's patience exists to prevent, arriving from underneath.
            // Faded, not flipped: this path only runs when something has gone wrong, and a soft
            // arrival is a better wrong answer than a bang.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak pager] in
                guard let pager, pager.view.alpha == 0 else { return }
                UIView.animate(withDuration: 0.18) { pager.view.alpha = 1 }
            }
        }
        // ⚠️ DO NOT CALL `installDismissPan` SYNCHRONOUSLY HERE. It was tried on 2026-08-08
        // (`261043f`), to save the runloop hop the open spends waiting for this card, and it cost the
        // person-to-person swipe: it ran `neutralizePagerScrollIfHostOwnsSwipe` before `startStory`
        // had populated the view model, so a friend's bucket read as a single bucket and the 3D swipe
        // was switched off for the whole session. It was reverted in `7e313b2`.
        //
        // The neutralise is symmetric now and would recover on the next update, so this is no longer
        // a trapdoor — but the call bought exactly one runloop turn, and that is not worth a second
        // unknown in a gesture that has now had to be reported three times.
        DispatchQueue.main.async { context.coordinator.installDismissPan() }
        return StoryPagerHostVC(pager: pager)
    }

    func updateUIViewController(_ host: StoryPagerHostVC, context: Context) {
        context.coordinator.syncIfNeeded()
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    // CADisplayLink retains its target (the coordinator), and the run loop retains the link, so deinit
    // never runs on its own -> leak + a per-frame wakeup that lives forever. Tear it down explicitly when
    // SwiftUI dismantles the representable (story closed).
    static func dismantleUIViewController(_ host: StoryPagerHostVC, coordinator: Coordinator) {
        // (The fold's display link went with the container — `StoryCubePagerVC` owns its own settle
        // link and invalidates it in its own `deinit`. There is nothing here to tear down any more.)
        // ⚠️ AND EVERY TURN FLAG COMES DOWN WITH THE VIEWER, WHICH IS THE ONE PLACE THEY COULD NEVER
        // COME DOWN BEFORE.
        //
        // All three are cleared only inside `setViewControllers`' completion. Close the viewer mid-
        // turn — a swipe-down commit, a host close, `isPresented` flipping during the ~0.4s turn —
        // and that completion never runs, so they strand for the life of the PROCESS. They are
        // statics, so the damage lands on the next viewer: `personTurnActive` makes
        // `StoryDetailView.updateStory` drop every tap, and a stranded `cubeTurnActive` pins
        // `applyCube`'s motion gate true so the pages can never be put back flat.
        //
        // `makeUIViewController` already clears them, which healed a FRIENDS viewer and never healed
        // the own-story one — `StorySoloPager` builds no pager and so never ran that line. Clearing
        // on the way out covers both, because every viewer goes through some teardown.
        //
        // ⚠️ `heroDismissActive` IS **NOT** CLEARED HERE, and that is a deliberate refusal rather
        // than an omission. The hero OPEN raises it, and SwiftUI dismantles this representable AFTER
        // building its replacement — the lesson written seven lines below about `detach`. So a
        // teardown landing after the NEXT viewer's open flight had started would zero the flag
        // during the very flight it exists to freeze, which is a worse bug than the one it would
        // fix. The other three are safe on that ordering because nothing raises them at creation:
        // they are raised by a turn, which cannot have happened yet.
        StoryPager.personTurnActive = false
        StoryPager.dismissActive = false
        // The card is going away. Leaving a stale transform on a recycled view would open the next
        // story already shrunken, and the reference is weak but the MASK is not: detach clears both.
        //
        // ITS OWN container is passed, not a bare call: SwiftUI dismantles this one AFTER building
        // its replacement, so an unconditional detach here cleared the NEW viewer's binding. See
        // StoryCardMorph.detach. (The container, not the scroll view — see the note at the attach.)
        StoryCardMorph.shared.detach(host.cardContainer)
    }

    /// The reference app's perspective depth, its constant.
    static let cubePerspective: CGFloat = 500.0

    /// ⚠️ THE TERM OURS WAS MISSING, AND THE REASON THE PAGES CAME OUT THE WRONG SIZE.
    ///
    /// The reference implementation reads its width-class metric and uses **40 on compact (every
    /// iPhone)**, 0 only on regular (iPad). Ours had no such term at all, and the note that used to
    /// sit here said "sideAngle = 0" as though that were a simplification. It is not a
    /// simplification, it is the iPad branch: put `sideDistance = 0` into its formula and
    /// `sideAngle` collapses to zero, `backDistance` collapses to zero, and what is left reduces
    /// algebraically to exactly the transform we shipped. The cube on his phone was the reference
    /// app's iPad cube.
    ///
    /// What the term buys is where the two faces meet. At `sideAngle = 0` they meet at a right angle
    /// on the screen edge, so a turning face is projected larger than its page and the incoming one
    /// arrives undersized — his "incorrect sizing". At 40 the join stands 40pt inside the screen and
    /// both faces are drawn at the size the page actually is.
    /// 40, flat: the reference app's compact-width value, and this app is an iPhone app. Its
    /// regular-width (iPad) value is 0 — which is the branch we were accidentally running. Kept as a named constant
    /// rather than read from `UIDevice` so this stays callable from anywhere without an actor hop.
    static let cubeSideDistance: CGFloat = 40

    /// The closed form for that angle, theirs verbatim. It answers "how far must a face be turned so
    /// its edge lands `sideDistance` inside the screen under a 500pt perspective", and it is not
    /// something to tidy up by eye — every term carries.
    static func cubeSideAngle(width w: CGFloat, sideDistance s: CGFloat) -> CGFloat {
        let p = cubePerspective
        let c = sqrt(-pow(p, 2) * pow(s, 2) + pow(p, 2) * pow(w, 2) + pow(s, 2) * pow(w, 2)
                     + s * pow(w, 3) + 0.25 * pow(w, 4))
        let a = 2.0 * p * w - 2.0 * c
        let b = -2.0 * p * s + 2.0 * s * w + pow(w, 2)
        guard b != 0 else { return 0 }
        return 2.0 * atan(a / b)
    }

    /// The reference implementation's cube-transform function, ported whole. t in [-1, 1]: 0 = flat
    /// centre, ±1 = edge-on. The face push (+w/2 in z) is the reference implementation's
    /// face-transform value, set on the CONTENT view while the cube goes on its parent; concatenating it first here is the same
    /// composition on one layer, and it is what makes the centred page sit at exactly full size.
    static func cubeTransform(_ t: CGFloat, width w: CGFloat) -> CATransform3D {
        let tc = max(-1, min(1, t))
        let absT = abs(tc)
        let sideAngle = cubeSideAngle(width: w, sideDistance: cubeSideDistance)
        // ⚠️ THE TURN IS WIDER THAN A RIGHT ANGLE. A cube whose faces stand off the screen edge has
        // to rotate past 90° to bring the next one square to the camera.
        let currentAngle = tc * (.pi / 2 + sideAngle)
        let cubeDistance_a = -1.4142135623731 * absT * cos(sideAngle + 0.785398163397448)
        let cubeDistance_b = sin(sideAngle * absT + 1.5707963267949 * absT + 0.785398163397448)
        let cubeDistance = 0.5 * w * (cubeDistance_a + absT + 1.4142135623731 * cubeDistance_b - 1.0)
        let backDistance = w / 2.0 + w * (tan(sideAngle) / 2.0) - w / (2.0 * cos(sideAngle))
        var perspective = CATransform3DIdentity
        perspective.m34 = -1.0 / cubePerspective
        var target = CATransform3DTranslate(perspective, 0, 0, -w * 0.5)
        target = CATransform3DTranslate(target, 0, 0, -cubeDistance + backDistance)
        target = CATransform3DConcat(CATransform3DMakeRotation(currentAngle, 0, 1, 0), target)
        target = CATransform3DTranslate(target, 0, 0, -backDistance)
        let face = CATransform3DMakeTranslation(0, 0, w * 0.5)
        return CATransform3DConcat(face, target)
    }

    final class Coordinator: NSObject, StoryCubePagerDataSource, StoryCubePagerDelegate, UIGestureRecognizerDelegate {
        let parent: StoryPager
        weak var pager: StoryCubePagerVC?
        // `dismissBackdrop` + `dismissBlur` stood here: a stationary blurred copy of the story meant
        // to be revealed behind the card during a swipe-down. DEAD SINCE THE DISMISS WAS REBUILT —
        // nothing ever assigned the image view a picture, and both were hidden at install and hidden
        // again on every pan `.began`, so what they actually did was add a permanently invisible
        // `UIVisualEffectView` to the pager for the app to composite. Removed with the rest of the
        // blur system; what pulls away now is the card, over the live chat list, as below.
        private var didInstallPan = false

        /// ⚠️ A PROGRAMMATIC PAGE TURN IS IN FLIGHT. Without this the app CRASHES — his
        /// `Kulan-2026-08-10-114950.ips`, build 520, `SIGABRT` from a UIKit assertion:
        /// `-[UIPageViewController _flushViewController:animated:]` ← `_UIQueuingScrollView
        /// _replaceViews:updatingContents:` ← `_scrollViewAnimationEnded:`.
        ///
        /// `UIPageViewController` cannot be told to change pages while it is already changing them.
        /// Its queuing scroll view flushes the outgoing controller when the animation ends, and if a
        /// second `setViewControllers` has replaced the queue in the meantime, that flush asserts.
        /// Apple state the constraint plainly; we were simply not honouring it.
        ///
        /// `syncIfNeeded` runs from `updateUIViewController`, so it fires on EVERY SwiftUI update.
        /// Tap forward to the next person and then again before the ~0.3s slide has landed — which is
        /// ordinary use, not abuse — and the second call arrives mid-transition.
        private var isTurning = false
        /// A sync that arrived while a turn was in flight. Dropping it outright would leave the pager
        /// showing one person while the view model names another, so it is replayed once the turn
        /// lands. The replay is cheap and self-terminating: `syncIfNeeded` returns immediately once
        /// the shown page already matches.
        private var syncPending = false
        /// Whether the passive watcher has already told the host it is past the fade threshold. One
        /// report per crossing, not one per frame — see `handleDismissWatch`.
        private var watchDragPastThreshold = false
        private weak var dismissPan: DirectionalPanGestureRecognizer?   // ours — system pans defer to it
        /// EVERY down pan this coordinator installed. `dismissPan` names only the newest one and the
        /// passive watcher is never assigned to it at all — see `gestureRecognizerShouldBegin`.
        /// Weak boxes: the views own the recognisers, and this must not be why one outlives its view.
        private var ourDownPans: [() -> UIGestureRecognizer?] = []

        /// Is the reply keyboard up? Watched here rather than asked of `KeyboardManager`, which is a
        /// `@StateObject` owned by each page and not reachable from the pager. Selector observers,
        /// so they are removed for us when this coordinator goes.
        private var keyboardUp = false

        @objc private func keyboardShown() { keyboardUp = true }
        @objc private func keyboardHidden() { keyboardUp = false }
        // Baseline translation captured the instant the swipe-UP pan engages. The recognizer only
        // begins after the finger has already travelled ~its 8pt threshold plus whatever it moved
        // while the competing pans were failing — so translation(in:) is already ~30-40pt at the
        // first .changed. Reporting that raw value made the card JUMP ~5% the moment the sheet
        // engaged (user's red-border test: a 12px snap at t=0.94). Subtracting this baseline makes
        // the drag start from ZERO at engagement, so the card tracks smoothly from full size.
        private var swipeUpBaselineY: CGFloat?

        init(_ parent: StoryPager) { self.parent = parent }

        private func index(of id: String) -> Int? {
            parent.viewModel.stories.firstIndex { $0.id == id }
        }

        /// Pages already built, by bucket id. See `makePage`.
        private var pageCache: [String: StoryPageHostVC] = [:]
        /// What each cached page was built against, PER BUCKET.
        private var pageSignatures: [String: String] = [:]

        /// ⚠️ ONE BUCKET'S SHAPE, NOT THE WHOLE VIEWER'S — and this is why tapping to the next person
        /// was sometimes fast and sometimes not.
        ///
        /// `StoryUIModel` is a struct, so a cached page holds a SNAPSHOT of its bucket: post a story,
        /// delete one, or have the row re-sort, and that page would keep showing the old set. The
        /// cheap way to notice was to hash EVERY bucket and every story in the viewer and throw the
        /// WHOLE cache away when any of it moved.
        ///
        /// The trouble is what makes it move. A story landing anywhere in the row, a delete, a
        /// refresh — any of those changed the signature, and the next tap then rebuilt a
        /// `StoryDetailView` and a hosting controller synchronously, before the page turn could even
        /// begin. That is the third of the delay `makePage` was written to remove, coming back
        /// through the door the invalidation left open, at a moment nobody could predict.
        ///
        /// Per bucket, only the bucket that actually changed is rebuilt. The staleness guarantee is
        /// unchanged — a page whose own stories moved is still thrown away — it just stops taking
        /// everybody else's page with it.
        private func bucketSignature(_ id: String) -> String {
            guard let idx = index(of: id) else { return "" }
            let m = parent.viewModel.stories[idx]
            return "\(m.id):\(m.stories.map(\.id).joined(separator: ","))"
        }

        /// A page per bucket, BUILT ONCE.
        ///
        /// It used to construct a whole new `StoryDetailView` and a whole new hosting controller on
        /// every call — and `syncIfNeeded` calls it on every tap-advance, synchronously, before the
        /// page transition can even start. A swipe never paid that: `viewControllerBefore/After` let
        /// UIKit build the neighbour ahead of time. That asymmetry is why swiping felt right and
        /// tapping felt slow, and it was roughly a third of the delay.
        ///
        /// Bounded to the current page and its immediate neighbours, so a long story row cannot turn
        /// this into a pile of live hosting controllers.
        func makePage(for id: String) -> StoryPageHostVC? {
            guard let idx = index(of: id) else { return nil }
            let signature = bucketSignature(id)
            if let hit = pageCache[id], pageSignatures[id] == signature { return hit }
            // This one is stale (or new): drop only it.
            pageCache.removeValue(forKey: id)
            pageSignatures[id] = signature

            let model = parent.viewModel.stories[idx]
            let root = StoryDetailView(
                viewModel: parent.viewModel,
                model: model,
                isPresented: parent.$isPresented,
                userClosure: parent.userClosure,
                onProfile: parent.onProfile,
                onItemSeen: parent.onItemSeen,
                onItemChanged: parent.onItemChanged,
                showMore: parent.showMore
            )
            let vc = StoryPageHostVC(rootView: root)
            vc.bucketID = id
            pageCache[id] = vc
            trimCache(around: idx)
            return vc
        }

        /// Keep the current page and one either side. NEVER drop something the pager is showing —
        /// a UIPageViewController holds its visible controllers as children, and pulling one out
        /// from under it is how you get a blank page.
        private func trimCache(around idx: Int) {
            let live = Set((pager?.children ?? []).compactMap { ($0 as? StoryPageHostVC)?.bucketID })
            let keep = Set((max(0, idx - 1)...min(parent.viewModel.stories.count - 1, idx + 1))
                .compactMap { parent.viewModel.stories.indices.contains($0) ? parent.viewModel.stories[$0].id : nil })
            for (key, _) in pageCache where !keep.contains(key) && !live.contains(key) {
                pageCache.removeValue(forKey: key)
                pageSignatures.removeValue(forKey: key)
            }
        }

        // Keep the visible page synced if currentStoryUser changes from outside the pager (e.g. tap-advance
        // off the end of a bucket sets the next user).
        // Own story (host owns the swipe): fully neutralize the pager's internal scroll so its
        // horizontal pan/bounce can't fight the host's vertical dismiss drag (the shaky double-image).
        func neutralizePagerScrollIfHostOwnsSwipe() {
            // ⚠️ ONE SWITCH ON A PAN WE OWN, WHICH IS THE WHOLE POINT OF THE REPLACEMENT.
            //
            // This used to reach into `UIPageViewController`'s private scroll view and turn its pan,
            // its bounce and its scrolling off. That is how the person-to-person swipe kept dying:
            // the fold was gated on that same scroll view reporting itself as tracking, so anything
            // that switched it off also switched the cube off, and the app has now had that bug
            // three separate times with a different flag holding the switch each time.
            //
            // The two conditions are unchanged and both are still right. A single bucket has nobody
            // to turn to. And while the viewers sheet is up nobody may turn a page at all — the
            // sheet shrinks the story by holding a transform on the card, and a turn started under
            // a shrunken card was the shape that crashed build 481.
            //
            // Re-asserted on every update, as before, so it can never be left in the wrong state.
            guard let pager else { return }
            let sheetUp = StoryCardMorph.shared.sheetFraction > 0.001
            let single = parent.viewModel.stories.count <= 1
            pager.swipeEnabled = !single && !sheetUp
        }

        func syncIfNeeded() {
            neutralizePagerScrollIfHostOwnsSwipe()   // re-assert on every update
            guard let pager else { return }
            let shown = (pager.focused as? StoryPageHostVC)?.bucketID
            // Initial population: stories/currentStoryUser weren't ready at makeUIViewController time
            // (startStory runs in .onAppear, after), so the pager came up empty -> black. Fill it now.
            if shown == nil {
                if let first = makePage(for: parent.viewModel.currentStoryUser) {
                    pager.setFocused(first)
                    // The FIRST advance is the one that used to be slowest, because nothing had been
                    // asked for yet. Warm the neighbours from the moment the viewer has a page.
                    prewarmNeighbours(of: parent.viewModel.currentStoryUser)
                }
                return
            }
            // Already showing the person we were asked for: nothing to do, and that is not a failure.
            guard shown != parent.viewModel.currentStoryUser else { return }
            // ⚠️ A LOOKUP THAT FAILS MUST NOT RETURN QUIETLY. THAT SILENCE IS THE BLACK SCREEN.
            //
            // These three used to sit in one `guard ... else { return }`, so a person who could not
            // be located left the container holding whatever it was holding — which, mid-advance, is
            // nothing. His report: black for a second, then his own story back again when a later
            // update repopulated from `currentStoryUser`.
            //
            // Their `StoryContainerScreen.navigate(direction:)` has no such state: asked for a next
            // peer that does not exist, they `controller.dismiss()`. Running out of people is a real
            // outcome with a real ending; being unable to name one is not a reason to show a void.
            guard let from = index(of: shown!),
                  let to = index(of: parent.viewModel.currentStoryUser),
                  let target = makePage(for: parent.viewModel.currentStoryUser)
            else {
                // Keep the person the container is actually showing as the truth, so the viewer is
                // consistent rather than merely still on screen. If even that is gone, close.
                if let shown, index(of: shown) != nil {
                    parent.viewModel.currentStoryUser = shown
                } else {
                    parent.isPresented = false
                }
                return
            }
            // ⚠️ THE WARM WAITS FOR THE TURN TO FINISH. It used to start one runloop after the
            // transition began, which is DURING it — and laying out a SwiftUI story page is not
            // cheap, so it spent main-thread time on the person after next while the person you
            // asked for was still arriving.
            // ⚠️ NEVER TWO TURNS AT ONCE, AND NEVER OVER THE TOP OF A FINGER. `isActive` is the
            // container's own answer — a finger down or a settle running — and it replaces asking a
            // scroll view we no longer have whether it was tracking.
            if isTurning || pager.isActive {
                syncPending = true
                return
            }
            let next = parent.viewModel.currentStoryUser
            isTurning = true
            // The tap's lock, raised with the sync's — see `StoryPager.personTurnActive`.
            StoryPager.personTurnActive = true
            // ⚠️ ONE PATH. THE CUBE IS THE PERSON-TO-PERSON TURN — his 2026-08-12 ruling, after
            // comparing it against the flat slide that used to be the default here.
            //
            // Deleted with the branch: a `CATransition` push that animated the CONTAINER's rendered
            // content. That is why it could never be folded — the pages never moved individually, so
            // there was nothing for a cube to derive an angle from, and the two could not be made
            // into one thing however the setting was written.
            //
            // This hands the turn to `UIPageViewController`'s own animated move, which is exactly
            // what the fold needs: the pages travel by FRAME, so every page's origin genuinely
            // moves and the display link has real positions to read — the same input a finger gives
            // it. One fold, two drivers, no flag.
            // ⚠️ ONE PATH, AND IT IS THE SAME ONE THE FINGER TAKES. A neighbour is reached with
            // `navigate`, which is their `navigate(direction:)`: a synthesised zero-length pan
            // committed at ±200, settling over 0.4s on the sampled spring. Anything further away is
            // not a turn at all — there is no cube between two people who are not adjacent — so it
            // is placed without animation rather than pretending.
            let neighbour: StoryCubePagerVC.Direction? = to == from + 1 ? .next : (to == from - 1 ? .previous : nil)
            let land: () -> Void = { [weak self] in
                        StoryPager.personTurnActive = false
                guard let self else { return }
                // ⚠️ `isTurning` COMES DOWN HERE AND NOWHERE EARLIER. It is tied to the real end of
                // the turn, never to a duration we guessed.
                self.isTurning = false
                self.prewarmNeighbours(of: next)
                self.replayPendingSync()
            }
            pendingLanding = land
            if let neighbour, pager.navigate(neighbour) { return }
            // Not adjacent, or the container had nobody that way: place it and land immediately.
            pager.setFocused(target)
            pendingLanding = nil
            land()
        }

        /// What to run when the container reports its turn has landed. Held here because the settle
        /// belongs to the container and the bookkeeping belongs to this coordinator.
        private var pendingLanding: (() -> Void)?

        /// Re-run a sync that was refused mid-turn, one runloop later.
        ///
        /// The hop is deliberate: this is called from inside `setViewControllers`' completion and
        /// from `didFinishAnimating`, and UIKit is still unwinding its own transition bookkeeping at
        /// both of those points. Starting the next turn from inside the previous one's teardown is a
        /// smaller version of the very thing that crashed.
        private func replayPendingSync() {
            guard syncPending else { return }
            syncPending = false
            DispatchQueue.main.async { [weak self] in self?.syncIfNeeded() }
        }

        /// BUILD **AND LAY OUT** THE PEOPLE EITHER SIDE, BEFORE THE FINGER ASKS FOR THEM.
        ///
        /// His 2026-08-08: "make the transition from tapping a story to the next person much
        /// faster… reduce the overall delay, including the page transition and any delay caused by
        /// loading/building the next story."
        ///
        /// `makePage` already stopped rebuilding a page per tap, which was about a third of it. What
        /// a cached page had NOT paid for is its first LAYOUT: it was constructed and then parked, so
        /// the whole SwiftUI body — the GeometryReader, the card, the overlays, the image view — was
        /// still evaluated on the main thread at the moment it was handed to the pager, which is
        /// inside the tap. Laying it out here moves that work into the seconds he spends watching the
        /// current story, where nothing is waiting on it.
        ///
        /// It also starts that page's image load, because `StoryImage.task` runs once the view is
        /// laid out — so the next person's first frame is usually decoded before he ever asks for it.
        /// That is the same reasoning as `prefetchAhead`'s flattened list, one layer further in.
        ///
        /// ⚠️ LAYOUT ONLY, NEVER PARENTED. A page added to the hierarchy would run `onAppear`, start
        /// its timer and mark its first story SEEN — a person he never watched. `layoutIfNeeded` on a
        /// detached view does the work without any of that.
        private func prewarmNeighbours(of id: String) {
            guard let pager, let idx = index(of: id), pager.view.bounds.width > 1 else { return }
            let bounds = pager.view.bounds
            // Next runloop: the transition that just started owns this one, and stealing main-thread
            // time from it would trade a faster arrival for a jerkier animation.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                for off in [1, -1] {
                    let j = idx + off
                    guard self.parent.viewModel.stories.indices.contains(j) else { continue }
                    guard let vc = self.makePage(for: self.parent.viewModel.stories[j].id),
                          vc.parent == nil, vc.view.superview == nil else { continue }
                    vc.view.frame = bounds
                    vc.view.layoutIfNeeded()
                }
            }
        }

        func cubePager(_ pager: StoryCubePagerVC, pageBefore vc: UIViewController) -> UIViewController? {
            guard let cur = (vc as? StoryPageHostVC)?.bucketID, let i = index(of: cur), i > 0 else { return nil }
            return makePage(for: parent.viewModel.stories[i - 1].id)
        }
        func cubePager(_ pager: StoryCubePagerVC, pageAfter vc: UIViewController) -> UIViewController? {
            guard let cur = (vc as? StoryPageHostVC)?.bucketID, let i = index(of: cur),
                  i < parent.viewModel.stories.count - 1 else { return nil }
            return makePage(for: parent.viewModel.stories[i + 1].id)
        }

        /// A turn is starting, by finger or by tap. The tap's lock goes up for BOTH now, which it
        /// could not before: an interactive swipe never went through the programmatic path, so a tap
        /// landing mid-swipe passed every guard and named "the person after ME" — the page being
        /// left. That is his bounce report, and it is closed by there being one path.
        func cubePagerWillBeginTurn(_ pager: StoryCubePagerVC) {
            StoryPager.personTurnActive = true
        }

        func cubePager(_ pager: StoryCubePagerVC, didSettleOn vc: UIViewController, committed: Bool) {
                StoryPager.personTurnActive = false
            // A turn this coordinator asked for finishes its own bookkeeping first.
            if let landing = pendingLanding {
                pendingLanding = nil
                landing()
                return
            }
            isTurning = false
            // ⚠️ THE TURN IS OVER WHETHER OR NOT IT COMMITTED, so the pending replay is released
            // either way. A swipe somebody changed their mind about still ends a turn, and a sync
            // refused during it must not be stranded — that is how the pager ends up showing one
            // person while the view model names another.
            defer { replayPendingSync() }
            guard let cur = (vc as? StoryPageHostVC)?.bucketID else { return }
            // ⚠️ A CANCELLED SWIPE DROPS THE QUEUED TURN INSTEAD OF SPENDING IT. A tap that landed
            // mid-drag computes "the person after ME" and parks in `syncPending`; releasing below
            // the threshold springs back, and replaying that queued sync would then move anyway —
            // the bounce report in a different costume.
            if !committed {
                syncPending = false
                if parent.viewModel.currentStoryUser != cur { parent.viewModel.currentStoryUser = cur }
                return
            }
            parent.viewModel.currentStoryUser = cur   // StoryView's onChange fires onUserChanged
            prewarmNeighbours(of: cur)
        }

        // MARK: dismiss pan (down only) + require-to-fail on the pager's own scroll

        func installDismissPan() {
            NotificationCenter.default.addObserver(self, selector: #selector(keyboardShown),
                                                  name: UIResponder.keyboardWillShowNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(keyboardHidden),
                                                  name: UIResponder.keyboardWillHideNotification, object: nil)
            guard !didInstallPan, let pager else { return }
            didInstallPan = true
            // The pan is created with the view, so make sure there IS one before anything is made to
            // wait on it.
            pager.loadViewIfNeeded()
            // ⚠️ THE SCROLL-VIEW LOOKUP THAT USED TO BE HERE IS GONE, AND WITH IT A WHOLE FAILURE
            // MODE. It hunted `pager.view.subviews` for `UIPageViewController`'s private scroll
            // view, retried twenty times when it was not built yet, and set `didInstallPan` before
            // it knew it had anything — so a miss meant the morph silently did nothing for the whole
            // session and the viewers sheet came up over a story that never shrank. There is no
            // private view to find any more: the pan is ours and it exists as soon as the container
            // does.
            neutralizePagerScrollIfHostOwnsSwipe()
            // DOWN dismiss pan (native UIKit — smooth). Installed for BOTH own and friends now, so the
            // own-story swipe-down uses the exact same buttery pan friends use (no app-level SwiftUI
            // offset). The card moves in pure UIKit; require(toFail:) keeps the horizontal slide separate.
            if parent.heroDismiss {
                // THE HOST'S OWN CLOSE. This pan reports and nothing else — see `handleHeroDrag`.
                // `require(toFail:)` on the pager's scroller is the same arrangement the library's
                // own dismiss has always used, and it is what keeps a sideways page swipe and a
                // downward close from ever contesting the same touch.
                let pan = DirectionalPanGestureRecognizer(direction: .down, target: self, action: #selector(handleHeroDrag(_:)))
                pan.delegate = self
                pager.view.addGestureRecognizer(pan)
                ourDownPans.append({ [weak pan] in pan })
                pager.pan.require(toFail: pan)
                dismissPan = pan
                // (prepareForHero / restoreAfterHero are registered in makeUIViewController — see
                // the note there for why they cannot wait until now.)
            } else if !parent.dismissEnabled {
                // PASSIVE watcher over Apple's native zoom-dismiss (user rule: never touch the
                // native close animation): it moves NOTHING — it only (a) pauses the story the
                // moment a downward drag starts and (b) COMMITS the close on a fast flick, which
                // the system's interactive dismissal tends to bounce back ("fast doesn't work").
                let watch = DirectionalPanGestureRecognizer(direction: .down, target: self, action: #selector(handleDismissWatch(_:)))
                watch.delegate = self
                watch.cancelsTouchesInView = false
                pager.view.addGestureRecognizer(watch)
                ourDownPans.append({ [weak watch] in watch })
            }
            if parent.dismissEnabled {
                let pan = DirectionalPanGestureRecognizer(direction: .down, target: self, action: #selector(handleDismiss(_:)))
                pan.delegate = self
                pager.view.addGestureRecognizer(pan)
                ourDownPans.append({ [weak pan] in pan })
                pager.pan.require(toFail: pan)
                dismissPan = pan
                // The zoom navigationTransition installs its OWN hidden interactive-dismiss pan on the
                // presentation chain, and it wins the race on fast flicks (re-lays-out the cover mid-
                // drag: wrong story flash, black frame, stuck dismissal — and it IGNORES
                // .interactiveDismissDisabled, device-proven on build 220). Subordinate it: any SYSTEM
                // pan up the chain must WAIT for our pan to fail — ours begins on every real downward
                // drag, so the system gesture never engages during drags, while X/auto closes (no pan)
                // keep the zoom-back hero. The recognizer only exists once presentation settles, so
                // try shortly after mount and again after the transition completes.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.subordinateSystemPans() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.subordinateSystemPans() }
            }
            // UP pan opens the views sheet. NOT installed for own stories — the host owns swipe-up there
            // (real-time viewers-sheet tracking), so the library up pan would double-fire.
            if parent.swipeUpEnabled {
                let upPan = DirectionalPanGestureRecognizer(direction: .up, target: self, action: #selector(handleSwipeUp(_:)))
                upPan.delegate = self
                pager.view.addGestureRecognizer(upPan)
                pager.pan.require(toFail: upPan)
            }
        }


        /// THE HOST-DRIVEN CLOSE: this method moves nothing and decides nothing.
        ///
        /// Everything the old `handleDismiss` did in here — pick a scale, pick a threshold, choose
        /// an exit — is geometry that belongs to whatever the story was opened FROM, and the library
        /// has never been able to see that. So the finger is reported and the host answers with a
        /// rectangle. What stays here is the part that genuinely belongs to the pager: making the
        /// containers see-through the moment the drag starts, so the shrinking card uncovers the
        /// chat list rather than a black page, and freezing the cube while the card is not where the
        /// page-fold maths thinks it is.
        ///
        /// The background is cleared on the FINGER, not on any dismissal callback. That lesson is
        /// already written into `handleDismissWatch` and it cost two device rounds: a dismissal
        /// formally starts long after the card has begun moving, so anything waiting for it rides
        /// down as a black bar for the whole drag.
        @objc func handleHeroDrag(_ g: UIPanGestureRecognizer) {
            guard let pager else { return }
            // WINDOW SPACE, NOT PAGER SPACE, and it is load-bearing now. The flight transforms the
            // presenter's container ABOVE this view, so pager coordinates shrink with the card as
            // the drag progresses: a translation measured there is divided by the card's scale,
            // which inflates every report and compounds frame over frame. The same lesson is
            // already written on the swipe-up pan. The window is never transformed.
            let space: UIView = pager.view.window ?? pager.view
            let t = g.translation(in: space)
            let v = g.velocity(in: space)
            switch g.state {
            case .began:
                StoryCardMorph.heroDismissActive = true
                StoryCardMorph.shared.prepareForHero?()
                NotificationCenter.default.post(name: .pauseStory, object: nil)
                parent.onHeroDrag(.began, t, v)
            case .changed:
                parent.onHeroDrag(.changed, t, v)
            case .ended:
                parent.onHeroDrag(.ended, t, v)
            case .cancelled, .failed:
                parent.onHeroDrag(.cancelled, t, v)
            default: break
            }
        }

        // Rides ALONGSIDE the system zoom-dismiss without influencing it (cancelsTouchesInView
        // false, simultaneous recognition). Pause on drag-start; commit fast flicks via the
        // SAME native dismissal (isPresented=false → the zoom-back hero plays — no custom anim).
        @objc func handleDismissWatch(_ g: UIPanGestureRecognizer) {
            guard let pager else { return }
            switch g.state {
            case .began:
                // THE BLACK STEPS ASIDE ON THE FINGER, NOT ON APPLE'S CALLBACK. viewWillDisappear
                // (the build-466 attempt) fires when a dismissal formally STARTS — but the zoom
                // gesture shrinks the cover DURING the drag, before any dismissal exists, so the
                // strip above the card rode along black for the whole drag and only went clear at
                // commit, which nobody sees. His screenshot twice. This pan begins on every
                // downward drag, which is exactly the moment the see-through look must start.
                pager.view.backgroundColor = .clear
                NotificationCenter.default.post(name: .pauseStory, object: nil)
            case .changed:
                // AND IT HAS TO TELL THE HOST, which it never did.
                //
                // The host hides its own furniture on `dragDown > 6` — my story's Views/trash footer,
                // the "can't reply" pill, the owner bar. All of them sit BELOW the card and do not
                // move with it. This watcher had `.began`, `.ended` and `.cancelled` and no
                // `.changed`, so `dragDown` never left 0 and that furniture stayed on screen while
                // the story shrank away from it. His report: the trash still showing, on its own
                // dark bar, the moment he starts to drag.
                //
                // Reported on the THRESHOLD CROSSING, not per frame: the host only ever asks whether
                // it is past 6, and a per-frame write would invalidate the whole viewer sixty times a
                // second to answer a question whose answer changed once.
                let dy = max(0, g.translation(in: pager.view).y)
                if (dy > 6) != watchDragPastThreshold {
                    watchDragPastThreshold = dy > 6
                    parent.onDragChanged(dy)
                }
            case .ended:
                let ty = g.translation(in: pager.view).y
                let vy = g.velocity(in: pager.view).y
                watchDragPastThreshold = false
                if ty > 20, vy > 800 {
                    NotificationCenter.default.post(name: .pauseStory, object: nil)
                    NotificationCenter.default.post(name: Notification.Name("storyForceClose"), object: nil)
                } else {
                    // Released gently: the system gesture decides commit/cancel on its own;
                    // resume so a cancelled drag never leaves the story frozen. If it cancels, the
                    // cover springs back to full screen — solid black behind the card again.
                    pager.view.backgroundColor = .black
                    NotificationCenter.default.post(name: .resumeStory, object: nil)
                    parent.onCancel()   // furniture comes back with it
                }
            case .cancelled, .failed:
                watchDragPastThreshold = false
                pager.view.backgroundColor = .black
                NotificationCenter.default.post(name: .resumeStory, object: nil)
                parent.onCancel()
            default: break
            }
        }

        @objc func handleDismiss(_ g: UIPanGestureRecognizer) {
            // THE MOVING CARD. It was the queuing scroll view — the thing that held the pages — and
            // it is the container's own view now, which holds them instead. Not the HOST's view:
            // SwiftUI writes a representable root view's frame every layout pass, and writing
            // `frame` to a transformed view corrupts it.
            guard let pager else { return }
            let card: UIView = pager.view
            let t = g.translation(in: pager.view)
            switch g.state {
            case .began:
                StoryPager.dismissActive = true   // freeze the cube: no 3D fold while the card moves
                // SEE-THROUGH dismissal (user reference): the shrinking card must reveal the CHAT
                // LIST behind the cover, not a blurred copy of itself. The stationary container
                // goes clear (the cover's presentation background is already clear at rest); the
                // MOVING card keeps its own solid backing so the story never turns transparent.
                // BOTH CLEAR NOW. This used to paint the moving card black so the story could not go
                // transparent mid-drag, and leaned on `maskToCard` to clip that black back to the
                // 9:16 card. The page is taller than the card, so whenever the clip did not bite,
                // the strip of page above the card came along as a black header sitting on top of
                // the story — the bar he circled, twice.
                //
                // The card paints its own black inside its own rounded rect now (StoryDetailView),
                // so there is no black out here to leak. What pulls away is the picture and nothing
                // else, which is what another mainstream messenger's dismissal actually is.
                card.backgroundColor = .clear
                pager.view.backgroundColor = .clear
                NotificationCenter.default.post(name: .pauseStory, object: nil)   // freeze for the whole drag
            case .changed:
                let ty = max(0, t.y)
                let frac = min(1, ty / card.bounds.height)
                // Reference video (user's chosen close): the card shrinks HARD as you pull —
                // down to ~30% at a full drag — floating over the live chat list, with a light
                // horizontal follow. It shrinks in place; it does not ride off with the finger.
                let scale = 1.0 - 0.7 * frac
                card.layer.cornerCurve = .continuous    // Apple squircle
                // CLIPPED TO THE STORY, NOT TO THE PAGE, which is the black header he circled. The
                // page is taller than the 9:16 card and the strip above it is the page's own black
                // background; rounding the PAGE shrank that strip into view as a black band inside
                // the card. Masking to the story means what pulls away is the story. See
                // StoryCardMorph.maskToCard.
                StoryCardMorph.shared.maskToCard(cornerRadius: min(40, ty * 0.3), scale: scale)
                // Horizontal follow clamped: a flick's large t.x must not yank the card sideways.
                let tx = max(-60, min(60, t.x * 0.7))
                card.transform = CGAffineTransform(translationX: tx, y: ty * 0.85)
                    .scaledBy(x: scale, y: scale)
                parent.onDragChanged(ty)                // fade the host overlays
            // ⚠️ A CANCELLED PULL IS NOT A FINISHED PULL. `.cancelled` used to share this branch
            // with `.ended` and was judged on the SAME accumulated translation, so a touch the
            // system took away past the threshold COMMITTED. Pull a story down and let a call
            // banner or Control Center interrupt you, and it closed instead of springing back.
            // `DirectionalPanGestureRecognizer` also cancels itself when the cross axis wins, and
            // disabling a live recogniser cancels it, so this is not a rare path.
            //
            // Cancelled means nothing happened: spring home, whatever the finger had covered.
            case .cancelled:
                springBackFromDismiss(card: card)
            case .ended:
                let ty = t.y, vy = g.velocity(in: pager.view).y
                // commit threshold: translation.y > 200 OR (translation.y > 5 AND velocity.y > 200)
                if ty > 200 || (ty > 5 && vy > 200) {
                    // Dismiss → STOP playback/timer for good (don't resume). The story was already paused on
                    // .began; killing the video here means no audio/frame keeps running behind the dismissal.
                    NotificationCenter.default.post(name: .pauseStory, object: nil)
                    // Reference video (user's chosen close): the card SHRINKS AND MELTS AWAY in
                    // place over the visible chat list. It must NOT slide off the bottom — the
                    // slide-off exit was the rejected look. Same exit at every drag depth/speed.
                    let exitScale: CGFloat = 0.12
                    let exitTx = max(-60, min(60, t.x * 0.7))   // clamped like the drag
                    UIView.animate(withDuration: 0.24, delay: 0, options: [.curveEaseIn]) {
                        card.transform = CGAffineTransform(translationX: exitTx, y: max(0, t.y) * 0.85 + 40)
                            .scaledBy(x: exitScale, y: exitScale)
                        card.alpha = 0
                    } completion: { _ in
                        self.parent.onCommit()
                        card.alpha = 1   // reset in case the pager is ever reused
                        StoryPager.dismissActive = false
                    }
                } else {
                    springBackFromDismiss(card: card)
                }
            default: break
            }
        }

        /// The card goes home and the story runs again. ONE implementation, shared by the gentle
        /// release and by a cancellation, so the two can never drift into behaving differently.
        private func springBackFromDismiss(card: UIView) {
            NotificationCenter.default.post(name: .resumeStory, object: nil)   // sprang back -> resume
            UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.85,
                           initialSpringVelocity: 0.3, options: []) {
                card.transform = .identity
                card.layer.cornerRadius = 0   // back to square (the media keeps its own rounding)
            } completion: { _ in
                // The dismiss clip comes off only once the card is home, or the story would
                // pop back to full-page bounds mid-spring.
                StoryCardMorph.shared.clearMask()
                self.pager?.view.backgroundColor = .black   // restore the solid backing at rest
                StoryPager.dismissActive = false            // cube live again at rest
                self.parent.onCancel()
            }
        }

        // One-time snapshot of the live card, used as the stationary backdrop during the dismiss drag.
        private func snapshot(_ view: UIView) -> UIImage? {
            guard view.bounds.width > 1, view.bounds.height > 1 else { return nil }
            let r = UIGraphicsImageRenderer(bounds: view.bounds)
            return r.image { _ in view.drawHierarchy(in: view.bounds, afterScreenUpdates: false) }
        }
        @objc func handleSwipeUp(_ g: UIPanGestureRecognizer) {
            guard let pager else { return }
            // WINDOW space, not pager space: the sheet-open morph SCALES the pager while this
            // pan is live, so pager-space deltas get amplified by 1/scale — a compounding
            // feedback loop that made the sheet leave the finger at ~50% and fly open on its
            // own (user report; same disease as the sheet drag's old .local-space bug).
            let space: UIView = pager.view.window ?? pager.view
            let t = g.translation(in: space)
            let v = g.velocity(in: space)
            // Report the drag CONTINUOUSLY so the host tracks the viewers sheet 1:1 with the finger
            // (native feel), then decides open/close on release. Direction-locked to .up, so it never
            // fights the down dismiss pan. The drag is measured from the ENGAGEMENT point (baseline),
            // not from touch-down, so the first frame reports ~0 instead of the accumulated wake-up
            // distance (that was the ~5% engagement snap the user measured).
            switch g.state {
            case .began:
                swipeUpBaselineY = t.y
            case .changed:
                if swipeUpBaselineY == nil { swipeUpBaselineY = t.y }
                let up = -(t.y - (swipeUpBaselineY ?? t.y))    // +up, zeroed at engagement
                parent.onSwipeUpChanged(max(0, up))
            case .ended:
                let up = -(t.y - (swipeUpBaselineY ?? t.y))
                parent.onSwipeUpEnded(up, -v.y)                // translation +up (from engagement), velocity +up
                swipeUpBaselineY = nil
            // ⚠️ CANCELLED REPORTS NOTHING, for the same reason the dismiss does not commit on one.
            // Sharing `.ended`'s branch meant a touch the system took away was judged on its
            // accumulated travel: past 200pt it snapped the viewers sheet fully open with the finger
            // already gone, and on a FRIEND's story past 40pt it opened the reply keyboard. Zero
            // fails both tests, so the sheet settles back to where it was before the drag.
            case .cancelled:
                parent.onSwipeUpEnded(0, 0)
                swipeUpBaselineY = nil
            default: break
            }
        }

        // Walk the presentation chain (pager → window) and make every SYSTEM pan recognizer —
        // identified by Apple's private "_UI…" class-name prefix (name READ only, no private API
        // called) — wait for our dismiss pan to fail. SwiftUI's own gesture host recognizers
        // ("SwiftUI.…") and the scroll pans are untouched. Idempotent; if nothing matches
        // (future iOS moves it), behavior simply stays as before — graceful no-op.
        private func subordinateSystemPans() {
            guard let pan = dismissPan, let v = pager?.view else { return }
            var node: UIView? = v.superview
            while let cur = node {
                for g in cur.gestureRecognizers ?? [] where g !== pan {
                    guard g is UIPanGestureRecognizer else { continue }
                    if NSStringFromClass(type(of: g)).hasPrefix("_UI") {
                        g.require(toFail: pan)
                    }
                }
                node = cur.superview   // ends at (and includes) the UIWindow
            }
        }

        // Let our pans coexist with EVERYTHING: the hosted SwiftUI gestures (tap zones,
        // hold-to-pause), the page scroll, and — critically — the system zoom-dismiss pan,
        // which the passive watcher must ride alongside without ever blocking it. (The old
        // "_UI…" exclusion protected the CUSTOM card pan from double-driving; that pan is
        // inert now, and excluding the system pan would kill the native close outright.)
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith o: UIGestureRecognizer) -> Bool { true }

        /// ⚠️ WITH THE REPLY KEYBOARD UP, A DOWNWARD SWIPE LOWERS THE KEYBOARD AND NOTHING ELSE.
        /// The same guard as `StorySoloPager`'s, for the same reason and with the same history —
        /// read the note there. Both pagers install a down pan and neither had a keyboard test.
        // ⚠️ EVERY DOWN PAN WE OWN, NOT JUST `dismissPan`. The guard used to name one recogniser,
        // and the PASSIVE watcher is never assigned to it — so on a viewer that installs the watcher
        // (no hero dismiss, no library dismiss) a downward swipe with the reply keyboard up sailed
        // past this and closed the whole viewer. His report, in his words: "if i open keyboad then i
        // try to scroll down just means Close keyboad Not all story". It was fixed on two of the
        // three routes and this was the third.
        //
        // Keeping the SET rather than the one reference means a future fourth pan is covered by
        // construction instead of by remembering to add it here.
        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            guard ourDownPans.contains(where: { $0() === g }), keyboardUp else { return true }
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            return false
        }
    }
}

/// The pager, with one job of its own: DROP THE BLACK THE MOMENT A REAL DISMISSAL STARTS.
///
/// `view.backgroundColor` is black at rest so the strips above and below the 9:16 card read as the
/// screen's own black. But that black lives INSIDE the cover, so Apple's zoom-dismiss shrank it
/// along with everything else and the strip above the card arrived as a black header sitting on
/// the story — the band he circled. `3bd471d` fixed this for the library's own down-pan (its
/// .began clears the backgrounds), but the zoom presentations never run that pan: their dismissal
/// is Apple's, and nothing on that path ever cleared the black. This is that path's clear.
///
/// `viewWillDisappear` + `isBeingDismissed` is the exact signal: it fires the instant a dismissal
/// transition starts — the interactive drag, the X close, the auto-close — and for none of the
/// things that must NOT go clear (page swaps never disappear the pager; backgrounding is not
/// `isBeingDismissed`). A cancelled drag runs `viewWillAppear` again, which restores the black.
/// The card itself stays opaque throughout — it paints its own black inside its own rounded rect
/// (StoryDetailView) — so what pulls away is the picture and nothing else, which is what the
/// reference screenshot he sent actually is.

/// ⚠️ ONE PLAIN VIEW FOR THE MORPH TO MOVE, WRAPPED ROUND THE PAGER. This is `StorySoloHostVC`'s
/// `cardContainer` for the friends route, and it exists for exactly the reason that one does.
///
/// The viewers sheet shrinks the story by writing a `transform` to a view. On my own story that view
/// has always been a plain container and the sheet has always worked; on this route it was UIKit's
/// private `_UIQueuingScrollView`, and the sheet did not. Build 512 routed my story through here for
/// the sideways swipe and shipped broken because of it.
///
/// The requirement is written on the solo host and it is three things this pager's scroll view fails
/// all of: `bounds.origin` always zero (a queuing scroll view's is one page wide and moving), no
/// gesture plumbing of its own, and nothing laying it out mid-drag. "Nothing of Apple's under the
/// transform." There is also a crash on record for the old target — build 481, inside
/// `queuingScrollView:didEndManualScroll:toRevealView:`, while UIKit tore down a transition we had a
/// transform on.
///
/// ⚠️ IT IS A CONTAINER AND NOTHING ELSE. It paints nothing: the black stays on `pager.view` exactly
/// where it was, so every background and alpha behaviour — the hero's `prepareForHero`, the
/// dismiss's `viewWillDisappear` — is byte-for-byte what it was. The only thing that changed is which
/// view a transform lands on.
///
/// ⚠️ AND NOT `pager.view` ITSELF. SwiftUI writes a representable's root view `frame` on every layout
/// pass, and writing `frame` to a transformed view corrupts it. That is the one place the old
/// "survives its layout" reasoning would genuinely have applied.
final class StoryPagerHostVC: UIViewController {
    let cardContainer = UIView()
    let pager: StoryCubePagerVC

    init(pager: StoryCubePagerVC) {
        self.pager = pager
        super.init(nibName: nil, bundle: nil)
    }
    @MainActor required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Clear, not black: the card's black belongs to `pager.view` and always has. A second black
        // here would sit behind the shrinking card and undo the whole point of the dismiss going
        // clear — the chat list has to show through.
        view.backgroundColor = .clear
        cardContainer.backgroundColor = .clear
        cardContainer.frame = view.bounds
        cardContainer.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(cardContainer)

        addChild(pager)
        pager.view.frame = cardContainer.bounds
        pager.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        cardContainer.addSubview(pager.view)
        pager.didMove(toParent: self)

        // The SAME view every gesture moves is the one the viewers sheet shrinks. No second card, no
        // picture of the story anywhere — see StoryCardMorph.
        StoryCardMorph.shared.attach(cardContainer)
    }
}

// Hosts one bucket's StoryDetailView; remembers which bucket it is for the dataSource lookups.
/// ⚠️ NOT `UIHostingController<AnyView>` ANY MORE.
///
/// `AnyView` erases the type, and an erased view is one SwiftUI cannot diff structurally — every
/// update has to be treated as "this might be anything now" instead of "this is the same view with
/// different values". It cost on every page build, and page builds were happening on every tap (see
/// `makePage`). The concrete type is free and strictly more information for the framework.
final class StoryPageHostVC: UIHostingController<StoryDetailView> {
    var bucketID: String = ""
    override init(rootView: StoryDetailView) {
        super.init(rootView: rootView)
        view.backgroundColor = .clear
        // The story photo must fill edge-to-edge UNDER the status bar. A UIHostingController insets
        // its SwiftUI content by the safe area by default — THAT was the black strip at the top. Turn it off;
        // the progress bars + reply bar re-add their own safe-area padding inside StoryDetailView.
        if #available(iOS 16.4, *) { safeAreaRegions = [] }
    }
    @MainActor required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
