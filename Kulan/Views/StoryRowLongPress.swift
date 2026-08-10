import SwiftUI
import UIKit
import QuartzCore   // CACurrentMediaTime, for StoryRowPress's quiet window

//
// THE STORIES ROW'S LONG PRESS, ON THE APP'S OWN MENU.
//
// He asked for this and it was never started (build-state, "OPEN, HIS CALL (b)"): the row's long
// press in UIKit, with a real lifted preview per card instead of SwiftUI's `.contextMenu`.
//
// WHAT WAS WRONG WITH THE SwiftUI ONE. `.contextMenu(menuItems:preview:)` does not lift the card —
// it BUILDS A SECOND ONE from the `preview:` closure. So the thing that rose off the row was a
// freshly constructed copy: its `StoryImage` started loading again (a beat of empty card on a cold
// cache), its avatar sat in a different place than the real card's, and it wore a caption the card
// itself does not have. Two views that have to look identical, maintained by hand, which is the
// mistake this codebase keeps writing down.
//
// WHAT THIS DOES INSTEAD. One `UILongPressGestureRecognizer` on the row's own scroll view, and the
// lift is a photograph of the card that is actually on screen — the same window-crop the story
// flight wears (`StoryCardShot`), at the card's own 24pt continuous radius. The menu is `CMOverlay`,
// the app's own long-press menu, so the row and the conversation now press the same way: one
// system, one set of numbers, one place to fix anything either of them gets wrong.
//
// ONE RECOGNISER, ON AN ANCESTOR, and both halves of that matter. A recogniser attached to a view
// laid OVER the card would have to be hit-testable, and then the card's own Button would never see
// a plain tap. On the scroll view it sees every press in the row without taking anything away: a
// tap never reaches the 0.2s threshold, so `cancelsTouchesInView` never fires and the tap opens the
// story as before; a real press recognises, UIKit cancels the touch the Button was tracking, and
// the story does NOT open behind the menu when the finger lifts.
//
// See [[kulan-story-row-isolation-rule]]: this area ships alone.
//

/// THE BELT FOR THE SAME BUG, because the gesture rule above depends on SwiftUI's Button being a
/// UIGestureRecognizer we can out-rank, and that is an implementation detail of a framework rather
/// than a promise. If a future SwiftUI drives its taps some other way, refusing simultaneity stops
/// meaning anything and the story opens on release again.
///
/// So the row's own open ALSO declines while a press owns the finger. The window extends past the
/// lift because a Button's action fires on touch-up, which is the same instant the recogniser ends,
/// and nothing orders those two.
enum StoryRowPress {
    private static var active = false
    private static var quietUntil: CFTimeInterval = 0

    static var swallowsTap: Bool { active || CACurrentMediaTime() < quietUntil }

    static func began() { active = true }
    static func ended() {
        active = false
        quietUntil = CACurrentMediaTime() + 0.35
    }
}

/// What a press on the row found: which card, where it is, and what its menu should say.
struct StoryMenuTarget {
    /// `MediaOpenRects` key, so the real card can be hidden while its picture is lifted.
    let key: String
    let rect: CGRect            // window space
    let actions: [CMAction]
    /// THE NAME UNDER THE CARD, in window space, and nil for a card that has none.
    ///
    /// His 2026-08-08 report: "also show Name". The lift used to be the picture alone, so pressing a
    /// card took the person's name away for as long as the menu was up — the one thing on the card
    /// that says WHOSE story you are about to hide. It is photographed as a second strip rather than
    /// included in the card's crop, because the card is rounded and the name is not: one image with
    /// one corner radius would round the bottom of the label.
    var labelRect: CGRect? = nil
    /// THE LABEL ITSELF, so its picture can be taken from its OWN layer tree rather than off the
    /// window. A window crop is right for the card (its pixels are a photo, a ring and a badge
    /// composited by the row) but wrong for the name: a `UILabel` draws only glyphs, and everything
    /// around them in a window crop is the CHAT LIST — white in light mode. That is the white box
    /// he circled on 2026-08-08, "make it only text". Rendered from the label, the strip is
    /// transparent everywhere the text is not. See `StoryCardShot.render`.
    var labelView: UIView? = nil
}

