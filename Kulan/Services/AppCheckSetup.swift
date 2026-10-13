import Foundation
import DeviceCheck
import FirebaseCore
import FirebaseAppCheck
import os

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
        guard let deviceCheck = DeviceCheckProvider(app: app) else { return nil }
        return DeadlineAppCheckProvider(wrapping: deviceCheck)
        #endif
    }
}

// 2026-10-13, the "one phone goes dead until relaunch" bug (6th report): App Check keeps ONE
// shared token fetch for the whole app and clears it only when the provider answers. Firestore,
// Storage, Functions and Auth all wait on that fetch before sending, with no time limit, so a
// DeviceCheck call that never answers leaves every send, listener, upload, lookup and call ring
// waiting until the app is killed. Disabling/enabling the network re-joins the same stuck fetch,
// which is why recovery never healed it and only a relaunch did.
//
// The fix is a deadline: if the provider has not answered in `deadline` seconds, answer with an
// error. App Check then clears its shared fetch (the next call starts a fresh one) and hands the
// SDKs a placeholder token, which the server accepts while enforcement is off.
final class DeadlineAppCheckProvider: NSObject, AppCheckProvider {
    private let inner: AppCheckProvider
    private let deadline: TimeInterval
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Kulan", category: "AppCheck")

    init(wrapping inner: AppCheckProvider, deadline: TimeInterval = 6) {
        self.inner = inner
        self.deadline = deadline
    }

    func getToken(completion handler: @escaping (AppCheckToken?, Error?) -> Void) {
        race(handler) { inner.getToken(completion: $0) }
    }

    func getLimitedUseToken(completion handler: @escaping (AppCheckToken?, Error?) -> Void) {
        race(handler) { done in
            if inner.getLimitedUseToken?(completion: done) == nil {
                inner.getToken(completion: done)
            }
        }
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        /// True for the first caller only.
        func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if done { return false }
            done = true
            return true
        }
        var isDone: Bool {
            lock.lock(); defer { lock.unlock() }
            return done
        }
    }

    // Whichever comes first, the provider's answer or the deadline, is delivered; the other is dropped.
    private func race(_ handler: @escaping (AppCheckToken?, Error?) -> Void,
                      start: (@escaping (AppCheckToken?, Error?) -> Void) -> Void) {
        let once = Once()
        let began = Date()
        let finish: (AppCheckToken?, Error?) -> Void = { token, error in
            guard once.claim() else { return }
            handler(token, error)
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + deadline) { [deadline] in
            guard !once.isDone else { return }
            Self.log.error("App Check token: no answer in \(deadline, privacy: .public)s, going on without it")
            DiagLog.add("App Check: no answer in \(Int(deadline))s, going on without it")
            finish(nil, NSError(domain: "Kulan.AppCheckDeadline", code: 1,
                                userInfo: [NSLocalizedDescriptionKey: "App Check provider did not answer in time"]))
        }
        start { token, error in
            let ms = Int(Date().timeIntervalSince(began) * 1000)
            if let error {
                Self.log.error("App Check token failed after \(ms, privacy: .public)ms: \(error.localizedDescription, privacy: .public)")
                DiagLog.add("App Check failed after \(ms)ms: \(error.localizedDescription)")
            } else {
                Self.log.info("App Check token in \(ms, privacy: .public)ms")
                if ms > 2000 { DiagLog.add("App Check slow: \(ms)ms") }
            }
            finish(token, error)
        }
    }
}
