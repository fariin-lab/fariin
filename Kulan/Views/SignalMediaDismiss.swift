import SwiftUI
import UIKit

// Interactive media dismiss — an interactive-dismiss + dismiss-animation controller pair:
//   • ONE vertical DirectionalPanGestureRecognizer on the presented viewer's root view.
//   • On begin, the live SwiftUI content is hidden ONCE and a LIGHTWEIGHT COPY of the media moves —
//     an image copy when available (a media transition image view), else a live snapshot of the
//     media's screen region. The copy sits in a shadow container (black 20%, offset (0,32), radius 48).
//   • Finger lock: copy.center = fromFrame.center + RAW translation, 1:1 both axes. The 0.8 scale and
//     shadow are a 0.2s "cock" scrubbed inside the 0.25s interactive timeline → they complete at
//     progress 0.8 and are NOT recomputed as functions of position.
//   • progress = clamp01(hypot(dx, dy) / 88)  (distanceToCompletion = 88pt).
//   • The presented root's alpha (black bg + chrome, media hidden) driven DIRECTLY from progress —
//     Signal's fromView.alpha scrub. Zero per-frame SwiftUI work.
//   • Release: FINISH on any progress (percentComplete > 0 — no velocity gate) with the 0.25s
//     critically-damped spring toward a no-destination fallback frame (fromFrame shifted
//     down by its height); gesture-cancel springs everything back.
// Shared by the image viewer AND the video player — one code path.
struct SignalDismissHost: UIViewRepresentable {
    var canBegin: () -> Bool                                  // e.g. current page at min zoom
    var media: () -> (frame: CGRect, image: UIImage?)?        // fitted media rect (screen coords) + image if loaded
    var onHideContent: (Bool) -> Void                         // hide/show the live SwiftUI viewer (once per gesture)
    /// Where the media came from (the thumbnail's global rect), if known. Given one, the release
    /// FLIES THE COPY HOME into that rect instead of fading out mid-air — so a drag-down close lands
    /// exactly on the tile it opened from, which is what the system zoom transition failed to do
    /// (it shrank the whole black viewer, so the photo only lined up at the very end).
    var targetRect: () -> CGRect? = { nil }
    /// The message id behind `targetRect`. Needed for two things the rect alone cannot give: the tile's
    /// REAL corner radius, and the ability to hide that tile while the copy is flying onto it.
    var targetId: () -> String? = { nil }
    /// The region the copy may draw in at the BUBBLE end of the flight (the visible message viewport,
    /// window coords) — Signal's `clippingAreaInsets`. Given one, the landing is clipped through it, so
    /// a copy flying home to a bubble half-scrolled under the header disappears BEHIND the bar instead
    /// of landing on top of it. The open (SignalMediaOpen.fly) takes the same rect as `clip:`.
    var clipRect: () -> CGRect? = { nil }
    /// Bump to run the BUTTON close through the same pipeline as the drag close: the copy flies home
    /// into its tile with the same landing spring (user report: the arrow used a different exit than
    /// the drag). Signal's model too — their X runs the same dismiss animator the pan drives.
    var closeToken: Int = 0
    var onDismiss: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIView {
        let v = Marker()
        v.isUserInteractionEnabled = false
        v.isHidden = true
        v.coordinator = context.coordinator
        return v
    }
    func updateUIView(_ v: UIView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.noteCloseToken(closeToken)
    }

    final class Marker: UIView {
        weak var coordinator: Coordinator?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil { coordinator?.install(from: self) }
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: SignalDismissHost
        private weak var root: UIView?
        private var container: UIView?
        private var clipWrap: UIView?      // landing-only clipping view (the chat viewport), see finish()
        private var fromFrame: CGRect = .zero
        private var active = false
        private static let distanceToCompletion: CGFloat = 88    // visual scrub (scale/alpha) reference
        // Commit thresholds. Were 160pt / 800 — that much travel made closing feel like work (user:
        // "too hard"). Telegram and WhatsApp commit around a short drag or any real flick, so a normal
        // downward swipe should already mean "close". Changing your mind still works: the decision uses
        // the NET downward offset, so dragging back up above the threshold cancels.
        // Signal's own rule is `percentComplete > 0` — ANY movement commits and cancel is effectively
        // unreachable (MediaInteractiveDismiss `.ended`). We deliberately do NOT copy that: being able
        // to drag down, change your mind and have it spring back is behaviour the user asked for and
        // liked. Instead the threshold is small enough that a deliberate short drag closes, which is
        // what "it must work like Signal" actually means in feel.
        // (The 40pt / 320pt-per-second commit thresholds are gone — see `.ended`. Signal commits on any
        // real movement, and so does this app's own profile photo viewer, the one that already feels right.)

