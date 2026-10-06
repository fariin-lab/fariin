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
    static let duration: TimeInterval = 0.2
    static let cardRadius: CGFloat = 20

    /// A restore waiting for the call screen to reach the window. See `CallPipMorphProbe`.
    private static var pendingRestore: (from: CGRect, snapshot: UIView)?

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
        commit()
        // Two turns: one for SwiftUI to take the cover down and lay the card out, one for the card's
        // frame report to land.
        DispatchQueue.main.async {
            DispatchQueue.main.async {
                let target = CallService.shared.cardFrame
                guard target.width > 1, win.bounds.contains(target.insetBy(dx: 4, dy: 4)) else {
                    // No card to fly to (a stashed tab, or not laid out): their fade alone.
                    UIView.animate(withDuration: duration, animations: { box.alpha = 0 },
                                   completion: { _ in box.removeFromSuperview() })
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
                UIView.animate(withDuration: duration, delay: 0, options: [.curveEaseInOut], animations: {
                    box.frame = target
                    box.layer.cornerRadius = cardRadius
                    screen.alpha = 0
                }, completion: { _ in
                    CallService.shared.cardHiddenForMorph = false
                    box.removeFromSuperview()
                })
            }
        }
    }

    /// Restore from the card. Snapshots the card where it sits, then `commit` clears `minimized`; the
    /// call screen picks the flight up when it reaches the window (`CallPipMorphProbe`).
    static func restore(_ commit: () -> Void) {
        let from = CallService.shared.cardFrame
        if let win = keyWindow, from.width > 1,
           let card = win.resizableSnapshotView(from: from, afterScreenUpdates: false, withCapInsets: .zero) {
            pendingRestore = (from, card)
        }
        commit()
    }

    /// Called by the probe inside the call screen once it is in a window.
    fileprivate static func runRestoreIfPending(from probe: UIView) {
        guard let (from, card) = pendingRestore else { return }
        pendingRestore = nil
        guard let win = probe.window, let vc = presentedRoot(of: probe) else { return }
        let v = vc.view!
        // Hidden for the turn UIKit may still spend finishing the presentation (it sets the final
        // frame on completion); alpha is the one thing it leaves alone.
        v.alpha = 0
        DispatchQueue.main.async {
            v.frame = from
            v.layer.cornerRadius = cardRadius
            v.layer.cornerCurve = .continuous
            v.clipsToBounds = true
            card.frame = v.bounds
            card.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            v.addSubview(card)
            v.layoutIfNeeded()
            v.alpha = 1
            UIView.animate(withDuration: duration, delay: 0, options: [.curveEaseInOut], animations: {
                v.frame = win.bounds
                v.layer.cornerRadius = 0
                card.alpha = 0
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
