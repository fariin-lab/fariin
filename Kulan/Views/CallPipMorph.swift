import UIKit
import SwiftUI

/// ⛔ THE REFERENCE APP'S MINIMIZE AND RESTORE, READ FROM ITS SOURCE — owner, 2026-10-06: "when I
/// click minimize, how the call page becomes the small preview, make it exactly like" the reference.
///
/// Theirs (ReturnToCallViewController.animatePipPresentation, IndividualCallViewController
/// .animateReturnFromPip): one `UIView.animate(withDuration: 0.2)`, default ease-in-out, no spring and
/// no transform. Minimizing, the call's WINDOW FRAME shrinks from the full screen to the small preview
/// while a snapshot of the full call screen on top of it fades from 1 to 0. Restoring is the mirror:
/// the call view starts at the preview's frame with a snapshot of the preview on top, and grows to
/// the full screen while that snapshot fades out.
///
/// This replaces the system zoom transition, which ran on its own ~0.5s spring and scaled the screen
/// rather than moving its frame. The cover itself now goes up and down as a hard cut; this draws the
/// motion around it. Our card keeps its own size (112×199, radius 20), his earlier choice; only the
/// motion is theirs.
@MainActor
enum CallPipMorph {
    /// ⛔ 0.35s, NOT THE REFERENCE SOURCE'S 0.2s — owner, 2026-10-06, on build 827: the zoom out and
    /// zoom in "work good but too speed". 0.2s with the picture fading the whole way was over before
    /// the eye could follow it. The frame now moves on a critically damped spring (no bounce) and the
    /// cross-fade runs in the middle of the move (`fadeDelay` .. + `fadeDuration`), so the screen is
    /// seen travelling into the card and back out of it.
    static let duration: TimeInterval = 0.35
    static let fadeDelay: TimeInterval = 0.06
    static let fadeDuration: TimeInterval = 0.22
    static let cardRadius: CGFloat = 20

    /// A restore waiting for the call screen to reach the window. See `CallPipMorphProbe`.
    private static var pendingRestore: (from: CGRect, snapshot: UIView)?

    /// Owner audit 2026-10-06 #43: a minimize flight is on screen. A tap on the card during it used to
    /// start a restore anyway (the card is invisible but still hit-testable), snapshotting the
    /// half-flown overlay as the card. Taps are ignored until the flight lands.
    private static var minimizeInFlight = false

