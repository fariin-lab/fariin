import UIKit
import SafariServices

/// OPENS A LINK WITHOUT THROWING THE PERSON OUT OF THE APP.
///
/// Every link in Kulan used to go through `UIApplication.shared.open`, which hands the URL to Safari
/// and leaves. Tap a link preview in a chat and the app is behind you; coming back means finding it
/// in the switcher and hoping the chat is where you left it.
///
/// The reference secure messenger's Terms page (his screenshots, 2026-08-23) is the standard answer:
/// `SFSafariViewController`, which is Safari presented as a sheet over the app. Close it and you are
/// exactly where you were, with reader mode, sharing and history for free and no browser of our own
/// to build.
///
/// ⛔ IT IS ALSO THE PRIVATE ONE, which matters more here than the convenience. SFSafariViewController
/// runs OUT OF PROCESS: the page cannot read anything of ours, we cannot read anything of the page's,
/// and it carries none of Safari's cookies. A `WKWebView` — the other way to keep someone in the app —
/// would run the page inside our process and inside our sandbox. For an app whose whole promise is
/// that we cannot see your messages, hosting somebody else's javascript next to them is not a
/// trade worth making. Never swap this for a WKWebView to "style" it.
enum WebLink {

    /// Opens `url` in the way that suits what it actually is.
    @MainActor
    static func open(_ url: URL) {
        guard useSheet(for: url) else {
            UIApplication.shared.open(url)   // let iOS route it to whichever app owns this
            return
        }
        guard let host = topViewController() else {
            UIApplication.shared.open(url)   // nothing to present from; better out than nowhere
            return
        }
        let safari = SFSafariViewController(url: url)
        safari.dismissButtonStyle = .close
        // No colours set on purpose: it inherits the system look, so it matches Safari rather than
        // wearing our tint over somebody else's website and implying the page is ours.
        host.present(safari, animated: true)
    }

    /// ⚠️ THE EXCLUSIONS ARE THE INTERESTING PART. A sheet is right for a WEB PAGE and wrong for
    /// everything else:
    ///
    /// - `tel:`, `sms:`, `mailto:`, `maps:` and our own `kulan://` are not pages at all; they belong
    ///   to another app and only the system can route them.
    /// - An App Store link IS https, but iOS hands those to the App Store app — where the person can
    ///   actually install the thing. In a Safari sheet they would get the web page instead, which
    ///   asks them to open the App Store as a second step for no reason.
    private static func useSheet(for url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        let host = (url.host ?? "").lowercased()
        if host == "apps.apple.com" || host == "itunes.apple.com" || host.hasSuffix(".apple.com") { return false }
        // Apple Maps is reached over https too (`maps.apple.com/?ll=`), and the system opens those in
        // the Maps app. A shared location must land in Maps with the pin, not on a web page.
        if host == "maps.apple.com" || host == "maps.google.com" { return false }
        return true
    }

    /// The controller anything presented has to sit on. Walks past whatever is already up — a sheet,
    /// a full-screen cover, the call screen — because presenting on a controller that is itself
    /// covered does nothing at all and looks like a dead tap.
    @MainActor
    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let root = scenes.first(where: { $0.activationState == .foregroundActive })?.keyWindow?.rootViewController
            ?? scenes.first?.keyWindow?.rootViewController
        var top = root
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}
