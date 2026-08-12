//
// Route A: UIKit UIPageViewController pager (replaces the SwiftUI TabView). The dismiss pan is added to
// the pager's OWN scroll view (a real direct subview) with require(toFail:), so cube (sideways) and
// dismiss (down) are mutually exclusive (the same page-controller mechanism). Each page hosts
// the existing SwiftUI StoryDetailView, so all the story logic (progress, reply, tap-advance) is reused.
//
// ⚠️ THE CUBE FOLD LIVES HERE, IN `applyCube`, AND NOWHERE ELSE. This header used to say it was a
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

    /// TRUE while a PROGRAMMATIC cube turn is in flight — a tap, or an auto-advance.
    ///
    /// ⚠️ THE CUBE'S GATE NEEDS THIS AND CANNOT WORK WITHOUT IT. `applyCube` folds only while the
    /// pager's scroll view is live (tracking / dragging / decelerating), because any OTHER movement
    /// of a page's origin — Apple's zoom dismiss, a layout shift — must never fold the pages. A
    /// programmatic turn moves the pages by FRAME and never touches those scroll flags, so without
    /// this the fold would simply not run and a tap would slide flat.
    ///
    /// Cleared on the turn's completion, and deliberately a plain static rather than published
    /// state: it is read from a display link at up to 120Hz and must not wait on a publish.
    static var cubeTurnActive = false

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
        StoryPager.cubeTurnActive = false
        let pager = StoryPagerVC(transitionStyle: .scroll, navigationOrientation: .horizontal)
        pager.dataSource = context.coordinator
        pager.delegate = context.coordinator
        pager.view.backgroundColor = .black   // solid card; slides as one unit during dismiss
        // The MEDIA is rounded inside StoryDetailView; the page itself stays square at rest (reply bar on
        // black, not in a card). cornerCurve is set so the dismiss-grow uses the Apple squircle.
        pager.view.layer.cornerCurve = .continuous
        context.coordinator.pager = pager
        if let first = context.coordinator.makePage(for: viewModel.currentStoryUser) {
            pager.setViewControllers([first], direction: .forward, animated: false)
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
        coordinator.cubeLink?.invalidate()
        coordinator.cubeLink = nil
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
        StoryPager.cubeTurnActive = false
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

    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate, UIGestureRecognizerDelegate {
        let parent: StoryPager
        weak var pager: UIPageViewController?
        weak var internalScroll: UIScrollView?
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
        fileprivate var cubeLink: CADisplayLink?   // fileprivate so dismantleUIViewController can invalidate it
        /// Whether any page currently carries a cube transform. Lets the resting frames cost one
        /// comparison instead of a write to every page's layer — see `applyCube`.
        private var cubeApplied = false
        /// Last committed fold position per page, and how many frames in a row were refused — the
        /// landing-blink guard's state. See the LANDING BLINK note in `applyCube`.
        private var lastCubeT: [ObjectIdentifier: CGFloat] = [:]
        private var cubeSkipStreak = 0
        /// The darkening gradient on each page's face — see `tint(for:)`.
        ///
        /// ⚠️ KEYED BY THE PAGE, AND RE-CHECKED AGAINST ITS SUPERLAYER. A queuing scroll view reuses
        /// and re-parents its page views, so an entry can outlive the arrangement it was made for;
        /// `tint(for:)` rebuilds when the layer it remembers is no longer this page's child, which is
        /// cheaper and safer than trying to observe the reuse.
        private var cubeTints: [ObjectIdentifier: CAGradientLayer] = [:]
        // Baseline translation captured the instant the swipe-UP pan engages. The recognizer only
        // begins after the finger has already travelled ~its 8pt threshold plus whatever it moved
        // while the competing pans were failing — so translation(in:) is already ~30-40pt at the
        // first .changed. Reporting that raw value made the card JUMP ~5% the moment the sheet
        // engaged (user's red-border test: a 12px snap at t=0.94). Subtracting this baseline makes
        // the drag start from ZERO at engagement, so the card tracks smoothly from full size.
        private var swipeUpBaselineY: CGFloat?

        init(_ parent: StoryPager) { self.parent = parent }
        deinit { cubeLink?.invalidate() }

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
            let live = Set((pager?.viewControllers ?? []).compactMap { ($0 as? StoryPageHostVC)?.bucketID })
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
            // Own story = a SINGLE bucket: nothing to navigate to horizontally, so kill the internal
            // scroll (its bounce would fight the vertical dismiss pan). Friends have multiple buckets
            // and keep it for user-to-user swipe.
            // ⚠️ SYMMETRIC, AND THAT IS THE FIX, NOT TIDYING. THIS IS THE ONLY WAY THE PERSON-TO-
            // PERSON SWIPE CAN BE KILLED, so it must not be possible to kill it by accident.
            //
            // It only ever DISABLED, so whoever asked first won for the rest of the session — and
            // `stories` is EMPTY early in the open (`startStory` runs in `.onAppear`, which is after
            // `makeUIViewController`, and `installDismissPan` is only one runloop later). Any call in
            // that window read "one bucket or fewer" for a FRIEND's story and switched the swipe off
            // for good, with nothing able to switch it back: the old guard returned early once the
            // buckets arrived, so the re-assert in `syncIfNeeded` could never undo it.
            //
            // ⚠️ THIRD REPORT OF THIS. `25ad2c44` made it symmetric on 2026-08-08 and `38b56dfc`
            // reverted it hours later — NOT because it was wrong, but because he chose "video fix
            // only" for that build and it rode along in the isolation revert. It was never restored,
            // so the race came back. Do not revert it a second time for a reason that is not about
            // this code.
            //
            // Both symptoms are this one line: with the pan recogniser disabled the scroll never
            // tracks, and `applyCube` gates the fold on exactly that motion, so the cube dies with
            // the swipe.
            //
            // With buckets present it sets enabled to true, which is the default it already had, so
            // this changes nothing on the working path.
            guard let scroll = internalScroll else { return }
            // ⚠️ AND WHILE THE VIEWERS SHEET IS UP, NOBODY MAY TURN A PAGE. This is the build-481
            // guard, not tidiness.
            //
            // The sheet shrinks the story by holding a transform on the card, and the card now wraps
            // this pager. A page turn started under a shrunken card is UIKit animating its own
            // private scroll view inside a view we are transforming — which is the exact shape that
            // crashed build 481 in `queuingScrollView:didEndManualScroll:toRevealView:`. It could not
            // happen before, because my own story was the only thing the sheet ran over and it had no
            // pager at all; it becomes reachable the moment my bucket is one page among several.
            //
            // `sheetFraction` is the sheet's own number and is zero at rest, so this costs the normal
            // path nothing, and `syncIfNeeded` re-asserts on every update so it comes back by itself.
            let sheetUp = StoryCardMorph.shared.sheetFraction > 0.001
            let single = parent.viewModel.stories.count <= 1
            let live = !single && !sheetUp
            scroll.isScrollEnabled = live
            scroll.panGestureRecognizer.isEnabled = live
            scroll.bounces = live
            scroll.alwaysBounceHorizontal = false
        }

        func syncIfNeeded() {
            neutralizePagerScrollIfHostOwnsSwipe()   // re-assert on every update; UIPageViewController may reset it
            // The setting can change while a viewer is open (Settings → Stories), and the link is
            // what draws the cube — re-checked here so the very next turn honours it.
            updateCubeLink()
            guard let pager else { return }
            let shown = (pager.viewControllers?.first as? StoryPageHostVC)?.bucketID
            // Initial population: stories/currentStoryUser weren't ready at makeUIViewController time
            // (startStory runs in .onAppear, after), so the pager came up empty -> black. Fill it now.
            if shown == nil {
                if let first = makePage(for: parent.viewModel.currentStoryUser) {
                    pager.setViewControllers([first], direction: .forward, animated: false)
                    // The FIRST advance is the one that used to be slowest, because nothing had been
                    // asked for yet. Warm the neighbours from the moment the viewer has a page.
                    prewarmNeighbours(of: parent.viewModel.currentStoryUser)
                }
                return
            }
            guard shown != parent.viewModel.currentStoryUser,
                  let from = index(of: shown!), let to = index(of: parent.viewModel.currentStoryUser),
                  let target = makePage(for: parent.viewModel.currentStoryUser)
            else { return }
            // ⚠️ THE WARM WAITS FOR THE TURN TO FINISH. It used to start one runloop after the
            // transition began, which is DURING it — and laying out a SwiftUI story page is not
            // cheap, so it spent main-thread time on the person after next while the person you
            // asked for was still arriving.
            // ⚠️ NEVER TWO TURNS AT ONCE, AND NEVER OVER THE TOP OF A FINGER. This is the crash
            // guard — see `isTurning`. The scroll-view test covers the interactive case: an
            // interactive swipe reports through `didFinishAnimating`, not through this path, so
            // `isTurning` alone would not see it.
            if isTurning || internalScroll.map({ $0.isTracking || $0.isDragging || $0.isDecelerating }) == true {
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
            StoryPager.cubeTurnActive = true
            // ⚠️ THE `layer.speed` BLOCK THAT USED TO BE HERE IS DELETED, AND SO IS `cubeTurnSpeedup`.
            //
            // It ran the pager's scroll layer at 3x to shorten UIKit's private turn duration, which
            // answered his 2026-08-11 "make it about 0.10 seconds". His 2026-08-12 instruction is to
            // match Telegram, whose peer turn settles over 0.4s on a spring — and
            // `UIPageViewController`'s own `.scroll` turn is within a frame or two of that, so the
            // right multiplier is 1.0 and a multiplier of 1.0 is three lines implementing an
            // identity function. The `asyncAfter` belt also captured the scroll view strongly and
            // kept the whole page hierarchy alive for a second after every turn, including after the
            // viewer had closed.
            //
            // If the turn ever needs shortening again, `internalScroll?.layer.speed` is the lever —
            // it must be restored in the completion AND on an independent clock, because a raised
            // speed belongs to the layer rather than to the turn and would silently accelerate the
            // dismiss spring.
            //
            // ⚠️ AND NOTE WHAT THE 3x WAS HIDING: at 1.0 the turn is three times longer, so every
            // window in which a tap, a dismiss, an auto-advance or a teardown can land INSIDE a live
            // turn is three times wider than when these guards were last tuned. That is why the flags
            // above now also come down in `dismantleUIViewController`.
            pager.setViewControllers([target], direction: to > from ? .forward : .reverse,
                                     animated: true) { [weak self] _ in
                StoryPager.cubeTurnActive = false
                StoryPager.personTurnActive = false
                guard let self else { return }
                // ⚠️ `isTurning` COMES DOWN HERE AND NOWHERE EARLIER. It is the crash guard (see its
                // note: a second turn over the top of a live one is a UIKit assertion), so it is tied
                // to the real end of the transition, never to a duration we guessed.
                self.isTurning = false
                self.prewarmNeighbours(of: next)
                self.replayPendingSync()
            }
        }

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

        func pageViewController(_ pvc: UIPageViewController, viewControllerBefore vc: UIViewController) -> UIViewController? {
            guard let cur = (vc as? StoryPageHostVC)?.bucketID, let i = index(of: cur), i > 0 else { return nil }
            return makePage(for: parent.viewModel.stories[i - 1].id)
        }
        func pageViewController(_ pvc: UIPageViewController, viewControllerAfter vc: UIViewController) -> UIViewController? {
            guard let cur = (vc as? StoryPageHostVC)?.bucketID, let i = index(of: cur),
                  i < parent.viewModel.stories.count - 1 else { return nil }
            return makePage(for: parent.viewModel.stories[i + 1].id)
        }

        func pageViewController(_ pvc: UIPageViewController, didFinishAnimating finished: Bool,
                                previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
            // ⚠️ THE INTERACTIVE TRANSITION IS OVER WHETHER OR NOT IT COMMITTED, so the pending-sync
            // replay is released BEFORE the `completed` guard. A swipe the person changed their mind
            // about still ends a transition, and a sync refused during it must not be stranded — that
            // is how the pager ends up showing one person while the view model names another.
            defer { replayPendingSync() }
            // ⚠️ A CANCELLED SWIPE DROPS THE QUEUED TURN INSTEAD OF SPENDING IT.
            //
            // `personTurnActive` locks out a tap during a PROGRAMMATIC turn, and there is no
            // equivalent during a finger swipe: `currentStoryUser` is not written until this method
            // runs, so a tap landing on the departing page mid-drag passes every guard, computes
            // "the person after ME", and is parked in `syncPending` by `syncIfNeeded`'s
            // scroll-is-dragging refusal. Release the swipe BELOW the threshold and the page springs
            // back — and the replay above then turns to the person that stray tap named.
            //
            // The user pulled a page halfway, changed their mind, and the viewer moved anyway. That
            // is the bounce report in a different costume. A transition that did not commit means
            // the person did not ask for anything, so the queued sync is not theirs to spend; the
            // model is re-pointed at the page actually on screen so nothing is left disagreeing.
            if !completed {
                syncPending = false
                if let shown = (pvc.viewControllers?.first as? StoryPageHostVC)?.bucketID,
                   parent.viewModel.currentStoryUser != shown {
                    parent.viewModel.currentStoryUser = shown
                }
                return
            }
            guard let cur = (pvc.viewControllers?.first as? StoryPageHostVC)?.bucketID else { return }
            parent.viewModel.currentStoryUser = cur   // StoryView's onChange fires onUserChanged
            // A swipe lands here rather than in `syncIfNeeded`, and the person AFTER the one he just
            // reached is the next thing he can ask for. Same warm, same reason.
            prewarmNeighbours(of: cur)
        }

        // MARK: dismiss pan (down only) + require-to-fail on the pager's own scroll
        /// How many times the scroll-view lookup below has come up empty. Capped so a pager that
        /// genuinely never builds one cannot spin forever.
        private var bindAttempts = 0

        func installDismissPan() {
            NotificationCenter.default.addObserver(self, selector: #selector(keyboardShown),
                                                  name: UIResponder.keyboardWillShowNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(keyboardHidden),
                                                  name: UIResponder.keyboardWillHideNotification, object: nil)
            guard !didInstallPan, let pager else { return }
            // THE ONE-SHOT FLAG USED TO BE SET HERE, BEFORE WE KNEW WE HAD ANYTHING, and that is why
            // the viewers sheet came up over a full-size story that never shrank.
            //
            // This runs one runloop tick after `makeUIViewController`, and a UIPageViewController has
            // not always built its internal scroll view by then. When it had not, `scroll` was nil,
            // `internalScroll` and `StoryCardMorph.shared.card` were both set to nil, and
            // `didInstallPan = true` meant it never looked again. The morph then silently did nothing
            // for the whole session: `apply` guards on `card` and returns, so the story stayed exactly
            // where it was while the sheet slid up over it. That is his screenshot.
            //
            // It failed silently in the worst way — the swipe-down dismiss still worked, because that
            // pan goes on `pager.view` rather than on the scroll view, so nothing looked broken until
            // somebody pulled the sheet.
            guard let scroll = pager.view.subviews.compactMap({ $0 as? UIScrollView }).first else {
                guard bindAttempts < 20 else { return }
                bindAttempts += 1
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    self?.installDismissPan()
                }
                return
            }
            didInstallPan = true
            internalScroll = scroll
            // ⚠️ THE MORPH IS NOT ATTACHED HERE ANY MORE, AND THAT MOVE IS THE WHOLE OF A REVERT.
            //
            // It used to be `attach(scroll)` — UIKit's private `_UIQueuingScrollView`. Build 512
            // routed my own story through this pager for the sideways swipe he asked for and shipped
            // with the viewers sheet not shrinking the story behind it; the note left in `MainShell`
            // blamed the transform not surviving that view's layout and prescribed re-asserting it.
            // Both halves were wrong, and were inferred from a screenshot rather than measured:
            // nothing in this repo resets a transform on that view, and the sheet's driver is a
            // display link that already re-writes it every single frame.
            //
            // The real difference is what the transform is written TO. `StorySoloHostVC.cardContainer`
            // — the host my own story used, where the sheet has always worked — states the
            // requirement in its own doc: a plain view whose `bounds.origin` is always zero, with no
            // gesture plumbing of its own and nothing laying it out mid-drag. "Nothing of Apple's
            // under the transform." This pager had the opposite of all three.
            //
            // ⚠️ AND THERE IS A CRASH ON RECORD FOR THE OLD TARGET, which is the stronger reason:
            // build 481 died inside `queuingScrollView:didEndManualScroll:toRevealView:` while UIKit
            // cleaned up a transition we had a transform on. The flight was moved off this view then;
            // the sheet was simply left behind on it.
            //
            // `StoryPagerHostVC` wraps this pager in exactly that plain container and attaches in its
            // own `viewDidLoad`. `internalScroll` is still needed and still correct for the cube, for
            // `require(toFail:)` and for the neutralise — it is only the MORPH that moved.
            // When the host owns the swipe (own story: app-level SwiftUI dismiss), the pager's internal
            // scroll pan has nothing to navigate to (single bucket) and only CONTENDS with the host drag
            // for the same touch — that horizontal scroll/bounce fighting the vertical drag is the
            // "shaky"/double-image swipe-down. Fully neutralize it (scroll off + pan recognizer off +
            // no bounce). Friends keep it for user-to-user swipe. Re-applied in syncIfNeeded so a
            // UIPageViewController internal reset can't turn it back on.
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
                scroll.panGestureRecognizer.require(toFail: pan)
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
                scroll.panGestureRecognizer.require(toFail: pan)
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
                scroll.panGestureRecognizer.require(toFail: upPan)
            }
            // The cube's display link is started here and re-checked on every update — see
            // `updateCubeLink`. It is the ONE owner of the fold.
            updateCubeLink()
        }

        /// ⚠️ ONE OWNER FOR THE FOLD, AND THERE IS NO LONGER A SETTING TO ASK.
        ///
        /// His 2026-08-12 report: the cube folds on a TAP and does nothing on a finger swipe. The
        /// cause is in this file's own history. `02cc55d1` retired this display link in favour of
        /// SwiftUI's `rotation3DEffect` (`StoryDetailView.getAngle`), and that angle is derived from
        /// `proxy.frame(in: .global)` — **a GeometryReader re-evaluates on a SIZE change, not on a
        /// POSITION change**, a trap already written up twice in this repo. A finger swipe moves the
        /// pages by the scroll view's `contentOffset`: no size changes, no layout is invalidated, and
        /// the incoming page is not even current yet (`currentStoryUser` is written in
        /// `didFinishAnimating`, at the END of the swipe), so its 20fps tick does not run either.
        /// Nothing re-samples the angle, so the page stays flat. A TAP escapes it by accident: the
        /// view model is written FIRST, so the incoming page ticks and re-renders all through Apple's
        /// animated turn. Working by accident on one path and not at all on the other.
        ///
        /// This link reads `layer.position` and `contentOffset` directly, so position is exactly what
        /// it is made of, and it covers both paths with one mechanism.
        ///
        /// ⚠️ AND THE SWIFTUI FOLD IT USED TO SHARE THE JOB WITH IS DELETED, NOT DISABLED. Two things
        /// folding the same pages is what produced the shake and the black flash. `getAngle` used to
        /// return zero in cube mode to stay out of the way; there is no mode any more, so there is
        /// nothing for it to stay out of the way OF, and a fold that can only ever return zero is a
        /// trap for whoever reads it next. This link is the only thing that folds a page.
        func updateCubeLink() {
            guard cubeLink == nil else { return }
            let link = CADisplayLink(target: self, selector: #selector(applyCube))
            // `.common` so the fold keeps running while the scroll view is tracking a finger, which
            // is the entire case this exists for.
            link.add(to: .main, forMode: .common)
            cubeLink = link
        }

        /// Every page back to flat. A page keeps whatever transform it was last given, so leaving
        /// cube mode — or coming to rest — must put them back or a page stays folded on screen.
        /// ⚠️ RESETS FROM THE TINT MAP, NOT FROM THE SCROLL VIEW'S CURRENT SUBVIEWS, AND THAT IS THE
        /// WHOLE POINT OF THE MAP.
        ///
        /// A page that leaves mid-fold is the case this has to cover, and walking `scroll.subviews`
        /// cannot: `_UIQueuingScrollView` flushes the departing page in the same runloop hop that
        /// runs the turn's completion, so by the next display-link frame it is already out of that
        /// list — still carrying a rotation near 90° and a gradient at full black. Those page views
        /// are CACHED (`pageCache`) and re-added later, and `applyCube` only rewrites a page on a
        /// frame where something is moving, so a re-added one gets composited at least once wearing
        /// the stale fold. That is the "black frame / wrong story" class this file already documents
        /// twice.
        ///
        /// Every page that has ever folded has a gradient in the map, and the gradient's superlayer
        /// IS that page's layer — so the map reaches exactly the set that needs putting back,
        /// whether or not the scroll view still admits to owning them.
        private func resetCubeTransforms() {
            cubeApplied = false
            lastCubeT.removeAll()
            cubeSkipStreak = 0
            for (_, g) in cubeTints {
                g.opacity = 0
                g.superlayer?.transform = CATransform3DIdentity
            }
            // Keyed by page-view identity, and a queuing scroll view builds and drops those as it
            // likes, so without this the map grows for the life of the viewer holding
            // `CAGradientLayer`s that belong to nothing. A gradient with no superlayer has already
            // been detached with its page — and it has just been put back flat above, so nothing is
            // lost by forgetting it.
            cubeTints = cubeTints.filter { $0.value.superlayer != nil }
            // Belt for a page that somehow never folded and so never got a gradient: it can only be
            // at identity already, but this costs one pass and closes the gap by construction.
            guard let scroll = internalScroll else { return }
            let w = scroll.bounds.width
            for sub in scroll.subviews where abs(sub.bounds.width - w) < 1.0 {
                sub.layer.transform = CATransform3DIdentity
            }
        }

        /// ⚠️ THE DARKENING ON THE TURNING FACE — the reference app has it and we did not, and it is
        /// most of why their cube reads as a solid object and ours read as a picture on a hinge.
        ///
        /// Theirs is a black axial gradient over each face, `1.0 → 0.8 → 0.5` alpha, whose DIRECTION
        /// flips with the sign of the rotation and whose whole-layer opacity is `|fraction| × 1.3`
        /// clamped to 1. Both numbers are theirs, not tuned by eye.
        ///
        /// A sublayer of the page rather than a sibling, which is the one difference from their
        /// arrangement and it is in our favour: their tint is a separate layer in a
        /// `CATransformLayer` and has to be given the face transform by hand, while a child of the
        /// page's own layer inherits the fold for free — and is hidden by the same
        /// `isDoubleSided = false` when the face turns away.
        private func tint(for page: UIView) -> CAGradientLayer? {
            let key = ObjectIdentifier(page)
            if let existing = cubeTints[key], existing.superlayer === page.layer {
                // ⚠️ AND IT HAS TO STAY ON TOP. A UIView's subviews ARE its layer's sublayers, so
                // anything UIKit adds to the page afterwards — and a queuing scroll view does re-add
                // its hosted content — lands ABOVE this gradient and the darkening silently stops
                // being visible. Re-appending only when it is not already last costs one comparison
                // a frame and cannot be forgotten the way a one-time insert can.
                if page.layer.sublayers?.last !== existing { page.layer.addSublayer(existing) }
                return existing
            }
            let g = CAGradientLayer()
            g.type = .axial
            g.colors = [UIColor.black.withAlphaComponent(1.0).cgColor,
                        UIColor.black.withAlphaComponent(0.8).cgColor,
                        UIColor.black.withAlphaComponent(0.5).cgColor]
            g.opacity = 0
            // ⚠️ CULLED WITH ITS FACE. `isDoubleSided` is PER LAYER and is not inherited, so the
            // `false` set on the page's own layer does not cover this one — the gradient would keep
            // drawing after its parent face turned past square, which is a thin fully-black sliver
            // on the far edge at the end of every turn, exactly where the content has been culled.
            g.isDoubleSided = false
            // Never its own animation: this is driven every frame from the display link, and an
            // implicit CALayer action would fight it and lag the fold by a frame.
            g.actions = ["opacity": NSNull(), "position": NSNull(), "bounds": NSNull(),
                         "startPoint": NSNull(), "endPoint": NSNull()]
            page.layer.addSublayer(g)
            cubeTints[key] = g
            return g
        }

        // The cube: rotate each page around the shared vertical edge with perspective depth, driven
        // by its position relative to screen centre. Centre page = flat; ±1 page = 90° (edge-on, hidden).
        @objc func applyCube() {
            guard let scroll = internalScroll else { return }
            // Only do per-frame transform work while the pages are actually in motion; at rest this
            // is pure churn at 60-120Hz. The two dismissal flags are here because during a swipe-down
            // the card is being moved by something that is not a page swipe, and a fold derived from
            // page position would then be derived from a lie.
            //
            // ⚠️ `cubeTurnActive` IS IN THE TEST, and without it a TAP folds nothing: a programmatic
            // turn animates the scroll view without ever setting `isDragging`/`isTracking`, and
            // `isDecelerating` is a finger's word, not UIKit's.
            let moving = (scroll.isDragging || scroll.isDecelerating || scroll.isTracking
                          || StoryPager.cubeTurnActive)
                && !StoryPager.dismissActive && !StoryCardMorph.heroDismissActive
            guard moving else {
                // Came to rest (or a dismissal took over): put the pages back flat ONCE, not every
                // frame. Without this a page keeps the last fold it was given and the next thing
                // drawn is a story standing at an angle.
                if cubeApplied { resetCubeTransforms() }
                return
            }
            cubeApplied = true
            let w = scroll.bounds.width
            guard w > 1 else { return }
            // ⚠️ THE PRESENTATION LAYER, NOT THE MODEL, AND ON A TAP IT IS THE WHOLE DIFFERENCE.
            //
            // `contentOffset` and `layer.position` are MODEL values: the instant
            // `setViewControllers(animated: true)` is called they already hold where the turn is
            // going to END, while the pixels are still at the beginning. Reading them, this loop
            // computed the same finished `t` on every frame of the animation and then snapped when
            // the model and the render server finally agreed — a fold that jumps rather than turns,
            // which is the jitter he reported on the tap. A finger drag has no animation, so the two
            // are equal there and the swipe path is unaffected.
            //
            // `presentation()` is nil when nothing is animating, hence the fallbacks.
            let offsetX = (scroll.layer.presentation() ?? scroll.layer).bounds.origin.x
            // THE LANDING BLINK (his slowed-video screenshots, build 542): for ONE frame at the end
            // of a turn the geometry reads a full page-width wrong — the landed story edge-on (a
            // near-black frame) or the story just LEFT drawn flat again (the "photo 1" blink) —
            // then everything is correct. The offset above is a PRESENTATION value and the page
            // positions are MODEL values; they describe the same instant all through the turn,
            // except at the teardown boundary, where UIKit removes its animation and re-centres the
            // queuing scroll view's pages in one transaction. If this link fires between the
            // re-centre and the presentation catching up, the pair disagrees by exactly one page
            // width, and the fold faithfully draws that lie.
            //
            // The guard: a page cannot MOVE half a screen in one frame. The fastest legal
            // programmatic motion — a 0.4s turn on a display link degraded to 30Hz — is ~0.11
            // page/frame, and the glitch is ~1.0. So compute every page's fold first, and refuse
            // the whole frame if any already-tracked page jumped further than half a width; the
            // previous frame's transforms hold for one tick, which no eye can see. Capped at two
            // refusals in a row so a genuine re-base (pages re-centred mid-multi-swipe) can never
            // freeze the cube.
            //
            // ⚠️ THE THRESHOLD IS ABOUT THE GLITCH, NOT ABOUT THE TURN'S SPEED. A hard FINGER flick
            // is not governed by any duration and can momentarily exceed half a page in a frame on
            // a degraded link; two refused frames at the start of such a flick is the price, and it
            // is the right trade against drawing a page a full width out of place.
            var folds: [(sub: UIView, relX: CGFloat, t: CGFloat)] = []
            var jumped = false
            for sub in scroll.subviews {
                guard abs(sub.bounds.width - w) < 1.0 else { continue }   // page-sized views only
                // Read the UNTRANSFORMED position (layer.position is the layout anchor, unaffected by our
                // transform), NOT sub.frame.minX — once a 3D transform is set, `frame` becomes the transformed
                // bounding box, so reading it back fed our own rotation into the next frame's math. That
                // feedback loop was the SHAKE, and its drift pushed pages off-screen → the BLACK flash.
                let pageMinX = (sub.layer.presentation() ?? sub.layer).position.x - sub.bounds.width / 2
                let relX = pageMinX - offsetX                             // page's screen-x (0 = centred, ±w = neighbour)
                let t = relX / w
                // ⚠️ A PAGE SEEN FOR THE FIRST TIME IS SEEDED, NOT DRAWN, AND THAT IS THE OTHER END
                // OF THE LANDING BLINK. The jump guard is `if let last` — a page with no history
                // cannot trip it — and the page that arrives with a turn is exactly the one
                // guaranteed to read wrong on its first frame: the scroll's layer is committed and
                // animating so it answers with a PRESENTATION offset, while the just-added page has
                // not been committed yet and falls back to its MODEL position, which is already the
                // final one. The pair disagrees by a full page width, and the fold draws it.
                //
                // Recording it without applying costs the arriving page one frame at identity, which
                // is where it starts anyway.
                if lastCubeT[ObjectIdentifier(sub)] == nil, StoryPager.cubeTurnActive {
                    lastCubeT[ObjectIdentifier(sub)] = t
                    continue
                }
                if let last = lastCubeT[ObjectIdentifier(sub)], abs(t - last) > 0.5 { jumped = true }
                folds.append((sub, relX, t))
            }
            if jumped, cubeSkipStreak < 2 {
                cubeSkipStreak += 1
                return
            }
            cubeSkipStreak = 0
            for (sub, relX, t) in folds {
                lastCubeT[ObjectIdentifier(sub)] = t
                sub.layer.isDoubleSided = false                            // hide the back face
                // THE FACE DARKENS AS IT TURNS — their numbers, see `tint(for:)`. Driven by the same
                // fraction as the fold, so the shading and the geometry cannot disagree.
                if let g = tint(for: sub) {
                    g.frame = sub.bounds
                    if t < 0 {
                        g.startPoint = CGPoint(x: 0, y: 0); g.endPoint = CGPoint(x: 1, y: 0)
                    } else if t > 0 {
                        g.startPoint = CGPoint(x: 1, y: 0); g.endPoint = CGPoint(x: 0, y: 0)
                    }
                    g.opacity = Float(min(1.0, abs(t) * 1.3))
                }
                if abs(t) > 1.0 {
                    // ⚠️ FURTHER AWAY THAN ONE PAGE: PUT IT BACK FLAT, do not leave it. There was no
                    // `else` here, so such a page kept whatever rotation it last had AND an
                    // `undoSlide` computed from a stale position — pinned to a screen location that
                    // no longer matched the scroll — while the tint above had already been written
                    // to fully opaque black. Normally it is off-screen or back-facing and hides;
                    // the moment the geometry is briefly wrong it is a solid black slab that does
                    // not move with the finger.
                    sub.layer.transform = CATransform3DIdentity
                    tint(for: sub)?.opacity = 0
                } else if abs(t) < 0.001 {
                    sub.layer.transform = CATransform3DIdentity            // resting page is pixel-perfect
                } else {
                    // Undo the scroll's flat slide FIRST, then rotate — so the cube anchors to the screen
                    // edge instead of stacking rotation on top of the slide. The transform drives the cube from
                    // the pan alone with no scroll translation underneath (confirmed from StoryContainerScreen);
                    // this makes our UIPageViewController scroll behave the same way visually.
                    let undoSlide = CATransform3DMakeTranslation(-relX, 0, 0)
                    sub.layer.transform = CATransform3DConcat(StoryPager.cubeTransform(t, width: w), undoSlide)
                }
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
            guard let pager, let card = internalScroll else { return }
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
final class StoryPagerVC: UIPageViewController {
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isBeingDismissed { view.backgroundColor = .clear }
    }
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        view.backgroundColor = .black
    }
}

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
    let pager: StoryPagerVC

    init(pager: StoryPagerVC) {
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