/// A picture of what is really on screen inside `rect`.
///
/// THE WINDOW IS PHOTOGRAPHED AND CROPPED, NOT THE CARD'S OWN VIEW, and that is not a shortcut. The
/// row registers an ANCHOR with `MediaOpenRects` — a `.background {}` view whose frame is the card's
/// and which draws nothing — and `drawHierarchy` renders the receiver's own hierarchy, so
/// photographing the anchor returns a transparent image. The story flight's cover was blank for its
/// whole life for exactly that reason. Cropping the window takes the pixels the eye is looking at.
enum StoryCardShot {
    /// - Parameter cornerRadius: the radius the SOURCE is drawn with. Anything outside that corner is
    ///   cut out of the picture and comes back transparent. 0 keeps the full rectangle.
    ///
    /// ⚠️ THIS IS WHERE THE WHITE CORNERS DIE, AND IT HAS TO BE HERE.
    ///
    /// The shot is a crop of the WINDOW at the card's rectangle. The card is rounded, so the four
    /// corners of that rectangle are not card at all — they are the chat list behind it, photographed
    /// BEFORE the flight's dim went on. In light mode that is very nearly white (measured off his
    /// screenshot: 247,244,245 against a list that by then reads 226,226,226). Those pixels are part
    /// of the image, so every attempt to fix this downstream has been an attempt to cover them up:
    /// the container mask cannot cut them (it is capped at the story card's own corner, which near
    /// the row end is a couple of points), and rounding the cover LAYER only trades one curve for
    /// another — that fix is what he watched make the rind bigger rather than smaller.
    ///
    /// Cut here, they do not exist. Nothing downstream has to agree with anything, at any scale, at
    /// any fraction, and the corner the flight actually shows is drawn by the cover's own layer as
    /// before — the shape is untouched, only the pixels that were never the card are gone.
    ///
    /// SLIGHTLY ROUNDER THAN ASKED (`* 1.12`), because the source is a SwiftUI continuous squircle
    /// and this path is a circular arc: at the same radius the two enclose different areas, and the
    /// crescent between them is what was left showing. Over-cutting puts that crescent on the
    /// transparent side, where what shows through is the dimmed list the card is flying over — which
    /// is what is behind the card anyway. Under-cutting puts it on the white side, which is the bug.
    static func crop(_ rect: CGRect, in window: UIWindow, cornerRadius: CGFloat = 0) -> UIImage? {
        guard rect.width > 1, rect.height > 1, rect.maxX > 0, rect.maxY > 0 else { return nil }
        // Not opaque: the corners must come out CLEAR, and an opaque format would fill them black —
        // a dark rind in place of a light one is not a fix.
        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = false
        return UIGraphicsImageRenderer(size: rect.size, format: format).image { ctx in
            if cornerRadius > 0.5 {
                let r = min(cornerRadius * 1.12, min(rect.width, rect.height) / 2)
                UIBezierPath(roundedRect: CGRect(origin: .zero, size: rect.size),
                             cornerRadius: r).addClip()
            }
            _ = ctx
            // Shifted so the card lands at the origin. `afterScreenUpdates: false`: the last
            // rendered frame is exactly what is on screen, and a flush would cost the press a frame.
            window.drawHierarchy(in: CGRect(x: -rect.minX, y: -rect.minY,
                                            width: window.bounds.width,
                                            height: window.bounds.height),
                                 afterScreenUpdates: false)
        }
    }

    /// The same picture, taken of a registered view wherever it is now.
    static func crop(_ view: UIView, cornerRadius: CGFloat = 0) -> UIImage? {
        guard let window = view.window else { return nil }
        return crop(view.convert(view.bounds, to: window), in: window, cornerRadius: cornerRadius)
    }