        init(_ p: SignalDismissHost) { parent = p }

        func install(from marker: UIView) {
            guard root == nil, let vc = marker.owningViewController else { return }
            root = vc.view
            let g = DirectionalPanGestureRecognizer(direction: .vertical, target: self, action: #selector(handle(_:)))
            g.delegate = self
            vc.view.addGestureRecognizer(g)
            // The viewer may be presented with a native .zoom transition (hero open from the bubble).
            // That transition installs its OWN interactive-dismiss pan/pinch on the presentation chain,
            // and that drag moves the WHOLE card — chrome, thumbnails, everything — over a moving
            // presenter (the user rejected exactly this). Disable those so THIS pan is the only dismiss
            // drag: only the media copy moves, the page behind never does. The zoom OPEN animation and
            // the programmatic shrink-into-bubble close are untouched — they're the animator, not the
            // gesture. Run again after the presentation settles: the system can attach its gestures late.
            // The blanket gesture-disabling that used to run here is GONE. It existed only to fight the
            // system `.zoom` transition's own interactive dismiss, and that transition is no longer used
            // for chat media anywhere — the album viewer was the last holdout and it now flies through
            // SignalMediaOpen like everything else. What it actually did was walk the whole presentation
            // chain and switch off EVERY pan and pinch that was not ours, twice, one of them 0.7s late.
            // Disabling gestures wholesale to protect one gesture is how a viewer ends up feeling dead in
            // ways nobody can trace, and there is nothing left for it to protect against.
        }


        // Coexist with the pager + zoom scroll views (coordinated via delegation the same way); we gate
        // on canBegin, and the directional recogniser FAILS on horizontal intent — which it only really
        // does since 2026-07-29. It used to judge direction from the delta since the last touch sample
        // and merely decline to engage on a horizontal one, staying `.possible` and armed for the rest
        // of the swipe. Simultaneous recognition then meant a sideways drag was being contested the
        // whole way across, and one wobbly frame handed it to the dismiss outright.
        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

        // The shared copy builder: the drag's .began and the button close construct the IDENTICAL
        // flying copy, so the two exits cannot drift apart.
        //
        // ONE geometry base for both directions: the open fits the media into the WINDOW's bounds; the
        // viewers' closures were fitting into `UIScreen.main.bounds`. Identical on a full-screen iPhone
        // cover, but recomputing against this root keeps the promise by construction.
        //
        // The copy lives in the WINDOW, above the presented root, so the root itself can be faded as
        // one unit — the viewer's own black background and chrome ARE the thing that fades (Signal's
        // `fromView.alpha` scrub). The viewer only hides its MEDIA; the copy replaces those pixels.
        @discardableResult
        private func buildCopy(_ m: (frame: CGRect, image: UIImage?)) -> UIView? {
            guard let root, let win = root.window else { return nil }
            fromFrame = m.image.map { mediaFitRect($0.size, in: root.bounds) } ?? m.frame

            // The lightweight copy: the image itself when loaded (a media transition image view),
            // else a live snapshot of the media's region (videos without a poster).
            let content: UIView
            if let img = m.image {
                let iv = UIImageView(image: img)
                iv.contentMode = .scaleAspectFill
                iv.clipsToBounds = true
                content = iv
            } else {
                content = root.resizableSnapshotView(from: m.frame, afterScreenUpdates: false,
                                                     withCapInsets: .zero) ?? UIView()
            }
            // Shadow container (plain UIView so it can carry both corners and shadow).
            let c = UIView(frame: fromFrame)
            c.layer.shadowColor = UIColor.black.withAlphaComponent(0.2).cgColor   // ows_blackAlpha20
            c.layer.shadowOffset = CGSize(width: 0, height: 32)
            c.layer.shadowRadius = 48
            c.layer.shadowOpacity = 0
            content.frame = c.bounds
            content.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            c.addSubview(content)
            win.addSubview(c)
            container = c
            return c
        }

        // The BUTTON close, through the drag's pipeline (user report: the arrow used a different
        // exit). Builds the same copy, hides the same things, runs the same landing spring — one
        // pipeline for every way out. Falls back to a plain dismiss when there is no geometry to fly,
        // so the close is never hostage to a missing rect or image.
        private var lastCloseToken = 0
        func noteCloseToken(_ t: Int) {
            guard t != lastCloseToken else { return }
            let adoptingMidLife = lastCloseToken == 0 && t > 1   // (re)attach to a viewer that closed before
            lastCloseToken = t
            guard t > 0, !adoptingMidLife else { return }
            closeNow()
        }
        private func closeNow() {
            guard !active, parent.canBegin(), let m = parent.media(), buildCopy(m) != nil else {
                parent.onDismiss()
                return
            }
            active = true
            parent.onHideContent(true)
            MediaSourceVisibility.shared.hide(parent.targetId())
            finish(offset: .zero)
        }

        @objc private func handle(_ g: UIPanGestureRecognizer) {
            guard let root else { return }
            switch g.state {
            case .began:
                guard !active, parent.canBegin(), let m = parent.media(), buildCopy(m) != nil else { return }
                active = true
                // Signal zeroes the translation on .began (MediaInteractiveDismiss). Without it the
                // first .changed already carries the recogniser's pre-recognition slop, so the copy
                // JUMPS by ~10pt the instant the drag is picked up instead of starting under the finger.
                g.setTranslation(.zero, in: root)
                parent.onHideContent(true)   // exactly ONE SwiftUI update for the whole gesture
                // Hide the tile we are flying towards. Without this the copy converges onto an
                // already-visible thumbnail, so for a moment the same photo is on screen twice and there
                // is no cross-fade at the landing.
                MediaSourceVisibility.shared.hide(parent.targetId())

            case .changed:
                guard active, let c = container else { return }
                let o = g.translation(in: root)
                let progress = min(1, max(0, hypot(o.x, o.y) / Self.distanceToCompletion))
                // 1:1 finger lock (center = fromFrame.offsetBy(offset).center) — both axes, raw.
                c.center = CGPoint(x: fromFrame.midX + o.x, y: fromFrame.midY + o.y)
                // The constant 0.8 scale + shadow: a 0.2s cock inside the 0.25s timeline → both
                // complete at progress 0.8 (scrubbed, not recomputed from position).
                let t = min(1, progress / 0.8)
                c.transform = CGAffineTransform(scaleX: 1 - 0.2 * t, y: 1 - 0.2 * t)
                c.layer.shadowOpacity = Float(t)
                // Background AND chrome melt together with the drag: the presented root (black bg +
                // header + toolbar, media already hidden) is faded as one unit over the live chat —
                // Signal's fromView.alpha scrub. Chrome used to vanish instantly here instead.
                root.alpha = 1 - t

            case .ended:
                guard active else { return }
                let o = g.translation(in: root)
                let v = g.velocity(in: root)
                // The completion decision (shouldCompleteTransition): finish ONLY if the media was
                // dragged past the dismiss threshold OR flung downward fast; otherwise CANCEL and spring
                // it back to exactly where it came from. This is what lets you drag down, change your
                // mind, drag back up, and fully recover — the net downward offset is what counts, so
                // dragging back above the threshold cancels. The release velocity is handed to the
                // spring either way, so the motion CONTINUES the finger instead of restarting from zero.
                // 2D length, matching the SCRUB. The visual progress above uses hypot on both axes but
                // the commit test used o.y alone, so a diagonal drag could scrub the photo most of the way
                // out and then snap all the way back. The 40pt / 320 thresholds themselves are the user's
                // deliberate choice (Signal commits on ANY movement) and are unchanged.
                // SIGNAL'S RULE, ADOPTED. Their `.ended` is `percentComplete > 0` — any real movement
                // commits. Ours demanded 40pt of travel OR a 320pt/s flick, and that gap is the "still
                // doesn't feel like Signal" the user has reported for days: a short, deliberate drag
                // scrubbed the photo partway out and then snapped all the way back, which reads as the
                // gesture refusing you.
                //
                // The proof it is the threshold and not the maths: this app's OTHER media viewer, the
                // profile photo one the user says works correctly, is plain SwiftUI with none of this
                // machinery — and it commits on `dist > 0`. Same gesture, same app, one rule apart.
                //
                // Cancel stays reachable, which is the one thing the user liked and Signal does not
                // really offer: drag back UP past where you started and the net offset goes negative, so
                // it springs home. Anything with real downward intent closes.
                if o.y > 0 {
                    finish(offset: o, velocity: v)
                } else {
                    cancel(velocity: v)
                }

            case .cancelled, .failed:
                guard active else { return }
                cancel()

            default: break
            }
        }

        // Normalized spring velocity (UISpringTimingParameters expects velocity as a FRACTION of the
        // remaining travel per second) so the animation takes over at exactly the finger's speed.
        private static func springVelocity(_ v: CGPoint, from: CGPoint, to: CGPoint) -> CGVector {
            let dx = to.x - from.x, dy = to.y - from.y
            return CGVector(dx: abs(dx) > 1 ? v.x / dx : 0, dy: abs(dy) > 1 ? v.y / dy : 0)
        }

        // Dismiss (damping 1): the root is already melted past the threshold (the chat shows behind),
        // so the copy fades out from RIGHT WHERE IT WAS RELEASED with a small continued drift + shrink —
        // seeded with the release velocity so it carries the finger's motion. Then dismiss.
        private func finish(offset o: CGPoint, velocity: CGPoint = .zero) {
            guard let c = container else { return }
            active = false

            // FLY HOME when we know where the media came from: the copy scales and travels into the
            // thumbnail's exact rect and only fades at the very end, so it visibly "lands" on the tile.
            // The rect must still be ON SCREEN. `MediaOpenRects` keeps the last reported rect with no
            // liveness check, so after scrolling the source bubble away the copy used to fly to a
            // stale offscreen position. Signal detects the missing context and falls back to dropping
            // straight down by one media height — do the same.
            let reported = parent.targetRect()
            let rootBounds = c.superview?.bounds ?? .zero
            let onScreen = reported.map { $0.intersects(rootBounds) } ?? false
            if let home = reported, onScreen, home.width > 1, home.height > 1 {
                // THE LANDING IS CLIPPED THROUGH THE CHAT VIEWPORT, exactly Signal's clipping view
                // (MediaDismissAnimationController: `clippingView.frame = containerView.bounds.inset(by:
                // toContext.clippingAreaInsets)` inside the spring). The wrap starts as the full root —
                // no visual change at reparent time — and shrinks to the viewport while the copy flies,
                // so a copy landing on a bubble half under the header slides BEHIND the bar. Both frames
                // animate in the same block, which is what makes the child's coordinates interpolate
                // through the moving clip the way Signal's do.
                var clipTarget: CGRect?
                if let clip = parent.clipRect(), let rootView = c.superview,
                   clip.width > 1, clip.height > 1, clip != rootView.bounds {
                    let wrap = UIView(frame: rootView.bounds)
                    wrap.clipsToBounds = true
                    rootView.addSubview(wrap)
                    wrap.addSubview(c)         // wrap sits at the root's origin → same on-screen frame
                    clipWrap = wrap
                    clipTarget = clip
                }
                // Destination expressed in the wrap's END-of-animation coordinates when clipped.
                let homeInWrap = clipTarget.map { home.offsetBy(dx: -$0.minX, dy: -$0.minY) } ?? home
                let center = CGPoint(x: homeInWrap.midX, y: homeInWrap.midY)
                // Resolved OUTSIDE the animation closure: reading `parent` inside it needs an explicit
                // self capture, and the value cannot change mid-flight anyway.
                let landingRadius = parent.targetId().map { MediaOpenRects.cornerRadius($0) } ?? 14
                let spring = UISpringTimingParameters(
                    dampingRatio: 1,     // Signal: springDamping 1, no overshoot on a landing
                    initialVelocity: Self.springVelocity(velocity, from: c.center, to: center))
                let animator = UIViewPropertyAnimator(duration: 0.25, timingParameters: spring)
                let wrapTarget = clipTarget
                animator.addAnimations {
                    // FRAME match with transform identity, the way Signal lands
                    // (MediaDismissAnimationController: `frame = destinationFrame`, `transform =
                    // .identity`). The old version kept a transform SCALE derived from min(w,h) ratios,
                    // which cannot match a tile of a different aspect — the copy arrived the wrong
                    // shape. cornerRadius also did nothing without masksToBounds.
                    if let wrapTarget { self.clipWrap?.frame = wrapTarget }
                    c.transform = .identity
                    c.frame = CGRect(x: center.x - homeInWrap.width / 2, y: center.y - homeInWrap.height / 2,
                                     width: homeInWrap.width, height: homeInWrap.height)
                    // The tile's OWN radius, not a hardcoded 14 - media whose bubble uses a different
                    // radius visibly changed shape at the moment the copy took over.
                    c.layer.cornerRadius = landingRadius
                    c.layer.shadowOpacity = 0
                    // The rest of the viewer (black + chrome) finishes melting over the land —
                    // Signal's final spring does exactly this to fromView.
                    self.root?.alpha = 0
                }
                c.layer.masksToBounds = true   // without this the corner radius was invisible
                // NO alpha fade: Signal lands the copy opaque and swaps it for the real thumbnail.
                // Fading it out at 0.8 was what made the return read as "vanishing near the tile".
                animator.addCompletion { _ in
                    // Reveal the tile BEFORE the copy goes, so the two overlap for a frame and the swap
                    // is invisible. Revealing after would flash the empty tile.
                    MediaSourceVisibility.shared.reveal()
                    self.parent.onDismiss()
                    // The copy lives in the WINDOW now, so the cover's teardown no longer removes it.
                    // Drop it a tick later, once the dismissal has the real content underneath.
                    DispatchQueue.main.async {
                        (self.clipWrap ?? self.container)?.removeFromSuperview()
                        self.clipWrap = nil
                        self.container = nil
                    }
                }
                animator.startAnimation()
                return
            }

            // No known source (e.g. opened from somewhere that doesn't report a rect): the original
            // Signal behaviour — drift on and fade out from where the finger let go.
            // Leave the SCREEN rather than evaporating on the spot. Drifting 40pt while fading read as
            // the photo dissolving in mid-air; carrying it a full frame-height down is an exit.
            let target = CGPoint(x: fromFrame.midX + o.x,
                                 y: fromFrame.midY + o.y + fromFrame.height)
            let spring = UISpringTimingParameters(dampingRatio: 1,
                                                  initialVelocity: Self.springVelocity(velocity, from: c.center, to: target))
            let animator = UIViewPropertyAnimator(duration: 0.25, timingParameters: spring)
            animator.addAnimations {
                c.center = target
                c.transform = CGAffineTransform(scaleX: 0.72, y: 0.72)
                c.layer.shadowOpacity = 0
                self.root?.alpha = 0
            }
            animator.addCompletion { _ in
                self.parent.onDismiss()
                // The copy is in the window, not the cover — remove it ourselves.
                DispatchQueue.main.async {
                    self.container?.removeFromSuperview()
                    self.container = nil
                }
            }
            animator.startAnimation()
        }

        // Cancel: a critically-damped spring back home that CONTINUES the release velocity (Signal's
        // interactive-dismiss recovery), then restore the live content. Signal animates center +
        // transform only — the old path also animated the FRAME while the transform was mid-flight,
        // and frame math under a non-identity transform is what made the snap-back visibly choppy.
        private func cancel(velocity: CGPoint = .zero) {
            active = false
            guard let c = container else { parent.onHideContent(false); return }
            let home = CGPoint(x: fromFrame.midX, y: fromFrame.midY)
            let spring = UISpringTimingParameters(dampingRatio: 1,
                                                  initialVelocity: Self.springVelocity(velocity, from: c.center, to: home))
            let animator = UIViewPropertyAnimator(duration: 0.26, timingParameters: spring)
            animator.addAnimations {
                c.center = home
                c.transform = .identity
                c.layer.shadowOpacity = 0
                // Background and chrome fade back in together, the reverse of the drag's scrub.
                self.root?.alpha = 1
            }
            animator.addCompletion { _ in
                self.parent.onHideContent(false)
                // Un-hide the source bubble. The drag's .began hid it, and only finish() ever revealed
                // it — a CANCELLED drag left the bubble invisible in the chat, which showed the moment
                // the viewer was later closed with the X instead of another drag.
                MediaSourceVisibility.shared.reveal()
                c.removeFromSuperview()
                self.container = nil
            }
            animator.startAnimation()
        }
    }
}

// Aspect-fit rect of media with size `media` centered in `bounds` (the copy's start frame).
func mediaFitRect(_ media: CGSize, in bounds: CGRect) -> CGRect {
    guard media.width > 0, media.height > 0 else { return bounds }
    let s = min(bounds.width / media.width, bounds.height / media.height)
    let size = CGSize(width: media.width * s, height: media.height * s)
    return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                  width: size.width, height: size.height)
}

