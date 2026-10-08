import UIKit

/// The app is portrait. The one exception is the call screen while it shows the other person's
/// shared screen full size: then the phone may turn to landscape, and the moment that ends (their
/// share stops, the call ends, the call is minimized) it comes back to portrait.
///
/// Info.plist lists the landscape orientations so the system CAN rotate; this mask is what the app
/// actually allows at any moment (`AppDelegate.application(_:supportedInterfaceOrientationsFor:)`).
@MainActor
enum OrientationLock {
    static var mask: UIInterfaceOrientationMask = .portrait

    /// The controller that asked for landscape (the call screen's cover, top of its window then).
    /// Landscape is given only while it is still the top controller of the window being asked
    /// about; every other window, and the same window once something else is on top or the cover
    /// is gone, stays portrait (1:1 audit #39, owner, 2026-10-08).
    private static weak var landscapeOwner: UIViewController?
    /// No owner could be found when landscape was turned on: fall back to the app-wide mask.
    private static var ownerUnknown = false

    /// What `application(_:supportedInterfaceOrientationsFor:)` returns for `window`.
    static func mask(for window: UIWindow?) -> UIInterfaceOrientationMask {
        guard mask != .portrait else { return .portrait }
        if ownerUnknown { return mask }
        // 1:1 audit check, 2026-10-08: the owner may sit anywhere in the presented chain, so an
        // alert or sheet over the call screen keeps landscape.
        guard let window, let owner = landscapeOwner, chain(in: window).contains(where: { $0 === owner }) else {
            return .portrait
        }
        return mask
    }

    /// The window's root and everything presented over it, up to the top controller.
    private static func chain(in window: UIWindow) -> [UIViewController] {
        var out: [UIViewController] = []
        var vc = window.rootViewController
        while let current = vc {
            out.append(current)
            guard let next = current.presentedViewController, !next.isBeingDismissed else { break }
            vc = next
        }
        return out
    }

    private static func topController(in window: UIWindow) -> UIViewController? {
        var vc = window.rootViewController
        while let next = vc?.presentedViewController, !next.isBeingDismissed { vc = next }
        return vc
    }

    /// The key window (or the one with something presented), where the call screen is.
    private static func currentWindow() -> UIWindow? {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
        return windows.first(where: { $0.isKeyWindow })
            ?? windows.first(where: { $0.rootViewController?.presentedViewController != nil })
    }

    /// The top controller of the key window (where the call screen is when it asks).
    private static func currentTopController() -> UIViewController? {
        guard let window = currentWindow() else { return nil }
        return topController(in: window)
    }

    static func allowLandscape(_ on: Bool) {
        let wanted: UIInterfaceOrientationMask = on ? .allButUpsideDown : .portrait
        // 1:1 audit check, 2026-10-08: refresh the owner on every "on", before the early return,
        // so an owner caught as a passing alert is corrected. A live owner still in the chain is
        // kept, so a later call made while an alert is up does not hand landscape to the alert.
        var ownerChanged = false
        if on {
            let window = currentWindow()
            let stillInChain = landscapeOwner.map { owner in
                window.map { chain(in: $0).contains { $0 === owner } } ?? false
            } ?? false
            if !stillInChain {
                let fresh = currentTopController()
                ownerChanged = fresh !== landscapeOwner
                landscapeOwner = fresh
                ownerUnknown = fresh == nil
            }
        }
        // A new owner while already on: the controllers below re-read the mask too.
        guard wanted != mask || ownerChanged else { return }
        if !on {
            landscapeOwner = nil
            ownerUnknown = false
        }
        mask = wanted
        print("[ScreenShare] orientation \(on ? "landscape allowed" : "portrait only")")
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            // Every controller that may be deciding the orientation re-reads the mask: the root and
            // whatever is presented on top of it (the call screen is a full-screen cover).
            for window in windowScene.windows {
                var vc = window.rootViewController
                while let current = vc {
                    current.setNeedsUpdateOfSupportedInterfaceOrientations()
                    vc = current.presentedViewController
                }
            }
            // On: the system follows the way the phone is held, inside the new mask.
            // Off: back to portrait now, even while the phone is still held sideways.
            windowScene.requestGeometryUpdate(.iOS(interfaceOrientations: wanted)) { error in
                print("[ScreenShare] orientation update refused: \(error.localizedDescription)")
            }
        }
    }
}