    /// The same picture, rendered from the view's OWN layer tree instead of the window.
    ///
    /// The window crops above photograph WHAT IS ON SCREEN, and they must (the corners cut there
    /// are the pixels behind the card). But a swipe retarget photographs a row card while the
    /// story viewer is standing in front of it, and at that moment the screen IS the story — a
    /// window crop would return story pixels. A covered view still owns its pixels; only the
    /// window flattening loses them. `afterScreenUpdates: false`, same as everything here — the
    /// card was committed long ago, and a flush is the re-entrancy trap `7763494` was about.
    /// ⚠️ Photograph BEFORE hiding: an alpha-0 card renders blank from its own tree too.
    static func render(_ view: UIView, cornerRadius: CGFloat = 0) -> UIImage? {
        let size = view.bounds.size
        guard size.width > 1, size.height > 1, view.window != nil else { return nil }
        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            if cornerRadius > 0.5 {
                let r = min(cornerRadius * 1.12, min(size.width, size.height) / 2)
                UIBezierPath(roundedRect: CGRect(origin: .zero, size: size),
                             cornerRadius: r).addClip()
            }
            view.drawHierarchy(in: CGRect(origin: .zero, size: size), afterScreenUpdates: false)
        }
    }
}

/// Installs the row's press recogniser. Draws nothing and never takes a touch of its own.
struct StoryRowLongPress: UIViewRepresentable {
    /// Which card is under this window point, and what its menu is. Asked at press time, so it
    /// always answers about the row as it stands right now rather than as it stood at layout.
    let target: (CGPoint) -> StoryMenuTarget?

    func makeUIView(context: Context) -> UIView {
        let v = Anchor()
        v.isUserInteractionEnabled = false
        v.backgroundColor = .clear
        v.coordinator = context.coordinator
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.target = target
        (uiView as? Anchor)?.coordinator = context.coordinator
        // A dead press only heals inside an install attempt, and the attempts above fire on
        // reparenting — which is exactly when the damage happens, but not the only time. If the
        // strip's backing scroll view is swapped LATER, with this anchor left where it is, no
        // UIView callback fires at all: this is the one hook that still runs (every SwiftUI
        // re-render of the row), and install is a no-op while the press is alive.
        (uiView as? Anchor)?.heal()
    }

    func makeCoordinator() -> Coordinator { Coordinator(target: target) }

    /// Install and remove on the window change rather than in `dismantleUIView`: this view is the
    /// only thing that knows when the row is really on screen, and a UIView's own callback is
    /// unambiguously on the main actor, which the static teardown hook is not.
    final class Anchor: UIView {
        weak var coordinator: Coordinator?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            // Asked again on every window change: SwiftUI is free to move a representable between
            // containers, and re-asking is free (install is a no-op once it has one).
            if window == nil { coordinator?.uninstall() } else { tryInstall() }
        }
        // ⚠️ A FAILED WALK MUST GET A SECOND CHANCE, and the archive row is why (his 2026-08-09
        // "archive story long press is not working"). `install` climbs the superviews looking for
        // the row's scroll view and — rightly — anchors NOWHERE when it finds none. But
        // `didMoveToWindow` can run while SwiftUI is still assembling the ancestors of a
        // `.background` representable, and the old install was once-only: miss that first walk and
        // `press` stayed nil for the life of the screen, with nothing ever re-asking. The UIKit
        // stories row never sees this because it hands the coordinator its own scroll view
        // directly. So: re-try when the view is re-parented, and once more on the next runloop
        // turn, when the hierarchy this view was being attached into has finished existing.
        // `install` is idempotent, so the retries cost nothing once one of them has landed.
        override func didMoveToSuperview() {
            super.didMoveToSuperview()
            tryInstall()
        }
        /// Re-anchor if the press's host has died — see the liveness check at the top of
        /// `install`. Called from `updateUIView`; a live press makes this a no-op.
        func heal() {
            tryInstall()
        }
        private func tryInstall() {
            guard window != nil, let c = coordinator else { return }
            // THE SCROLL VIEW GETS EVERY CHANCE FIRST. A climb that fails here may only be early —
            // SwiftUI can still be assembling this view's ancestors — so the window fallback is
            // held back until the next runloop turn, by which point the hierarchy this view was
            // being attached into has finished existing. A row that has a scroll view therefore
            // always anchors on it, exactly as before.
            c.install(from: self, allowWindow: false)
            guard !c.isInstalled else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window != nil else { return }
                self.coordinator?.install(from: self, allowWindow: true)
            }
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var target: (CGPoint) -> StoryMenuTarget?
        private weak var overlay: CMOverlay?
        private weak var host: UIView?
        private var press: UILongPressGestureRecognizer?
        /// Whether a recogniser is live — the Anchor's retry loop stops asking once it is.
        var isInstalled: Bool { press != nil }