// MARK: - Open (the mirror of the drag-close above)

/// Flies a media copy from its bubble to its fullscreen position, then reveals the viewer.
///
/// WHY THIS EXISTS. Opening used SwiftUI's `.navigationTransition(.zoom)`, which scales the ENTIRE
/// presented cover — black backdrop, header, thumb strip, toolbar — out of the bubble. Signal instead
/// moves only the MEDIA, inside a clipping view, and cross-fades the backdrop
/// (MediaZoomAnimationController). That is the whole difference, and it is why our open never matched
/// theirs no matter how the timing was tuned.
///
/// It deliberately lives in this file, next to the close, because the two must agree: same geometry
/// source (`MediaOpenRects` / `mediaFitRect`), same spring, same copy construction. An earlier attempt
/// at this was a SwiftUI per-frame animation, which is why it felt different from the close even when
/// the numbers matched — SwiftUI cannot hold a 1:1 frame animation the way a property animator does.
@MainActor
enum SignalMediaOpen {

    /// Signal's spring, from SignalUI/UIKitExtensions/UIKit+Animations.swift:
    /// `springDamping: 1, springResponse: 0.25` is NOT `usingSpringWithDamping` — it expands to
    /// `stiffness = (2π / response)²` and `damping = 4π · damping / response` at mass 1, i.e. a
    /// critically damped spring. Reaching for `usingSpringWithDamping:` here is the usual way to get
    /// this subtly wrong: it is a different parameterisation and produces a visibly different curve.
    /// Neither of Signal's animation controllers seeds an initial velocity, and that is deliberate.
    static let duration: TimeInterval = 0.25
    static var spring: UISpringTimingParameters {
        let response: CGFloat = 0.25, damping: CGFloat = 1
        return UISpringTimingParameters(mass: 1,
                                        stiffness: pow(2 * .pi / response, 2),
                                        damping: 4 * .pi * damping / response,
                                        initialVelocity: .zero)
    }

