import Foundation

// WHERE TEST AIDS ARE OFFERED AT ALL: debug builds and TestFlight, never the App Store.
//
// This file used to also draw and encode the demo story cast (clips, posters, avatars) for
// `StoriesRepository.demoGroups`. That cast had been switched off for good since 2026-09-24 and
// was deleted with it (release audit L3, 2026-11-10). The gate below is what is left; DemoMode,
// GlowDemo and the Subscriptions preview read it.

enum DemoStoryMedia {

    /// Debug builds and TestFlight, never the App Store.
    ///
    /// A TestFlight (and debug-signed) install carries a `sandboxReceipt`; an App Store install
    /// carries a `receipt`. That is the only distinction available inside the app, and it is the one
    /// that matches the actual requirement: testers can reach these, the public never sees the
    /// switch. Not `#if DEBUG`: the TestFlight lane builds Release, so a debug-only aid is one the
    /// owner can never run.
    static var isAvailable: Bool {
        #if DEBUG
        return true
        #else
        return Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"
        #endif
    }
}