        init(target: @escaping (CGPoint) -> StoryMenuTarget?) { self.target = target }

        /// Anchored on the WINDOW rather than on a scroll view, so every press must prove it belongs
        /// to this row before it is allowed to begin. See `install`.
        private var gated = false
        /// The view the representable sits in, kept for the gate's "same screen" test.
        private weak var origin: UIView?

        /// `allowWindow`: whether a failed climb may fall back to the window (see below). The UIKit
        /// stories row calls this with a view inside its own scroller and never needs it.
        func install(from view: UIView, allowWindow: Bool = false) {
            // ⚠️ A PRESS WHOSE HOST HAS LEFT THE WINDOW IS NOT INSTALLED, IT IS EMBALMED — the
            // third archive report ("long press archive story plz fix, more days"). The guard
            // below treats any non-nil `press` as job done, but the recogniser lives on `host`,
            // and nothing ever asked whether that view is still on screen. SwiftUI is free to swap
            // the strip's backing scroll view, or to reparent this anchor between hosts WITHOUT
            // dropping its window (didMoveToSuperview fires, didMoveToWindow does not — so the
            // uninstall that handles the window-drop case never runs). Either way the press stays
            // wired to a dead view, `isInstalled` answers true, every later install attempt turns
            // back at the guard, and the screen has no press for the rest of its life — exactly
            // like having none, which is what he keeps photographing. A recogniser on a live host
            // is untouched (the chat row's UIKit scroller never dies), so this is a no-op
            // everywhere the press already worked.
            if press != nil, host == nil || host?.window == nil { uninstall() }
            guard press == nil else { return }
            // The row's own scroll view, found by climbing. This is the chat list's answer too —
            // it hands `install` a view inside its scroller, so the first step up finds it.
            var next: UIView? = view.superview
            var scroll: UIScrollView?
            while let v = next {
                if let s = v as? UIScrollView { scroll = s; break }
                next = v.superview
            }
            // ⚠️ AND WHEN THE CLIMB FINDS NOTHING, THE WINDOW — GATED. His 2026-08-09, twice: the
            // archive row's long press does nothing while the chat list's works. The chat list hands
            // its own scroll view over directly; the archive is a SwiftUI `.background`, so it has to
            // climb, and refusing to anchor at all (the old behaviour, retries and all) means the
            // screen simply has no press for its whole life. A retry cannot fix a climb that has no
            // scroll view to find.
            //
            // The reason a window anchor was refused still stands — a bare one would cancel the
            // touch of whatever was really being pressed anywhere in the app — so it is never bare.
            // It begins ONLY when both answers agree that this press belongs to this row: a
            // registered card is under the finger, and the thing actually on top at that point
            // belongs to the same screen we do. Everywhere else the recogniser fails at 0.2s having
            // cancelled nothing, which is exactly what having no recogniser did.
            let anchor: UIView? = scroll ?? (allowWindow ? view.window : nil)
            guard let anchor else { return }
            gated = scroll == nil
            origin = view
            let g = UILongPressGestureRecognizer(target: self, action: #selector(pressed(_:)))
            g.minimumPressDuration = 0.2      // the reference app's number, and the chat menu's
            g.delegate = self
            anchor.addGestureRecognizer(g)
            host = anchor
            press = g
        }

        /// The last view below the window on `v`'s way up — a presented screen's own container. Two
        /// views answer the same one exactly when they are on the same screen, which is how a press
        /// on a story standing OVER the archive is told from a press on the archive itself. Asked
        /// this way rather than by walking our own subtree, because where SwiftUI puts a
        /// `.background` representable relative to its content is not something to depend on.
        private func screenContainer(of v: UIView) -> UIView? {
            var top: UIView?
            var cur: UIView? = v
            while let c = cur, !(c is UIWindow) { top = c; cur = c.superview }
            return top
        }

        /// Only asked of a window-anchored recogniser (`gated`); a scroll-view anchor is already
        /// bounded to the row and keeps its old behaviour exactly — including swallowing the tap on
        /// a press that finds no card, which the chat list has shipped with since `bf976c8d`.
        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            guard gated else { return true }
            let p = g.location(in: nil)
            guard target(p) != nil, let origin, origin.window != nil else { return false }
            guard let hit = origin.window?.hitTest(p, with: nil) else { return false }
            return screenContainer(of: hit) === screenContainer(of: origin)
        }

