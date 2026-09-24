import Foundation
import DeviceCheck
import FirebaseCore
import FirebaseAppCheck

// 2026-09-24 fix-all #161: App Check on the client. Every Firebase call (Firestore, Storage,
// Functions) now carries an App Check token proving the request came from this app on a real
// device. Nothing is ENFORCED yet: the server side keeps `enforceAppCheck` off until the
// console's App Check metrics show the real traffic is verified, so an app without a token keeps
// working. Turning enforcement on before that is how legitimate users get locked out.
//
// Provider: App Attest where the device supports it, DeviceCheck otherwise (older hardware and
// some managed devices report App Attest unsupported). The simulator has neither, so it uses the
// debug provider, whose token must be registered in the console before it verifies.
//
// ORDER MATTERS: `install()` must run BEFORE `FirebaseApp.configure()`, or the SDK has already
// built its default provider and ignores the factory.
enum AppCheckSetup {
    static func install() {
        AppCheck.setAppCheckProviderFactory(KulanAppCheckProviderFactory())
    }
}

final class KulanAppCheckProviderFactory: NSObject, AppCheckProviderFactory {
    func createProvider(with app: FirebaseApp) -> AppCheckProvider? {
        #if targetEnvironment(simulator)
        return AppCheckDebugProvider(app: app)
        #else
        // DeviceCheck only, for now. App Attest is stronger but needs the
        // `com.apple.developer.devicecheck.appattest-environment` entitlement, and adding that key
        // before the App Attest capability is enabled on the App ID in the developer portal makes
        // the TestFlight build fail at signing (the same trap as the associated-domains and
        // age-range keys). Once the capability is on: add the key with "production" to
        // Kulan.entitlements and return `AppAttestProvider(app:)` when
        // `DCAppAttestService.shared.isSupported`, keeping DeviceCheck as the fallback.
        return DeviceCheckProvider(app: app)
        #endif
    }
}