    private static var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
    }

    private static func topPresented(_ window: UIWindow) -> UIViewController? {
        var vc = window.rootViewController?.presentedViewController
        while let next = vc?.presentedViewController { vc = next }
        return vc
    }

    /// Minimize. `commit` flips the call to minimized (the cover leaves with no animation and the card
    /// is placed); the shrink is drawn over that.
    static func minimize(_ commit: () -> Void) {
        guard let win = keyWindow, let top = topPresented(win),
              let screen = top.view.snapshotView(afterScreenUpdates: false) else { commit(); return }
        let box = UIView(frame: win.bounds)
        box.clipsToBounds = true
        box.layer.cornerCurve = .continuous
        box.isUserInteractionEnabled = false
        box.backgroundColor = .black
        screen.frame = box.bounds
        screen.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        box.addSubview(screen)
        win.addSubview(box)
        minimizeInFlight = true
        commit()
        // A beat for SwiftUI to take the cover down, lay the card out and report its frame. The
        // overlay covers the whole screen meanwhile, so nothing is seen to wait.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            do {
                let target = CallService.shared.cardFrame
                guard target.width > 1, win.bounds.contains(target.insetBy(dx: 4, dy: 4)) else {
                    // No card to fly to (a stashed tab, or not laid out): their fade alone.
                    UIView.animate(withDuration: duration, animations: { box.alpha = 0 },
                                   completion: { _ in
                                       minimizeInFlight = false
                                       box.removeFromSuperview()
                                   })
                    return
                }
                // The preview's own picture under the fading screen, as their pip window carries its
                // live content while it shrinks. Taken with the overlay out of the way, then the real
                // card is hidden until the flight lands so there are never two.
                box.isHidden = true
                let card = win.resizableSnapshotView(from: target, afterScreenUpdates: true, withCapInsets: .zero)
                box.isHidden = false
                if let card {
                    card.frame = box.bounds
                    card.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                    box.insertSubview(card, belowSubview: screen)
                }
                CallService.shared.cardHiddenForMorph = true
                UIView.animate(withDuration: fadeDuration, delay: fadeDelay, options: [.curveEaseIn], animations: {
                    screen.alpha = 0
                })
                UIView.animate(withDuration: duration, delay: 0, usingSpringWithDamping: 1, initialSpringVelocity: 0,
                               options: [], animations: {
                    box.frame = target
                    box.layer.cornerRadius = cardRadius
                }, completion: { _ in
                    minimizeInFlight = false
                    CallService.shared.cardHiddenForMorph = false
                    box.removeFromSuperview()
                })
            }
        }
    }

    /// Restore from the card. Snapshots the card where it sits, then `commit` clears `minimized`; the
    /// call screen picks the flight up when it reaches the window (`CallPipMorphProbe`).
    static func restore(_ commit: () -> Void) {
        // #43: a tap while the minimize flight is still landing is ignored (see `minimizeInFlight`).
        guard !minimizeInFlight else { return }
        let from = CallService.shared.cardFrame
        if let win = keyWindow, from.width > 1,
           let card = win.resizableSnapshotView(from: from, afterScreenUpdates: false, withCapInsets: .zero) {
            pendingRestore = (from, card)
            // Owner audit 2026-10-06 #43: the snapshot stands in the card's place, in the window, from
            // this moment. `commit` removes the real card at once, and the call screen is invisible
            // until the probe hands it the snapshot a runloop turn later, so without this there was a
            // frame with neither, just the screen underneath. The probe moves it into the call view.
            card.frame = from
            card.isUserInteractionEnabled = false
            win.addSubview(card)
            // A restore the call screen never picked up must not fire on some later call, nor leave
            // its picture sitting on the window.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                if pendingRestore?.snapshot === card {
                    pendingRestore = nil
                    card.removeFromSuperview()
                }
            }
        }
        commit()
    }

    /// Called by the probe inside the call screen once it is in a window.
    fileprivate static func runRestoreIfPending(from probe: UIView) {
        guard let pending = pendingRestore else { return }
        pendingRestore = nil
        let from = pending.from, card = pending.snapshot
        guard let win = probe.window, let vc = presentedRoot(of: probe) else {
            card.removeFromSuperview()   // #43: it was standing in for the card on the window
            return
        }
        let v = vc.view!
        // Hidden for the turn UIKit may still spend finishing the presentation (it sets the final
        // frame on completion); alpha is the one thing it leaves alone.
        v.alpha = 0
        DispatchQueue.main.async {
            v.frame = from
            v.layer.cornerRadius = cardRadius
            v.layer.cornerCurve = .continuous
            v.clipsToBounds = true
            v.addSubview(card)   // off the window (#43) and into the call view, in one move
            card.frame = v.bounds
            card.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            v.layoutIfNeeded()
            v.alpha = 1
            UIView.animate(withDuration: fadeDuration, delay: fadeDelay, options: [.curveEaseOut], animations: {
                card.alpha = 0
            })
            UIView.animate(withDuration: duration, delay: 0, usingSpringWithDamping: 1, initialSpringVelocity: 0,
                           options: [], animations: {
                v.frame = win.bounds
                v.layer.cornerRadius = 0
                v.layoutIfNeeded()
            }, completion: { _ in
                card.removeFromSuperview()
                v.clipsToBounds = false
            })
        }
    }

    /// The presented controller that holds `view`: up the parents to the one UIKit presented.
    private static func presentedRoot(of view: UIView) -> UIViewController? {
        var r: UIResponder? = view.next
        while let cur = r, !(cur is UIViewController) { r = cur.next }
        var vc = r as? UIViewController
        while let parent = vc?.parent { vc = parent }
        return vc?.presentingViewController != nil ? vc : nil
    }
}

/// Mounted in the call screen. When it reaches a window it hands the pending restore its view.
struct CallPipMorphProbe: UIViewRepresentable {
    func makeUIView(context: Context) -> Probe { Probe() }
    func updateUIView(_ v: Probe, context: Context) {}

    final class Probe: UIView {
        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
        }
        required init?(coder: NSCoder) { fatalError() }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil { CallPipMorph.runRestoreIfPending(from: self) }
        }
    }
}