        func uninstall() {
            if let press, let host { host.removeGestureRecognizer(press) }
            press = nil
            host = nil
            // A window anchor outlives the screen that installed it unless this is cleared, and the
            // next install has to decide the gate for itself.
            gated = false
            origin = nil
            overlay?.dismiss(animated: false)
        }

        /// ⚠️ THE SCROLL, YES. THE CARD'S TAP, NO — and that distinction is the whole of his
        /// "releasing after a long press opens the story".
        ///
        /// This returned `true` for everything, and the note at the top of the file claimed that on
        /// recognising, "UIKit cancels the touch the Button was tracking". It does not, and cannot,
        /// while we are saying yes to the Button's own recogniser: granting simultaneity is
        /// precisely the instruction to let it carry on. So the press raised the menu, the finger
        /// lifted, the tap that had been tracking the whole time fired, and the story opened behind
        /// the menu.
        ///
        /// Refusing it restores the standard rule: a recogniser that recognises cancels the others
        /// analysing the same touches unless it has agreed to share them. The pan keeps its yes,
        /// because a horizontal scroll must still be able to take the press away — that is the
        /// behaviour a row of cards should have and it is the only reason this method exists.
        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            other is UIPanGestureRecognizer
        }

        @objc private func pressed(_ g: UILongPressGestureRecognizer) {
            let p = g.location(in: nil)
            switch g.state {
            case .began:
                // Raised BEFORE the early-outs below: the finger is already past the threshold, so
                // the tap must be swallowed even on a press that finds no card to lift.
                StoryRowPress.began()
                guard overlay == nil,
                      let window = g.view?.window,
                      let t = target(p),
                      // ⚠️ CUT AT ZERO, AND LET THE LAYER DO THE ROUNDING. This asked for 24 and got
                      // a corner that did not match the card (his 2026-08-08 report, "when i long
                      // press story dont change the runded corners").
                      //
                      // MEASURED off his 9:05 screenshot: the shot was being cut TWICE. Here, at
                      // `24 * 1.12 = 26.88` with a CIRCULAR arc — the over-cut the flight's cover
                      // needs, because that cover has no mask of its own and its corners must come
                      // back transparent. And again by the image view below, at 24 with Apple's
                      // CONTINUOUS curve. The bigger cut wins, so the lift wore a 26.88pt circular
                      // corner where the card it came off wears a 24pt squircle: rounder, and the
                      // wrong shape.
                      //
                      // This view is not the cover and does not have the cover's problem. It carries
                      // its own mask, at the card's own radius and the card's own curve, so the
                      // square corners of a window crop are removed by the one cut that is already
                      // guaranteed to agree with the card.
                      let shot = StoryCardShot.crop(t.rect, in: window, cornerRadius: 0)
                else { return }
                let image = UIImageView(image: shot)
                image.frame = CGRect(origin: .zero, size: t.rect.size)
                image.contentMode = .scaleAspectFill   // only ever scales uniformly; belt anyway
                image.layer.cornerRadius = 24
                image.layer.cornerCurve = .continuous   // every card in this app is continuous
                image.layer.masksToBounds = true

                // THE NAME COMES WITH IT (his "also show Name"). A second crop rather than one taller
                // one, because the card is rounded and the name is not — a single image under a
                // single corner radius would round the bottom of the label. Photographed, not
                // rebuilt from a string, for the same reason the card is: a second label kept in step
                // by hand is the mistake `.contextMenu`'s `preview:` closure was making.
                //
                // The lifted rectangle is the CARD PLUS THE NAME when there is one, so the frame the
                // overlay squeezes out of is the whole card as the row draws it. A card with no name
                // reported falls straight through to exactly what it did before.
                let frame = t.labelRect.map { t.rect.union($0) } ?? t.rect
                let container = UIView(frame: CGRect(origin: .zero, size: frame.size))
                container.backgroundColor = .clear
                image.frame = CGRect(x: t.rect.minX - frame.minX, y: t.rect.minY - frame.minY,
                                     width: t.rect.width, height: t.rect.height)
                image.autoresizingMask = t.labelRect == nil
                    ? [.flexibleWidth, .flexibleHeight]
                    : [.flexibleWidth, .flexibleHeight, .flexibleBottomMargin]
                container.addSubview(image)
                // ⚠️ RENDERED FROM THE LABEL, NOT CROPPED OUT OF THE WINDOW — see `labelView`. The
                // card above is a window crop because its pixels really are on the window; the name
                // is glyphs on nothing, and a window crop of "nothing" is the chat list.
                var liftedName: UIView?
                if let lr = t.labelRect, let lv = t.labelView,
                   let nameShot = StoryCardShot.render(lv, cornerRadius: 0) {
                    let name = UIImageView(image: nameShot)
                    name.frame = CGRect(x: lr.minX - frame.minX, y: lr.minY - frame.minY,
                                        width: lr.width, height: lr.height)
                    name.autoresizingMask = [.flexibleWidth, .flexibleTopMargin]
                    container.addSubview(name)
                    liftedName = name
                }

                let o = CMOverlay(previewView: container,
                                  sourceFrame: frame,
                                  // The menu hugs the side the card is on, the way the chat's hugs
                                  // the side the bubble is on.
                                  alignRight: frame.midX > window.bounds.midX,
                                  actions: t.actions,
                                  react: nil,
                                  // TELEGRAM'S OPEN AND CLOSE, on his order. The chat's menu keeps
                                  // Signal's, which he has already judged — see `CMOverlay.Motion`.
                                  motion: .telegram) { [weak self] in
                    self?.overlay = nil
                }
                // The card comes back as the return spring STARTS, not after the lift is gone — a
                // SwiftUI reveal paints on the next pass, and waiting would leave one frame with an
                // empty slot in the row. See `CMOverlay.onWillDismiss`.
                //
                // ⚠️ AND THE COPY'S NAME GOES IN THE SAME BREATH, OR THE NAME IS ON SCREEN TWICE.
                //
                // His 2026-08-08 screenshot: two "Test Zahra", one sharp and one offset and blurred.
                // The reveal above brings the real card back INSTANTLY while the lifted copy takes
                // 0.4s to spring home, so for that whole spring both are drawn. The pictures
                // doubling is invisible — they are the same photograph landing on itself — but the
                // NAME the lift gained in `5401903` is a line of text sliding over a line of text
                // that is not moving, and the eye reads that immediately.
                //
                // A hard cut, not a fade: at this instant the copy is still up at the lifted size,
                // so its name is nowhere near the real one and there is nothing to cross-fade with.
                // What flies home is the picture, which is what it did before the name was added and
                // is the half that actually has somewhere to fly to.
                o.onWillDismiss = {
                    liftedName?.alpha = 0
                    MediaSourceVisibility.shared.reveal()
                }
                // AND WHERE IT LANDS IS ASKED AGAIN AT THE CLOSE, not remembered from here.
                //
                // The row dips a held card to 0.92 (its own pressed state), so the rectangle
                // photographed at `.began` is 8% smaller than the card the finger has since let go
                // of. Landing on the remembered rectangle means the copy shrinks past the real
                // card's size and vanishes, uncovering something bigger on the last frame. Same
                // hit-test and the same union rule as the lift; it declines if the card under that
                // point is no longer this person, and `CMOverlay` then keeps the original.
                o.liveSourceFrame = { [weak self] in
                    guard let self, let now = self.target(p), now.key == t.key else { return nil }
                    return now.labelRect.map { now.rect.union($0) } ?? now.rect
                }
                overlay = o
                // The real card steps aside for the lift, exactly as the chat hides the pressed
                // bubble: the same picture must never be on screen twice at the hand-over.
                // WITH THE NAME, because this lift carries one. A story flight does not, and hiding
                // the name for it is what made the name come back late after a close — see
                // `MediaSourceVisibility.hidesLabel`.
                MediaSourceVisibility.shared.hide(t.key, withLabel: true)
                UIImpactFeedbackGenerator(style: .medium).impactOccurred(intensity: 0.8)
                o.present(in: window, startAtSqueeze: true)

            case .changed:
                overlay?.fingerMoved(to: p)

            case .ended, .cancelled, .failed:
                StoryRowPress.ended()
                overlay?.fingerEnded(at: p)

            default:
                break
            }
        }
    }
}
