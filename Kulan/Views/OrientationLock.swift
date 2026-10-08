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

    static func allowLandscape(_ on: Bool) {
        let wanted: UIInterfaceOrientationMask = on ? .allButUpsideDown : .portrait
        guard wanted != mask else { return }
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
