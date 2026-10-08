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
        guard let window, let owner = landscapeOwner, topController(in: window) === owner else {
            return .portrait
        }
        return mask
    }

    private static func topController(in window: UIWindow) -> UIViewController? {
        var vc = window.rootViewController
        while let next = vc?.presentedViewController, !next.isBeingDismissed { vc = next }
        return vc
    }

    /// The top controller of the key window (where the call screen is when it asks).
    private static func currentTopController() -> UIViewController? {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
        guard let window = windows.first(where: { $0.isKeyWindow })
                ?? windows.first(where: { $0.rootViewController?.presentedViewController != nil }) else { return nil }
        return topController(in: window)
    }

    static func allowLandscape(_ on: Bool) {
        let wanted: UIInterfaceOrientationMask = on ? .allButUpsideDown : .portrait
        guard wanted != mask else { return }
        if on {
            landscapeOwner = currentTopController()
            ownerUnknown = landscapeOwner == nil
        } else {
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
