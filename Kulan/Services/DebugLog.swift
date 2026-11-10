import Foundation

/// The app's console lines, for development only. A release build (TestFlight and the App Store)
/// writes nothing: these lines carry other people's uids, chat ids and error text, and the device
/// log can be read off a phone. Same arguments as `print`, so a call site reads the same.
func debugLog(_ items: Any..., separator: String = " ") {
    #if DEBUG
    print(items.map { "\($0)" }.joined(separator: separator))
    #endif
}

/// Who may send the hidden diagnostic log (`DiagLog`) to `users/{uid}/diag`: debug builds and
/// TestFlight installs, never an App Store install. Release audit 2026-11-10: every user's phone was
/// uploading up to 60 KB of chat ids, call ids and error text with no opt-out. The file itself is
/// still written on the phone; only the upload is gated, so a tester's report keeps working.
///
/// A TestFlight (and debug-signed) install carries a `sandboxReceipt`, an App Store install a
/// `receipt`; the same test `DemoStoryMedia.isAvailable` uses.
enum DiagUpload {
    static var allowed: Bool {
        #if DEBUG
        return true
        #else
        return Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"
        #endif
    }

    /// `DiagLog.flagForUpload`, for test builds only. An App Store install neither flags nor sends.
    static func flag(after seconds: TimeInterval = 3) {
        guard allowed else { return }
        DiagLog.flagForUpload(after: seconds)
    }
}