    private static var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first
    }

    /// Fly out of the bubble if the media can be resolved from ANY cache tier; present plainly only if
    /// it genuinely is not cached at all.
    ///
    /// THE MEMORY CACHE IS NOT A PRECONDITION, and treating it as one was a real bug (user report on
    /// build 400: "after putting the app in the background and reopening it, tapping an image animates
    /// from the bottom of the screen instead of from its bubble"). Every call site used to read
    /// `DiskImageCache.memoryImage(url)` — a synchronous MEMORY-ONLY lookup — and fall back to a plain
    /// presentation when it returned nil. But that tier is an `NSCache`, which iOS empties under memory
    /// pressure and when the app is backgrounded, so after returning to the app the first tap on every
    /// photo took the fallback. The image was never gone; it was one tier down, on disk, where the
    /// bubble itself was already reading it from.
    ///
    /// So resolve it properly. A memory hit still flies on the same frame as the tap. A miss costs one
    /// off-main disk read plus decode, which also promotes it back into memory, so only the first tap
    /// after a return pays it — and it pays a frame or two, not a different animation.
    static func flyOrPresent(imageUrl: String?,
                             rectKey: String,
                             clip: CGRect? = nil,
                             present: @escaping () -> Void) {
        guard let imageUrl, MediaOpenRects.rect(rectKey) != nil else { present(); return }
        if let img = DiskImageCache.shared.memoryImage(imageUrl) {
            flyFromRegistry(img, rectKey: rectKey, clip: clip, present: present)
            return
        }
        // Not in memory. Ask the zero-IO disk index BEFORE going async: media that genuinely is not
        // cached anywhere (still downloading) must open exactly as promptly as it always did, rather
        // than paying for a disk read that was always going to come back empty.
        guard DiskImageCache.shared.isCached(imageUrl) else { present(); return }
        Task { @MainActor in
            guard let img = await DiskImageCache.shared.image(for: imageUrl) else { present(); return }
            // Re-read the rect rather than closing over the old one: a few tens of milliseconds is
            // enough for the list to have moved, and flying from a stale rect is the "wrong area"
            // class of bug this registry exists to prevent.
            flyFromRegistry(img, rectKey: rectKey, clip: clip, present: present)
        }
    }

    private static func flyFromRegistry(_ image: UIImage, rectKey: String,
                                        clip: CGRect?, present: @escaping () -> Void) {
        guard let rect = MediaOpenRects.rect(rectKey) else { present(); return }
        fly(image: image, from: rect,
            sourceCornerRadius: MediaOpenRects.cornerRadius(rectKey),
            clip: clip, present: present)
    }

    /// - Parameters:
    ///   - image: the media to fly. Videos pass their poster — Signal flies a still frame for video too,
    ///            never a layer and never a snapshot of the screen.
    ///   - source: the bubble's rect in window coordinates (`MediaOpenRects`).
    ///   - sourceCornerRadius: the bubble's radius, interpolated to 0 as it fills the screen.
    ///   - clip: the region the source is allowed to draw in — the message list's frame. A bubble half
    ///           scrolled under the header must not appear to fly OVER the header, which is exactly what
    ///           a transition with no clipping view does.
    ///   - present: reveals the real viewer. Called with the copy still on screen and matching it exactly.
    static func fly(image: UIImage,
                    from source: CGRect,
                    sourceCornerRadius: CGFloat = 14,
                    clip: CGRect? = nil,
                    present: @escaping () -> Void) {
        guard let window = keyWindow, source != .zero, !source.isEmpty else {
            present()   // no geometry to fly from — never block opening the viewer
            return
        }

        let destination = mediaFitRect(image.size, in: window.bounds)

        // Backdrop, fading in underneath the media exactly as the close fades it out.
        let backdrop = UIView(frame: window.bounds)
        backdrop.backgroundColor = .black
        backdrop.alpha = 0
        backdrop.autoresizingMask = [.flexibleWidth, .flexibleHeight]

        // The clipping view. Starts as the region the bubble lives in and grows to the whole window, so
        // the media is revealed from behind the bars rather than flying over them.
        let clipView = UIView(frame: clip ?? window.bounds)
        clipView.clipsToBounds = true

        let container = UIView(frame: clipView.convert(source, from: window))
        container.clipsToBounds = true
        container.layer.cornerRadius = sourceCornerRadius
        container.layer.cornerCurve = .continuous

        let content = UIImageView(image: image)
        // scaleAspectFill + clipping is what reconciles the two aspect ratios: the bubble renders the
        // photo filled and cropped, the viewer renders it fitted. Animating the frame between the two
        // rects with this content mode makes the crop resolve continuously instead of snapping.
        content.contentMode = .scaleAspectFill
        content.clipsToBounds = true
        content.frame = container.bounds
        content.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(content)

        window.addSubview(backdrop)
        window.addSubview(clipView)
        clipView.addSubview(container)

        let animator = UIViewPropertyAnimator(duration: duration, timingParameters: spring)
        animator.addAnimations {
            clipView.frame = window.bounds
            container.frame = destination
            container.layer.cornerRadius = 0
            backdrop.alpha = 1
        }
        // cornerRadius is a CALayer property and does not ride a UIView animation block on its own.
        let radius = CABasicAnimation(keyPath: "cornerRadius")
        radius.fromValue = sourceCornerRadius
        radius.toValue = 0
        radius.duration = duration
        radius.timingFunction = CAMediaTimingFunction(name: .easeOut)
        container.layer.add(radius, forKey: "cornerRadius")

        animator.addCompletion { _ in
            // Reveal the viewer while the copy still covers the same pixels, then drop the copy a tick
            // later. Presenting first would put the viewer OVER the copy mid-flight; removing the copy
            // first would show one frame of the chat underneath. Neither order flashes if they overlap.
            withoutPresentationAnimation { present() }
            DispatchQueue.main.async {
                backdrop.removeFromSuperview()
                clipView.removeFromSuperview()
            }
        }
        animator.startAnimation()
    }
}
